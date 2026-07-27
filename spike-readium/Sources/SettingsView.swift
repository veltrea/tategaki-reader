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

    private let engines: [(id: String, label: String)] = [
        ("voicevox", "VOICEVOX (:50021)"),
        ("aivis", "AivisSpeech (:10101)"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                engineSection
                voiceSection
                saveSection
                displaySection
            }
            .formStyle(.grouped)
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
        // 丸められる。content の .frame も .presentationDetents（iOS 用 API）も Catalyst の
        // フォームシートには効かず、行数がこの高さを超えると最下行(「言語」)が下端で切れる。
        // 唯一効くのは提示中ホスト VC の preferredContentSize。ブリッジで直接指定して全行を収める。
        // preferredContentSize は Catalyst の iOS 座標系（≈0.77 倍で画面表示）で解釈されるため、
        // 目標の実寸 ≒ 幅478×高さ616 pt を得るには 0.77 の逆数を掛けた値を渡す（620×800）。
        // 実寸 ≒ 620×0.77=478、800×0.77=616。全11行(実測≒555pt)が余裕をもって収まる。
        // 表示セクション（綴じ方向・見開き・アスペクト比）を足したぶん背を高くしてある。
        .background { CatalystSheetSizer(size: CGSize(width: 700, height: 1180)) }
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

// MARK: - Mac Catalyst フォームシートの高さ制御ブリッジ
//
// Catalyst の .sheet は UIKit フォームシートで提示され、SwiftUI の .frame /
// .presentationDetents では大きさを変えられない。提示中のホスト VC の
// preferredContentSize を直接与えると、その寸法でシート枠が確定する。
// 透明な子 VC を content の背景に忍ばせ、親をたどって提示ホスト（presentingVC を持つ VC）
// を見つけて設定する。
struct CatalystSheetSizer: UIViewControllerRepresentable {
    let size: CGSize

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.isUserInteractionEnabled = false
        return vc
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let target = size
        DispatchQueue.main.async {
            // 提示されているシートのルート（presentingViewController を持つ最上位の親）を探す。
            var host: UIViewController? = nil
            var cur: UIViewController? = uiViewController
            while let c = cur {
                if c.presentingViewController != nil { host = c }
                cur = c.parent
            }
            let vc = host ?? uiViewController.parent
            if let vc, vc.preferredContentSize != target {
                vc.preferredContentSize = target
            }
        }
    }
}
