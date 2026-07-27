import SwiftUI
import UniformTypeIdentifiers

/// 設定シート（オーディオ＋表示）。モックの縦積みレイアウトを Form で実装。
///
/// 変更はローカルの作業コピーに溜め、「保存」で初めて永続化＋反映する（「閉じる」は破棄）。
/// エンジン URL・話者は VOICEVOX/AivisSpeech に実問い合わせして状態表示・一覧化する。
struct SettingsView: View {
    @ObservedObject var model: AppModel
    /// 開いている本があれば表示設定を即反映するためのリーダー（書棚から開いたときは nil）。
    var reader: ReaderModel?

    @Environment(\.dismiss) private var dismiss

    // 作業コピー（保存で確定）。
    @State private var audio = AudioSettingsStore.load()
    @State private var display = ReadingSettings()
    @State private var savePath: String = TTSSaveLocation.displayPath ?? ""

    // エンジン問い合わせ結果。
    @State private var engineVersion: String?      // nil = 未接続/未確認
    @State private var probing = false
    @State private var speakerList: [VoicevoxSpeakerStyle] = []

    @State private var showFolderPicker = false
    @State private var testSpeaker = VoicevoxSpeaker()
    @State private var testing = false

    // 翻訳（LM Studio）。
    @State private var translation = TranslationSettingsStore.load()
    @State private var lmModels: [LMStudioModel] = []
    @State private var lmProbing = false
    @State private var lmReachable = false
    @State private var cachedTranslations = 0

    private let engines: [(id: String, label: String)] = [
        ("voicevox", "VOICEVOX (:50021)"),
        ("aivis", "AivisSpeech (:10101)"),
    ]

    /// 設定の分類。全部を1枚に積むと縦がモニタからはみ出すので、タブで分けて畳む。
    enum SettingsTab: String, CaseIterable, Identifiable {
        case audio, display

        var id: String { rawValue }

        var label: LocalizedStringKey {
            switch self {
            case .audio: return "読み上げ"
            case .display: return "表示"
            }
        }
    }

    @State private var tab: SettingsTab = .audio

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(SettingsTab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)

