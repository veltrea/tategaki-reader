import SwiftUI

// MARK: - 対訳の取得と翻訳（ReaderModel 側のロジック）

@MainActor
extension ReaderModel {

    /// 対訳ペインの開閉。開いたらすぐ現在ページを訳す。
    func toggleTranslation() {
        showTranslation.toggle()
        if showTranslation {
            refreshTranslation()
        } else {
            cancelTranslation()
            translationUnits = []
            translationError = nil
        }
    }

    /// 実行中の翻訳を止める（ページ送り・ペインを閉じたとき）。
    func cancelTranslation() {
        translateTask?.cancel()
        translateTask = nil
        isTranslating = false
    }

    /// ページ送りの連打で毎回 LLM を叩かないよう、少し落ち着いてから取り直す。
    func scheduleTranslationRefresh() {
        translateTask?.cancel()
        translateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.runTranslation(force: false)
        }
    }

    /// いま表示しているページを訳し直す。`force` でキャッシュを無視する。
    func refreshTranslation(force: Bool = false) {
        translateTask?.cancel()
        translateTask = Task { [weak self] in await self?.runTranslation(force: force) }
    }

    /// 対訳の行から本文の該当箇所へジャンプする。
    func jumpToPassage(_ unit: TranslationUnit) {
        guard unit.id.hasPrefix("epubcfi(") else { return }
        Task { await engine.call("window.__reader.goTo(\(FoliateEngine.quote(unit.id)))") }
    }

    /// 段落抽出 → キャッシュ充当 → 足りないぶんだけ LM Studio へ、の本体。
    private func runTranslation(force: Bool) async {
        guard engineReady else { return }
        let settings = TranslationSettingsStore.load()
        translationError = nil

        // 1) いま見えている段落を bridge から取る。
        guard let raw = await engine.callJSON("window.__reader.getVisiblePassages()") as? [String: Any]
        else {
            translationUnits = []
            translationError = String(localized: "本文を取得できませんでした")
            isTranslating = false
            return
        }
        if Task.isCancelled { return }

        var units: [TranslationUnit] = []
        for (i, p) in ((raw["passages"] as? [[String: Any]]) ?? []).enumerated() {
            let text = (p["text"] as? String) ?? ""
            guard !text.isEmpty else { continue }
            let cfi = (p["cfi"] as? String) ?? ""
            units.append(TranslationUnit(
                id: cfi.isEmpty ? "p\(i)" : cfi,
                isHeading: (p["heading"] as? Bool) ?? false,
                source: text))
        }
        guard !units.isEmpty else {
            translationUnits = []
            translationError = (raw["reason"] as? String) == "image-page"
                ? String(localized: "このページは画像です（訳す本文がありません）")
                : String(localized: "このページには訳す本文がありません")
            isTranslating = false
            return
        }

        // 2) モデルを決める。未指定なら一覧の先頭を使い、以後はその結果を使い回す
        //    （ページを送るたびに /v1/models を叩かない）。
        var model = settings.model
        if model.isEmpty { model = translationModel }
        if model.isEmpty {
            model = (await LMStudioClient.models(settings: settings))?.first?.id ?? ""
        }
        guard !model.isEmpty else {
            translationUnits = units
            translationError = String(localized: "LM Studio に接続できません。設定 →「翻訳（LM Studio）」で URL とモデルを確認してください。")
            isTranslating = false
            return
        }
        translationModel = model
        if Task.isCancelled { return }

        // 3) 訳済みの段落はキャッシュから即座に埋める（戻って読み返しても待たされない）。
        for i in units.indices where !force {
            let key = TranslationCache.key(
                model: model, target: settings.targetLanguage, text: units[i].source)
            if let hit = await TranslationCache.shared.value(for: key) {
                units[i].translated = hit
                units[i].state = .done
            }
        }
        translationUnits = units
        let pending = units.indices.filter { !units[$0].isSettled }
        guard !pending.isEmpty else {
            isTranslating = false
            return
        }

        // 4) 残りを翻訳する。ローカル LLM は並列にしても総スループットが伸びないことが多いので、
        //    少数ずつ束ねて投げ、終わった行から順にペインへ出す。
        isTranslating = true
        let system = LMStudioClient.systemPrompt(settings: settings)
        let width = max(1, min(settings.concurrency, 8))
        var cursor = 0
        var connectionFailures = 0

        while cursor < pending.count {
            if Task.isCancelled { break }
            let slice = Array(pending[cursor ..< min(cursor + width, pending.count)])
            for i in slice where i < translationUnits.count {
                translationUnits[i].state = .running
            }

            await withTaskGroup(of: (Int, Result<String, Error>).self) { group in
                for i in slice {
                    let text = units[i].source
                    // 直前の段落は文脈としてだけ渡す（代名詞・話者の取り違えを減らす）。
                    let previous = settings.useContext && i > 0 ? units[i - 1].source : nil
                    group.addTask {
                        do {
                            let out = try await LMStudioClient.chat(
                                settings: settings, model: model, system: system,
                                user: LMStudioClient.userPrompt(text: text, previous: previous))
                            return (i, .success(out))
                        } catch {
                            return (i, .failure(error))
                        }
                    }
                }
                for await (i, result) in group {
                    guard i < translationUnits.count else { continue }
                    switch result {
                    case let .success(text):
                        translationUnits[i].translated = text
                        translationUnits[i].state = .done
                        let key = TranslationCache.key(
                            model: model, target: settings.targetLanguage,
                            text: translationUnits[i].source)
                        await TranslationCache.shared.set(text, for: key)
                    case let .failure(error):
                        if error is URLError { connectionFailures += 1 }
                        translationUnits[i].state = .failed(Self.describe(error))
                    }
                }
            }
            cursor += slice.count
        }

        if connectionFailures > 0, connectionFailures == pending.count {
            translationError = String(localized: "LM Studio に接続できません。設定 →「翻訳（LM Studio）」で URL とモデルを確認してください。")
        }
        isTranslating = false
    }

    /// 行に出すエラー文言。
    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        if let e = error as? URLError { return e.localizedDescription }
        return String(describing: error)
    }
}

// MARK: - 対訳ペイン（本文の右に出す）

/// 左＝原文、右＝訳の2カラムで現在ページを見せるペイン。
///
/// 本文（foliate）はウィンドウ左に残るので、原文併記をオフにすると
/// 「左に原書・右に訳」というレイアウトそのものになる。
struct TranslationPane: View {
    /// 設定シートの開閉はアプリ側が持つ（書棚・リーダー・メニューで共通）。
    @ObservedObject var model: AppModel
    @ObservedObject var reader: ReaderModel
    /// ペインの幅（左端のハンドルをドラッグして変える）。
    @Binding var width: CGFloat

    /// ペイン内の文字倍率。
    @AppStorage("reader.translation.fontScale") private var fontScale: Double = 1.0
    /// 原文を併記するか（オフなら訳だけ）。
    @AppStorage("reader.translation.showSource") private var showSource: Bool = true

    /// ドラッグ開始時の幅。
    @State private var dragStart: CGFloat?

    static let minWidth: CGFloat = 280
    static let maxWidth: CGFloat = 900
    /// これ以上広ければ原文と訳を左右に並べる。狭いときは上下に積む。
    private static let sideBySideThreshold: CGFloat = 520

    var body: some View {
        HStack(spacing: 0) {
            resizeHandle
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
        }
        .background(.background)
    }

    // MARK: ヘッダ

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("対訳").font(.headline)
                if reader.isTranslating {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button { showSource.toggle() } label: {
                    Image(systemName: showSource ? "text.alignleft" : "text.justify.left")
                }
                .help(showSource ? "原文を隠す" : "原文を併記する")
                Button { fontScale = max(0.7, fontScale - 0.1) } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .help("文字を小さく")
                Button { fontScale = min(2.0, fontScale + 0.1) } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .help("文字を大きく")
                Button { reader.refreshTranslation(force: true) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(reader.isTranslating)
                .help("このページを訳し直す（キャッシュを使わない）")
                Button { model.showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .help("翻訳の設定")
                Button { reader.toggleTranslation() } label: {
                    Image(systemName: "xmark")
                }
                .help("対訳を閉じる")
            }
            HStack(spacing: 6) {
                Text(progressLabel)
                if !reader.translationModel.isEmpty {
                    Text("·")
                    Text(reader.translationModel).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var progressLabel: String {
        let done = reader.translationUnits.filter(\.isSettled).count
        let total = reader.translationUnits.count
        if total == 0 { return String(localized: "—") }
        return String(format: String(localized: "%1$d / %2$d 段落"), done, total)
    }

    // MARK: 本体

    private var content: some View {
        GeometryReader { geo in
            let sideBySide = showSource && geo.size.width >= Self.sideBySideThreshold
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let message = reader.translationError {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    ForEach(reader.translationUnits) { unit in
                        row(unit, sideBySide: sideBySide)
                        Divider()
                    }
                    if reader.translationUnits.isEmpty, reader.translationError == nil {
                        Text("ページを送ると、その画面の本文をここに訳します。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
            }
        }
    }

    private func row(_ unit: TranslationUnit, sideBySide: Bool) -> some View {
        Group {
            if sideBySide {
                HStack(alignment: .top, spacing: 14) {
                    sourceText(unit).frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    targetView(unit).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if showSource { sourceText(unit) }
                    targetView(unit)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // 行をダブルクリックすると本文をその段落へ動かす（長いページで見失わないため）。
        .onTapGesture(count: 2) { reader.jumpToPassage(unit) }
    }

    private func sourceText(_ unit: TranslationUnit) -> some View {
        Text(unit.source)
            .font(.system(size: (unit.isHeading ? 16 : 14) * fontScale,
                          weight: unit.isHeading ? .semibold : .regular))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func targetView(_ unit: TranslationUnit) -> some View {
        switch unit.state {
        case .done:
            Text(unit.translated)
                .font(.system(size: (unit.isHeading ? 17 : 15) * fontScale,
                              weight: unit.isHeading ? .semibold : .regular))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("翻訳中…").font(.caption).foregroundStyle(.secondary)
            }
        case .pending:
            Text("順番待ち").font(.caption).foregroundStyle(.tertiary)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 幅の調整

    /// ペイン左端の掴みしろ。ドラッグで幅を変える。
    private var resizeHandle: some View {
        ZStack {
            Color.clear
            Divider()
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStart ?? width
                    if dragStart == nil { dragStart = start }
                    // ペインは右側にあるので、左へ引くほど広くなる。
                    width = min(max(start - value.translation.width, Self.minWidth), Self.maxWidth)
                }
                .onEnded { _ in dragStart = nil }
        )
    }
}