                Form {
                    switch tab {
                    case .audio:
                        engineSection
                        voiceSection
                        saveSection
                    case .display:
                        displaySection
                        debugSection
                    }
                    // 対訳（LM Studio）はまだ表に出さない。実装は translationSection に残してある。
                }
                .formStyle(.grouped)
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button {
                        Task { await playTest() }
                    } label: {
                        if testing { ProgressView() } else { Text("テスト再生") }
                    }
                    .disabled(testing || engineVersion == nil)
                    Button("保存") { saveAndApply() }
                        .keyboardShortcut(.defaultAction)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { testSpeaker.stop(); dismiss() }
                }
            }
        }
        .frame(minWidth: 460)
        // Mac Catalyst の .sheet は UIKit フォームシートとして提示され、既定 ≈478×524 に
        // 丸められる。content の .frame も .presentationDetents（iOS 用 API）も効かず、
        // 行が増えると下端で切れる。ここでは画面上の実寸で欲しい大きさを渡し、
        // 座標系の換算と画面内への切り詰めは FittedSheetSizing に任せる（詳細はそちらの注記）。
        // 全項目を1枚に積むと画面高 900pt 級のモニタからはみ出しかけるので、タブで分けて
        // 一番丈の高いタブ（表示）がちょうど収まる大きさにしてある。
        .modifier(FittedSheetSizing(displaySize: CGSize(width: 620, height: 540)))
        .onAppear { display = model.settings }
        .task { await refreshEngine() }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                savePath = url.path
            }
        }
    }

    // MARK: - セクション

    private var engineSection: some View {
        Section {
            Picker("読み上げエンジン", selection: $audio.engine) {
                ForEach(engines, id: \.id) { Text($0.label).tag($0.id) }
            }
            .onChange(of: audio.engine) { newValue in
                // プリセット切替は URL を既定ポートへ差し替えて再問い合わせ。
                audio.baseURLString = AudioSettings.defaultURL(for: newValue)
                Task { await refreshEngine() }
            }

            TextField("URL", text: $audio.baseURLString)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { Task { await refreshEngine() } }

            LabeledContent("エンジン状態") {
                HStack(spacing: 8) {
                    if probing {
                        ProgressView().controlSize(.small)
                    } else if let v = engineVersion {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text(String(format: String(localized: "接続済み (v%@)"), "\"\(v)\""))
                            .foregroundStyle(.secondary)
                    } else {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("未接続").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await refreshEngine() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(probing)
                }
            }
        }
    }

    private var voiceSection: some View {
        Section {
            if speakerList.isEmpty {
                LabeledContent("話者") {
                    Text(engineVersion == nil ? "未接続" : "取得できません")
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("話者", selection: $audio.speaker) {
                    ForEach(speakerList) { Text($0.label).tag($0.id) }
                }
            }

            sliderRow("話速", value: $audio.speedScale, range: 0.5 ... 2.0, step: 0.05, format: "%.2f")
            sliderRow("無音の長さ（改行・句読点の間）", value: $audio.pauseLengthScale,
                      range: 0.0 ... 3.0, step: 0.1, format: "%.1f")
        }
    }

    private var saveSection: some View {
        Section {
            LabeledContent("音声の保存先") {
                HStack(spacing: 8) {
                    Text(savePath.isEmpty ? String(localized: "ダウンロード（既定）") : savePath)
                        .lineLimit(1).truncationMode(.head)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("参照…") { showFolderPicker = true }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    private var displaySection: some View {
        Section {
            sliderRow("文字サイズ", value: $display.fontSize, range: 0.6 ... 2.0, step: 0.05, format: "%.1f")
            sliderRow("行間", value: $display.lineHeight, range: 1.0 ... 2.4, step: 0.1, format: "%.1f")

            Picker("テーマ", selection: $display.theme) {
                Text("自動").tag("auto")
                Text("ライト").tag("light")
                Text("セピア").tag("sepia")
                Text("ダーク").tag("dark")
            }
            Picker("言語", selection: $display.language) {
                Text("Auto").tag("auto")
                Text("日本語").tag("ja")
                Text("English").tag("en")
            }
            Picker("書字方向", selection: $display.writingMode) {
                ForEach(WritingMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            Picker("表示モード", selection: $display.renderMode) {
                ForEach(RenderMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            Picker("綴じ方向", selection: $display.bindingDirection) {
                ForEach(BindingDirection.allCases) { d in
                    Text(d.label).tag(d.rawValue)
                }
            }
            Picker("画像ページの見開き", selection: $display.imageSpread) {
                ForEach(SpreadMode.allCases) { m in
                    Text(m.label).tag(m.rawValue)
                }
            }
            Picker("本文の見開き", selection: $display.textSpread) {
                ForEach(SpreadMode.allCases) { m in
                    Text(m.label).tag(m.rawValue)
                }
            }
        } footer: {
            Text("EPUB の縦書き指定は欠けていることが多いので、自動でうまくいかない本はリーダーの書字方向メニューで本ごとに上書きできます。表示モードを「EPUB のまま」にすると、画像の拡大・見開き・比率の補正を止めて、EPUB の指定がそのまま描かれた姿を確認できます。綴じ方向と見開きはここが全書籍の既定で、リーダーのツールバーで切り替えるとその本だけの指定として覚えます。")
        }
    }

    /// 開発時の確認用。既定は切ってあり、切っている間はツールバーに一切出ない。
    private var debugSection: some View {
        Section {
            Toggle("デバッグモード", isOn: $display.debugMode)
        } footer: {
            Text("測定グリッド（本文の上に重ねる半透明のものさし）をリーダーのツールバーに出します。"
                 + "レイアウトの余白や座標を実寸で確かめるための開発用の機能です。")
        }
    }

    /// 対訳（LM Studio）。原文はそのまま、訳をリーダー右のペインに出す。
    private var translationSection: some View {
        Section {
            TextField("LM Studio の URL", text: $translation.baseURLString)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { Task { await refreshLMStudio() } }

            LabeledContent("接続状態") {
                HStack(spacing: 8) {
                    if lmProbing {
                        ProgressView().controlSize(.small)
                    } else {
                        Circle().fill(lmReachable ? .green : .red).frame(width: 8, height: 8)
                        Text(lmReachable
                             ? String(format: String(localized: "接続済み (%d モデル)"), lmModels.count)
                             : String(localized: "未接続"))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await refreshLMStudio() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(lmProbing)
                }
            }

            if lmModels.isEmpty {
                LabeledContent("翻訳モデル") {
                    Text(lmReachable ? "取得できません" : "未接続").foregroundStyle(.secondary)
                }
            } else {
                Picker("翻訳モデル", selection: $translation.model) {
                    Text("自動（一覧の先頭）").tag("")
                    ForEach(lmModels) { Text($0.id).tag($0.id) }
                }
            }

            Picker("原文の言語", selection: $translation.sourceLanguage) {
                Text("自動判定").tag("auto")
                ForEach(TranslationLanguage.all, id: \.code) { Text($0.label).tag($0.code) }
            }
            Picker("訳文の言語", selection: $translation.targetLanguage) {
                ForEach(TranslationLanguage.all, id: \.code) { Text($0.label).tag($0.code) }
            }
            Toggle("直前の段落を文脈として渡す", isOn: $translation.useContext)
            Toggle("推論（thinking）を止めるよう頼む", isOn: $translation.disableThinking)
            Stepper(
                String(format: String(localized: "同時に投げる段落数: %d"), translation.concurrency),
                value: $translation.concurrency, in: 1 ... 8)

            LabeledContent("訳のキャッシュ") {
                HStack(spacing: 8) {
                    Text(String(format: String(localized: "%d 段落"), cachedTranslations))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("消去") {
                        Task {
                            await TranslationCache.shared.clear()
                            cachedTranslations = 0
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
        } header: {
            Text("翻訳（LM Studio）")
        } footer: {
            Text("LM Studio の「Local Server」を起動しておくと、リーダーの吹き出しボタンで対訳ペインを開けます。訳は段落ごとに作られ、一度訳した段落はキャッシュから即座に出ます。推論（thinking）するモデルは1段落に数十秒〜数分かかるので、対訳には推論しないモデルを選んでください。")
        }
    }

    /// ラベル + スライダー + 右端の数値表示（モックの各スライダー行）。
    private func sliderRow(
        _ title: LocalizedStringKey, value: Binding<Double>,
        range: ClosedRange<Double>, step: Double, format: String
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: value, in: range, step: step)
                Text(String(format: format, value.wrappedValue))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    // MARK: - 動作

    /// LM Studio へ /v1/models を問い合わせ、接続状態とモデル一覧を更新する。
    private func refreshLMStudio() async {
        lmProbing = true
        lmModels = []
        lmReachable = false
        if let models = await LMStudioClient.models(settings: translation) {
            lmReachable = true
            lmModels = models
            // 選んでいたモデルが一覧から消えていたら「自動」に戻す（LM Studio 側の入れ替えに追従）。
            if !translation.model.isEmpty, !models.contains(where: { $0.id == translation.model }) {
                translation.model = ""
            }
        }
        lmProbing = false
        cachedTranslations = await TranslationCache.shared.count()
    }

    /// URL へ /version と /speakers を問い合わせ、状態表示と話者一覧を更新する。
    private func refreshEngine() async {
        probing = true
        engineVersion = nil
        speakerList = []
        let base = audio.baseURL
        engineVersion = await VoicevoxCatalog.version(baseURL: base)
        if engineVersion != nil {
            speakerList = await VoicevoxCatalog.speakers(baseURL: base) ?? []
            // 現在の話者が一覧に無ければ先頭に寄せる（エンジン差し替え時のフォールバック）。
            if !speakerList.isEmpty, !speakerList.contains(where: { $0.id == audio.speaker }) {
                audio.speaker = speakerList[0].id
            }
        }
        probing = false
    }

    /// 現在（未保存）の設定でサンプル文を1文だけ合成・再生する。
    private func playTest() async {
        testing = true
        testSpeaker.config = audio.makeConfig()
        defer { testing = false }
        try? await testSpeaker.speak(.plain(String(localized: "これはテスト再生です。")))
    }

    /// 作業コピーを永続化し、開いている本と保存先に反映してから閉じる。
    private func saveAndApply() {
        testSpeaker.stop()
        AudioSettingsStore.save(audio)
        TranslationSettingsStore.save(translation)
        model.updateSettings(display)
        if savePath.isEmpty { TTSSaveLocation.clear() }
        else { TTSSaveLocation.setDirectory(URL(fileURLWithPath: savePath, isDirectory: true)) }
        applyLanguage(display.language)
        reader?.applyDisplaySettings()
        reader?.applyRenderMode()
        // 既定の書字方向を変えたときは、本ごとの上書きが無い本には即反映する
        //（組み直しが要るので applyDisplaySettings とは別経路）。
        reader?.refreshWritingModeFromSettings()
        // 綴じ方向・見開きの既定も同じく、本ごとの上書きが無い本へ反映する。
        reader?.refreshDisplayOverridesFromSettings()
        // モデルや訳文の言語を変えたら、開いている対訳は作り直す（前のモデルの訳が混ざらないよう）。
        if let reader, reader.showTranslation {
            reader.translationModel = translation.model
            reader.refreshTranslation()
        }
        dismiss()
    }

    /// UI 言語の上書き（"auto" で解除）。反映はアプリ再起動後。
    private func applyLanguage(_ code: String) {
        let defaults = UserDefaults.standard
        if code == "auto" {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([code], forKey: "AppleLanguages")
        }
    }
}

// MARK: - Mac Catalyst のシート寸法

/// 設定シートの大きさを決める。iOS 18 / macOS 15 で入った `.presentationSizing` を使う。
///
/// 経緯: Catalyst の `.sheet` は UIKit フォームシートで提示され、SwiftUI の `.frame` も
/// `.presentationDetents`（iOS 用）も効かない。長らく提示ホスト VC の `preferredContentSize`
/// を直接書く回避策を使っていたが、macOS 15 では設定してもすぐ既定値（iOS 座標 620×680
/// ＝実寸 478×524）へ巻き戻され、行が増えるほど下が切れるようになった。
/// `.presentationSizing` は SwiftUI 側で提示サイズを決めるためこれを迂回できる。
struct FittedSheetSizing: ViewModifier {
    /// 画面上の実寸（pt）で欲しいシートの大きさ。座標系の換算は内部で行う。
    let displaySize: CGSize

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.presentationSizing(SheetDisplaySizing(displaySize: displaySize))
        } else {
            // iOS 18 未満（macOS 14 以前）では Catalyst 既定サイズのまま。
            content
        }
    }
}

/// 実寸で欲しい大きさを、Catalyst の座標系と画面の広さに合わせて提案サイズへ直す。
///
/// `.form` や `.fitted` は Form がスクロール可能なせいで理想サイズを小さく見積もり、
/// シートが内容よりずっと小さくなる（実測 355×93）。そこで欲しい大きさを直接返す。
@available(iOS 18.0, *)
struct SheetDisplaySizing: PresentationSizing {
    let displaySize: CGSize

    /// 提案サイズは Catalyst の iOS 座標系で解釈され、画面にはこの比率で描かれる
    ///（実測: 提案 760×840 → 実寸 586×647、いずれも ×0.7708）。
    private static let catalystScale: CGFloat = 0.7708
    /// 画面端との最小の空き（実寸 pt）。メニューバーとシート上下の余白ぶん。
    private static let screenMargin = CGSize(width: 60, height: 70)

    func proposedSize(
        for root: PresentationSizingRoot, context: PresentationSizingContext
    ) -> ProposedViewSize {
        // PresentationSizingContext は寸法を公開しないので、画面は UIScreen から取る
        //（Catalyst の UIScreen.bounds は実寸 pt を返す。実測 1600×900）。
        let screen = UIScreen.main.bounds.size
        let fits = CGSize(
            width: min(displaySize.width, max(360, screen.width - Self.screenMargin.width)),
            height: min(displaySize.height, max(360, screen.height - Self.screenMargin.height)))
        return ProposedViewSize(
            width: fits.width / Self.catalystScale,
            height: fits.height / Self.catalystScale)
    }
}
