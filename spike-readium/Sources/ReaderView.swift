import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit
import AVFoundation

/// 1冊を表示するリーダー画面。書棚から `book` を受け取って開く。
struct ReaderScreen: View {
    @ObservedObject var model: AppModel
    let book: BookEntry

    @StateObject private var reader = ReaderModel()
    @State private var sliderValue: Double = 0
    @State private var isEditingSlider = false
    @State private var showBookmarks = false
    @State private var showSearch = false
    /// デバッグ用: ネイティブ層の測定グリッド（半透明メジャー）を表示するか。
    @AppStorage("reader.debug.measureGrid") private var showMeasureGrid = false
    /// ユーザー定義カスタムCSS（全書籍共通・本のCSSより後に注入して上書き）。
    @AppStorage("reader.userCSS") private var userCSS = ""
    @State private var showCSSEditor = false
    /// 読み上げ音声の保存先フォルダ選択ピッカーの表示。
    @State private var showSaveFolderPicker = false

    var body: some View {
        HStack(spacing: 0) {
            if showBookmarks {
                BookmarksSidebar(
                    model: model,
                    bookID: book.id,
                    onAdd: { reader.addBookmark() },
                    onJump: { reader.jump(to: $0) },
                    onClose: { showBookmarks = false }
                )
                .frame(width: 260)
                .transition(.move(edge: .leading))
                Divider()
            }
            if reader.showTOC {
                TOCSidebar(
                    reader: reader,
                    onJump: { reader.jumpToTOC($0) },
                    onClose: { reader.showTOC = false }
                )
                .frame(width: 280)
                .transition(.move(edge: .leading))
                Divider()
            }
        // 本文は常にウィンドウ全面。操作パネル（上下バー）はその上に重ねるだけなので、
        // 出入りで本文が再レイアウトされない（＝ページ割・文字の流し直しが起きない）。
        ZStack(alignment: .top) {
            ZStack {
                if reader.engineReady {
                    NavigatorContainer(
                        reader: reader,
                        showMeasureGrid: showMeasureGrid,
                        isImagePage: reader.currentPageIsImage,
                        onRegisterDictionary: { reader.requestDictionaryRegister(surface: $0) },
                        onDoubleTap: { reader.startSpeakingFromSelection() },
                        onDropEPUB: { model.open(url: $0) },
                        onPage: { forward in Task { await reader.pageStep(forward: forward) } },
                        onHover: { point, height in
                            reader.updateContentPointer(y: point?.y, viewHeight: height)
                        },
                        onShortcut: { reader.handleShortcut($0) },
                        isRTL: reader.isRTL,
                        columnPitch: reader.columnPitch,
                        pageBackground: ReaderModel.pageBackgroundColor(theme: model.settings.theme)
                    )
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(reader.status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // 本文領域の地色をテーマ色で先に塗っておく。ロード中(engineReady=false)の
            // プレースホルダは既定だと systemBackground（ライト=白）になり、
            // ダーク/セピアで本を開くたびに白が一瞬見えるため。
            // reader.model は .task で bind されるので1フレーム目は nil。
            // reader 側のプロパティを読むと light(白)に落ちるため、model から直接テーマを取る。
            .background(Color(uiColor: ReaderModel.pageBackgroundColor(theme: model.settings.theme)))

            chromeLayer
        }
        .task {
            reader.bind(model: model, bookID: book.id)
            #if DEBUG
            // DEBUG 限定: 計りレイヤー/測定を TestBus から駆動できるよう現在のリーダーを登録。
            TestBus.shared.reader = reader
            #endif
            await reader.load(book: book)
        }
        .onChange(of: reader.progression) { newValue in
            // foliate-js の relocate/seek 由来の fraction は稀に NaN や 0...1 外になり得る。
            // そのまま Slider(value:in:0...1) に渡すと assertionFailure でクラッシュするため、
            // 有限値へ丸めて範囲内にクランプしてから反映する。
            if !isEditingSlider {
                sliderValue = newValue.isFinite ? min(max(newValue, 0), 1) : 0
            }
        }
        .onDisappear { reader.persistProgress() }
        .sheet(isPresented: $showSearch) {
            SearchView(reader: reader) { locator in
                reader.jumpToSearchResult(locator)
            }
        }
        .sheet(isPresented: $showCSSEditor) {
            CSSEditorView(
                globalCSS: $userCSS,
                bookCSS: Binding(
                    get: { model.bookCSS(for: book.id) },
                    set: { model.setBookCSS(bookID: book.id, css: $0) }
                ),
                bookTitle: book.title
            ) {
                // 保存後: 解決済みCSSを再計算して現在ページに即反映＋以後のページにも注入。
                reader.applyUserCSS(reader.refreshActiveCSS())
            }
        }
        .sheet(isPresented: $reader.showDictionary) {
            DictionarySheet(reader: reader)
        }
        .sheet(isPresented: $reader.showSettings) {
            SettingsView(model: model, reader: reader)
        }
        // 読み上げ音声の保存先フォルダを選ぶ（App Sandbox 無効なので選んだパスをそのまま利用）。
        .fileImporter(
            isPresented: $showSaveFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                TTSSaveLocation.setDirectory(url)
                reader.status = String(format: String(localized: "保存先: %@"), url.path)
            }
        }
        .sheet(item: $reader.dictInput) { input in
            // 右クリック「読み上げ辞書に登録」からの登録フォーム（レイヤー指定つき）。
            NavigationStack {
                EntryEditForm(reader: reader, input: input)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("キャンセル") { reader.dictInput = nil }
                        }
                    }
            }
        }
        }
        .animation(.easeInOut(duration: 0.2), value: showBookmarks)
        .animation(.easeInOut(duration: 0.2), value: reader.showTOC)
    }

    // MARK: - 操作パネル層（Kindle 風・ホバーでのみ出す）

    /// パネル非表示時にウィンドウの上端／下端へ残すホバー反応帯の厚み(pt)。
    /// ネイティブ側の `UIHoverGestureRecognizer`（本文全域で効く）が主経路で、これはその補助。
    /// ここに本文へのクリックが吸われるので、気付かれない程度に薄くしておく。
    private static let hoverStrip: CGFloat = 6

    /// 上下の操作パネル。本文の上に重ねる層。
    private var chromeLayer: some View {
        VStack(spacing: 0) {
            topChrome
            Spacer(minLength: 0)
            bottomChrome
        }
    }

    /// 上バー（書棚に戻る・タイトル・各種操作）。ポインタが上端に寄ったときだけ出す。
    private var topChrome: some View {
        VStack(spacing: 0) {
            if reader.chromeTop {
                topBar
                    .background(.regularMaterial)
                Divider()
            }
            Color.clear
                .frame(height: reader.chromeTop ? 0 : Self.hoverStrip)
                .contentShape(Rectangle())
        }
        // パネル自身に乗っている間は出したまま（本文→パネルへポインタが移ると
        // 本文側のホバーは終わるので、この判定が無いと消えてしまう）。
        .onHover { reader.setChromeHover(top: $0) }
        .animation(.easeInOut(duration: 0.18), value: reader.chromeTop)
    }

    /// 下バー（進捗スライダー＋読み上げ操作）。ポインタが下端に寄ったときだけ出す。
    private var bottomChrome: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: reader.showsBottomChrome ? 0 : Self.hoverStrip)
                .contentShape(Rectangle())
            if reader.showsBottomChrome {
                Divider()
                progressBar
                    .background(.regularMaterial)
                Divider()
                ttsControls
            }
        }
        .onHover { reader.setChromeHover(bottom: $0) }
        .animation(.easeInOut(duration: 0.18), value: reader.showsBottomChrome)
    }

    /// Kindle 風の進捗スライダー + %表示。
    private var progressBar: some View {
        HStack(spacing: 12) {
            Slider(
                value: $sliderValue, in: 0 ... 1,
                onEditingChanged: { editing in
                    isEditingSlider = editing
                    if !editing {
                        Task { await reader.seek(to: sliderValue) }
                    }
                }
            )
            // 右→左読み（縦書き）のときは Kindle 同様に「右＝先頭」へ鏡像化。
            // 章ごとの isRTL ではなく本単位の bookIsRTL を使う（前付けは横組みなので、
            // 章の値で鏡像化すると本文へ入った瞬間に摘みが左右へ飛ぶ）。
            .environment(\.layoutDirection, reader.bookIsRTL ? .rightToLeft : .leftToRight)

            Text("\(Int((sliderValue * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                reader.persistProgress()
                model.closeBook()
            } label: {
                Label("書棚", systemImage: "chevron.left")
            }
            Spacer()
            Text(book.title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            readerControls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var readerControls: some View {
        HStack(spacing: 18) {
            // EPUB の指定を確かめる用。押すたびに「読みやすさ優先」⇄「EPUB のまま」を往復する。
            Button { reader.toggleRenderMode() } label: {
                Image(systemName: reader.renderMode == .raw
                    ? "chevron.left.forwardslash.chevron.right" : "wand.and.sparkles")
            }
            .help(reader.renderMode == .raw
                ? "EPUB のまま表示中（押すと読みやすさ優先へ）"
                : "読みやすさ優先で表示中（押すと EPUB のままへ）")
            // 固定レイアウトに限らず、画像ページを見開きで組んでいる本でも使う。
            if reader.isFixedLayout || reader.currentPageIsImage {
                Button { reader.toggleSpreadOffset() } label: {
                    Image(systemName: "rectangle.lefthalf.inset.filled")
                }
                .help("見開きをずらす")
            }
            Button { showSearch = true } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("本文を検索")
            Button { reader.showDictionary = true } label: {
                Image(systemName: "character.book.closed")
            }
            .help("読み上げ辞書（単語・読み替えルール）")
            Button { reader.addBookmark() } label: {
                Image(systemName: "bookmark")
            }
            .help("しおりを追加")
            Button { showBookmarks.toggle(); if showBookmarks { reader.showTOC = false } } label: {
                Image(systemName: showBookmarks ? "sidebar.left" : "list.bullet")
            }
            .help("しおり一覧")
            Button { reader.showTOC.toggle(); if reader.showTOC { showBookmarks = false } } label: {
                Image(systemName: "list.bullet.indent")
            }
            .help("目次")
            // 書字方向。EPUB の指定は当てにならないので、読み手が本ごとに上書きできる。
            Menu {
                Picker("書字方向", selection: Binding(
                    get: { reader.writingMode },
                    set: { reader.setWritingMode($0) }
                )) {
                    ForEach(WritingMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: reader.isVertical ? "text.append" : "text.alignleft")
            }
            .help("書字方向（縦書き／横書き）")
            Menu {
                Section("文字サイズ") {
                    Button { reader.changeFontSize(by: 0.1) } label: { Label("大きく", systemImage: "plus.magnifyingglass") }
                    Button { reader.changeFontSize(by: -0.1) } label: { Label("小さく", systemImage: "minus.magnifyingglass") }
                }
                Section("配色") {
                    Button { reader.setTheme("light") } label: { Label("ライト", systemImage: "sun.max") }
                    Button { reader.setTheme("sepia") } label: { Label("セピア", systemImage: "book.closed") }
                    Button { reader.setTheme("dark") } label: { Label("ダーク", systemImage: "moon") }
                }
                Section("カスタム") {
                    Button { showCSSEditor = true } label: {
                        Label("カスタムCSSを編集", systemImage: "curlybraces")
                    }
                }
                Section("音声保存") {
                    Button {
                        reader.saveCurrentSectionAudio()
                    } label: {
                        Label("このセクションを音声保存", systemImage: "waveform.and.mic")
                    }
                    .disabled(reader.isSavingAudio || reader.canStop)
                    Button { showSaveFolderPicker = true } label: {
                        Label("保存先フォルダを選択…", systemImage: "folder.badge.gearshape")
                    }
                    Text(String(format: String(localized: "保存先: %@"),
                                TTSSaveLocation.displayPath ?? String(localized: "ダウンロード（既定）")))
                }
            } label: {
                Image(systemName: "textformat.size")
            }
            .help("文字サイズ・配色")
            Button { reader.showSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .help("設定")
            Button { showMeasureGrid.toggle() } label: {
                Image(systemName: showMeasureGrid ? "ruler.fill" : "ruler")
            }
            .help("測定グリッド（デバッグ）")
        }
        .imageScale(.large)
    }

    private var ttsControls: some View {
        // ボタン群だけを中央に固定する。status を同じ HStack に入れると
        // 文字数の増減で HStack 全幅が変わり、アイコンの中心位置がずれてしまう。
        ttsButtons
            .frame(maxWidth: .infinity)
            // overlay はレイアウト（親のサイズ計算）に影響しないので、
            // status が何文字になってもボタンは動かない。
            .overlay(alignment: .trailing) {
                Text(reader.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.regularMaterial)
    }

    private var ttsButtons: some View {
        HStack(spacing: 24) {
            // 再生／一時停止
            Button {
                reader.togglePlayPause()
            } label: {
                Image(systemName: reader.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
            }
            .disabled(!reader.engineReady)
            .help(reader.isPlaying ? "一時停止" : "再生")

            // 停止
            Button {
                reader.stopSpeaking()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 40))
            }
            .disabled(!reader.canStop)
            .help("停止")

            // 音声保存（このセクションを WAV で書き出し）
            Button {
                reader.saveCurrentSectionAudio()
            } label: {
                ZStack {
                    // 波形＝音声。下矢印だけだと「何を保存するのか」が読めないため。
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.teal)
                        .opacity(reader.isSavingAudio ? 0.25 : 1)
                    if reader.isSavingAudio {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(!reader.engineReady || reader.isSavingAudio
                      || reader.isSavingVideo || reader.canStop)
            .help("このセクションを音声保存（WAV）")

            // 動画保存（読み上げ＋縦書きグロー動画を MP4/WebM で書き出し）
            Button {
                reader.saveCurrentSectionVideo()
            } label: {
                ZStack {
                    // フィルム＝動画。video.circle は小サイズで波形と紛れるため film に。
                    Image(systemName: "film.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.indigo)
                        .opacity(reader.isSavingVideo ? 0.25 : 1)
                    if reader.isSavingVideo {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(!reader.engineReady || reader.isSavingVideo
                      || reader.isSavingAudio || reader.canStop)
            .help("このセクションを動画保存（MP4）")
        }
        // 各ボタンの外形を固定する。ProgressView 差し替えや disabled で
        // ボタン自身の幅が変わらないよう ZStack 側は Image サイズに従う。
        .fixedSize()
    }
}

// MARK: - foliate WebView を SwiftUI に載せるホスト
// ページ送り入力（ホイール・矢印キー・ダブルクリック）は bridge.js が iframe 内で処理する。
// ここはネイティブ層の責務だけ持つ: 左右タップゾーン・測定グリッド・EPUB の D&D・列フィットインセット。
final class DictionaryHostViewController: UIViewController {
    let webView: WKWebView
    var onRegister: ((String) -> Void)?
    /// 本文の現在選択テキストを返す（ReaderModel.selectedText を読む）。
    /// buildMenu は同期呼び出しなので、JS 往復でなく selectionchange 同期値を使う。
    var selectionText: (() -> String)?
    /// ウィンドウへ EPUB がドロップされたときのコールバック（リーダー表示中の D&D 用）。
    var onDropEPUB: ((URL) -> Void)?
    /// 1画面ページ送り（forward=true で次へ）。タップゾーン・矢印キーから呼ぶ。
    var onPage: ((Bool) -> Void)?
    /// 読み上げのキー操作（"playPause" / "stop"）。本文にフォーカスが無くても効くように、
    /// bridge.js の keydown だけでなくレスポンダチェーンからも拾う。
    var onShortcut: ((String) -> Void)?
    /// ポインタのホバー位置（このビューの座標系）とビュー高さ。操作パネルの自動表示に使う。
    /// 位置 nil はホバー終了。
    var onHover: ((CGPoint?, CGFloat) -> Void)?
    /// 右→左読み（縦書き等）。左右タップ/矢印の「進む/戻る」判定に使う。
    var isRTL: Bool = false
    /// デバッグ用の測定グリッド（ネイティブ層・WKWebView の上に半透明で重ねる）。
    private lazy var measureGrid: MeasurementGridView = {
        let g = MeasurementGridView()
        g.translatesAutoresizingMaskIntoConstraints = false
        g.isUserInteractionEnabled = false   // タップ等はすべて下へ透過
        g.isHidden = true
        return g
    }()

    /// 列フィット用のインセット制約（縦書きの列ピッチ整数倍そろえ）。
    private var navLeading: NSLayoutConstraint!
    private var navTrailing: NSLayoutConstraint!
    /// 縦書きの列ピッチ(px)。>0 のとき、表示幅を列ピッチの整数倍にインセットして
    /// ページ端に半端な列（のぞき）が出ないようにする。画像ページには適用しない。
    private var columnPitch: CGFloat = 0
    private var pageIsImage = false

    init(webView: WKWebView) {
        self.webView = webView
        super.init(nibName: nil, bundle: nil)
        webView.translatesAutoresizingMaskIntoConstraints = false
        // 露出する地肌の既定色。実際のテーマ色は setPageBackground で上書きされる。
        view.backgroundColor = UIColor(hex: 0x1C1C1E)
        view.addSubview(webView)
        navLeading = webView.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        navTrailing = webView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            navLeading, navTrailing,
        ])
        setupPageTapZones()
        // ポインタの現在位置を SwiftUI 側へ流し、上端／下端に寄ったら操作パネルを出す（Kindle 風）。
        // hover は他の認識器と排他にならないので、WKWebView の上を動かしていてもここで拾える。
        view.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hoverMoved(_:))))
        // リーダー表示中も EPUB をドロップで開けるように、ホストビューに drop interaction を付ける。
        view.addInteraction(UIDropInteraction(delegate: self))
        // 測定グリッドは最前面（タップゾーンより上）に敷く。透過するので操作は妨げない。
        view.addSubview(measureGrid)
        NSLayoutConstraint.activate([
            measureGrid.topAnchor.constraint(equalTo: view.topAnchor),
            measureGrid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            measureGrid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            measureGrid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// 測定グリッドの表示/非表示を切り替える。
    func setMeasurementGrid(_ visible: Bool) {
        measureGrid.isHidden = !visible
        if visible { view.bringSubviewToFront(measureGrid) }
    }

    /// 地肌（ホストビュー）と WebView の背景を現在ページの背景色に揃える。
    /// 本を開いた瞬間や幅変化でコンテンツ未描画の一瞬に地肌が見えても白くならないよう、
    /// 本文背景と同色にしておく（開いた直後の白ちらつき防止＝じわっと表示になる）。
    /// とくに underPageBackgroundColor は WKWebView のリサイズ中に「コンテンツの外側」に
    /// 一瞬見える色で、既定がシステム色（ライト=白）のため放置すると白く光る主因になる。
    func setPageBackground(_ color: UIColor) {
        view.backgroundColor = color
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
        if #available(iOS 15.0, *) { webView.underPageBackgroundColor = color }
    }

    /// 列ピッチと画像ページ判定を受け取り、列フィットのインセットを更新する。
    func setColumnPitch(_ pitch: CGFloat, isImagePage: Bool) {
        let changed = abs(columnPitch - pitch) > 0.1 || pageIsImage != isImagePage
        columnPitch = pitch
        pageIsImage = isImagePage
        if changed { applyInsets(animated: false) }
    }

    /// 片側インセット = 列フィットぶん（列ピッチの整数倍に丸めるための端数）。
    /// 残り幅を列ピッチの整数倍に丸め、端数を左右に振り分けて半端な列（のぞき）を消す。
    private func sideInset() -> CGFloat {
        let avail = view.bounds.width
        guard columnPitch > 4, !pageIsImage, avail > columnPitch else { return 0 }
        // ちょうど N 列(= N×pitch)になるようインセット。丸めると clientWidth が pitch の
        // 整数倍からずれて pageStep の floor が 1 列ぶん重なるので、丸めずサブpx精度で入れる。
        let remainder = avail - (avail / columnPitch).rounded(.down) * columnPitch
        return remainder / 2
    }

    private func applyInsets(animated: Bool) {
        let inset = sideInset()
        guard abs(navLeading.constant - inset) > 0.5 else { return }
        navLeading.constant = inset
        navTrailing.constant = -inset
        if animated { UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() } }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyInsets(animated: false)  // 幅変化に追従（列フィット）
    }

    /// Kindle 風の左右端タップゾーン（幅15%）。ホバーで矢印、クリックでページ送り。
    private func setupPageTapZones() {
        // 左端タップ=視覚的に左へ。RTL(縦書き)では左=進む、LTR では左=戻る。
        // ページ送りは scroll モードの章内送りに対応するため onPage(pageStep) 経由にする
        //（navigator.goLeft/goRight だと章を丸ごと跨いで章内が飛ぶ）。
        let left = PageTapZone(icon: "chevron.left")
        let right = PageTapZone(icon: "chevron.right")
        left.onTap = { [weak self] in guard let self else { return }; self.onPage?(self.isRTL) }
        right.onTap = { [weak self] in guard let self else { return }; self.onPage?(!self.isRTL) }
        for z in [left, right] {
            // タップゾーンが hit-test を取る領域でもホバー位置を親へ流す（パネル自動表示用）。
            z.onHoverMove = { [weak self] point in
                guard let self else { return }
                onHover?(point, view.bounds.height)
            }
            z.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(z)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            left.topAnchor.constraint(equalTo: view.topAnchor),
            left.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            left.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.15),
            right.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            right.topAnchor.constraint(equalTo: view.topAnchor),
            right.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            right.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.15),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: - 矢印キーでのページ送り
    // WebView にフォーカスが無いときのフォールバック（フォーカス時は bridge.js の keydown が処理）。
    // 左=isRTLで進む / 右=その逆 / 下=進む / 上=戻る（縦書き・横書き双方で自然な向き）。
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(pageLeft)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(pageRight)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(pageDown)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(pageUp)),
            // 読み上げ: スペース=再生／一時停止、Return・Esc=停止。
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(shortcutPlayPause)),
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(shortcutStop)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(shortcutStop)),
        ]
    }

    @objc private func shortcutPlayPause() { onShortcut?("playPause") }
    @objc private func shortcutStop() { onShortcut?("stop") }

    // MARK: - ポインタ位置の通知（操作パネルの自動表示）

    @objc private func hoverMoved(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            onHover?(g.location(in: view), view.bounds.height)
        default:
            onHover?(nil, view.bounds.height)
        }
    }

    @objc private func pageLeft() { onPage?(isRTL) }
    @objc private func pageRight() { onPage?(!isRTL) }
    @objc private func pageDown() { onPage?(true) }
    @objc private func pageUp() { onPage?(false) }

    // MARK: - 右クリック（選択メニュー）の「読み上げ辞書に登録」
    // WKWebView の選択メニューへの項目追加は buildMenu(with:) で行う
    //（Catalyst で有効なことは Readium 時代に実証済み。合成イベントではメニューが開かないため検証は実クリックで）。

    @objc func registerReadingDictionary(_ sender: Any?) {
        onRegister?(selectionText?() ?? "")
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(registerReadingDictionary(_:)) {
            return !(selectionText?() ?? "").isEmpty
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context, !(selectionText?() ?? "").isEmpty else { return }
        let register = UICommand(
            title: String(localized: "読み上げ辞書に登録"),
            action: #selector(registerReadingDictionary(_:))
        )
        builder.insertChild(
            UIMenu(title: "", options: .displayInline, children: [register]),
            atStartOfMenu: .root
        )
    }
}

// MARK: - リーダー表示中の EPUB ドロップ受付

extension DictionaryHostViewController: UIDropInteractionDelegate {
    private static let dropTypes = [UTType.epub.identifier, UTType.fileURL.identifier]

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: Self.dropTypes)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        dlog("[Drop] performDrop items=\(session.items.count)")
        for item in session.items {
            // 書棚と同じ堅牢ローダ（in-place 実パス優先）。deliver は main で呼ばれる。
            EPUBDrop.load(from: item.itemProvider) { [weak self] url in
                self?.onDropEPUB?(url)
            }
        }
    }
}

/// 左右端のページ送りゾーン（Kindle 風）。ホバーで矢印を薄く表示、クリックで送り。
final class PageTapZone: UIControl {
    private let chevron = UIImageView()
    var onTap: (() -> Void)?
    /// ホバー位置（superview 座標）を親へ転送する。nil はホバー終了。操作パネルの自動表示用。
    var onHoverMove: ((CGPoint?) -> Void)?

    init(icon: String) {
        super.init(frame: .zero)
        chevron.image = UIImage(
            systemName: icon,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .semibold)
        )
        chevron.tintColor = UIColor.secondaryLabel
        chevron.alpha = 0
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        NSLayoutConstraint.activate([
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        let show = (g.state == .began || g.state == .changed)
        UIView.animate(withDuration: 0.15) { self.chevron.alpha = show ? 0.9 : 0 }
        onHoverMove?(show ? g.location(in: superview) : nil)
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted
                ? UIColor.label.withAlphaComponent(0.05)
                : .clear
        }
    }
}

/// デバッグ用の測定グリッド。WKWebView（コンテンツ表示部）の上に半透明で重ね、
/// どんな本でも表示部の物理座標に対して画像/本文の位置・余白をピクセルで測れるようにする。
/// 四辺に 0–100% 目盛り、中央に十字、ビューポート寸法(pt)、および
/// **16色2レーンの絶対座標リボン**（端の色を読むだけで絶対 pt 座標が分かる）を表示。非インタラクティブ。
final class MeasurementGridView: UIView {
    /// 1セルの pt サイズ。端からセルを数える／色を読むと座標が pt で分かる。
    private static let cell: CGFloat = 10
    /// 16色パレット（互いに識別しやすい配色。index が座標の「桁」を表す）。
    private static let palette: [UIColor] = [
        UIColor(hex: 0xE6194B), UIColor(hex: 0xF58231), UIColor(hex: 0xFFE119), UIColor(hex: 0xBFEF45),
        UIColor(hex: 0x3CB44B), UIColor(hex: 0x469990), UIColor(hex: 0x42D4F4), UIColor(hex: 0x4363D8),
        UIColor(hex: 0x000075), UIColor(hex: 0x911EB4), UIColor(hex: 0xF032E6), UIColor(hex: 0xFABED4),
        UIColor(hex: 0x9A6324), UIColor(hex: 0xFFFAC8), UIColor(hex: 0xAAFFC3), UIColor(hex: 0xA9A9A9),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()   // リサイズで目盛りを引き直す
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIContext() else { return }
        let W = bounds.width, H = bounds.height
        guard W > 1, H > 1 else { return }

        let grid = UIColor.systemGray.withAlphaComponent(0.35)
        let edge = UIColor.systemPink.withAlphaComponent(0.9)
        let center = UIColor.systemGreen.withAlphaComponent(0.9)

        // ---- 絶対座標リボン（先に敷いて、グリッド線を上に重ねる）----
        drawCoordinateRibbons(ctx: ctx, W: W, H: H)
        let band = Self.cell * 2  // リボン帯の厚み（下位+上位の2レーン）

        // 10% グリッド線
        ctx.setLineWidth(1)
        grid.setStroke()
        for i in 1..<10 {
            let x = (W * CGFloat(i) / 10).rounded()
            let y = (H * CGFloat(i) / 10).rounded()
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: H))
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y))
        }
        ctx.strokePath()

        // 外周枠 + 四辺の % 目盛り
        edge.setStroke()
        ctx.setLineWidth(2)
        ctx.stroke(bounds.insetBy(dx: 1, dy: 1))
        let tick: CGFloat = 12
        ctx.setLineWidth(2)
        for i in stride(from: 0, through: 100, by: 10) {
            let x = ((W - 1) * CGFloat(i) / 100).rounded()
            let y = ((H - 1) * CGFloat(i) / 100).rounded()
            ctx.move(to: CGPoint(x: x, y: band)); ctx.addLine(to: CGPoint(x: x, y: band + tick))
            ctx.move(to: CGPoint(x: x, y: H)); ctx.addLine(to: CGPoint(x: x, y: H - tick))
            ctx.move(to: CGPoint(x: band, y: y)); ctx.addLine(to: CGPoint(x: band + tick, y: y))
            ctx.move(to: CGPoint(x: W, y: y)); ctx.addLine(to: CGPoint(x: W - tick, y: y))
        }
        ctx.strokePath()

        // 中央十字
        center.setStroke()
        ctx.setLineWidth(2)
        let cx = (W / 2).rounded(), cy = (H / 2).rounded()
        ctx.move(to: CGPoint(x: cx, y: cy - 24)); ctx.addLine(to: CGPoint(x: cx, y: cy + 24))
        ctx.move(to: CGPoint(x: cx - 24, y: cy)); ctx.addLine(to: CGPoint(x: cx + 24, y: cy))
        ctx.strokePath()

        // ビューポート寸法（pt）
        let dim = "viewport \(Int(W))x\(Int(H)) pt / cell=\(Int(Self.cell))pt" as NSString
        let dimAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: center,
        ]
        dim.draw(at: CGPoint(x: cx + 6, y: cy + 6), withAttributes: dimAttrs)

        drawLegend(at: CGPoint(x: cx - 130, y: cy + 26))
    }

    /// 上辺(X)・左辺(Y)に 16色2レーンの絶対座標リボンを敷く。
    /// 下位レーン色 = palette[cell % 16]（1の位）、上位レーン色 = palette[(cell/16) % 16]（16の位）。
    /// 端の2セルの色を読めば「上位×16＋下位」で絶対セル番号→ ×cell pt で絶対座標。
    private func drawCoordinateRibbons(ctx: CGContext, W: CGFloat, H: CGFloat) {
        let c = Self.cell
        let pal = Self.palette
        // 上辺: X 座標（低レーン y[0,c), 高レーン y[c,2c)）
        var i = 0
        var x: CGFloat = 0
        while x < W {
            let low = pal[i % 16], high = pal[(i / 16) % 16]
            low.withAlphaComponent(0.9).setFill();  ctx.fill(CGRect(x: x, y: 0, width: c, height: c))
            high.withAlphaComponent(0.9).setFill(); ctx.fill(CGRect(x: x, y: c, width: c, height: c))
            x += c; i += 1
        }
        // 左辺: Y 座標（低レーン x[0,c), 高レーン x[c,2c)）
        i = 0
        var y: CGFloat = 0
        while y < H {
            let low = pal[i % 16], high = pal[(i / 16) % 16]
            low.withAlphaComponent(0.9).setFill();  ctx.fill(CGRect(x: 0, y: y, width: c, height: c))
            high.withAlphaComponent(0.9).setFill(); ctx.fill(CGRect(x: c, y: y, width: c, height: c))
            y += c; i += 1
        }
        // 16セルごと（=160pt）に境界線を引き、周回の切れ目を分かりやすく
        UIColor.black.withAlphaComponent(0.6).setStroke()
        ctx.setLineWidth(1)
        var k = 0
        x = 0
        while x < W { if k % 16 == 0 { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: c*2)) }; x += c; k += 1 }
        k = 0; y = 0
        while y < H { if k % 16 == 0 { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: c*2, y: y)) }; y += c; k += 1 }
        ctx.strokePath()
    }

    /// 色→桁の対応を示す凡例（0..F の16スウォッチ）。スクショから色を復号するため。
    private func drawLegend(at origin: CGPoint) {
        guard let ctx = UIContext() else { return }
        let sw: CGFloat = 15, h: CGFloat = 13
        let hexDigits = Array("0123456789ABCDEF")
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: UIColor.white,
        ]
        // 背景（黒帯）で視認性確保
        UIColor.black.withAlphaComponent(0.55).setFill()
        ctx.fill(CGRect(x: origin.x - 2, y: origin.y - 2, width: sw * 16 + 4, height: h + 4))
        for i in 0..<16 {
            let r = CGRect(x: origin.x + CGFloat(i) * sw, y: origin.y, width: sw, height: h)
            Self.palette[i].setFill(); ctx.fill(r)
            (String(hexDigits[i]) as NSString).draw(at: CGPoint(x: r.minX + 3, y: r.minY), withAttributes: attrs)
        }
    }

    private func UIContext() -> CGContext? { UIGraphicsGetCurrentContext() }
}

private extension UIColor {
    /// 0xRRGGBB 形式から生成。
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

private struct NavigatorContainer: UIViewControllerRepresentable {
    // foliate エンジンの WebView をホストに載せる（ホイール・矢印・ダブルクリックは bridge.js が処理）。
    let reader: ReaderModel
    var showMeasureGrid: Bool = false
    /// 現在ページが画像のみか（列フィットの適用除外判定に使う）。
    var isImagePage: Bool = false
    let onRegisterDictionary: (String) -> Void
    let onDoubleTap: () -> Void
    /// リーダー表示中に EPUB がドロップされたとき（ウィンドウ D&D 継続用）。
    var onDropEPUB: (URL) -> Void = { _ in }
    /// 1画面ページ送り（forward=true で次へ）。タップゾーン・矢印から呼ぶ。
    var onPage: (Bool) -> Void = { _ in }
    /// ポインタのホバー位置（本文ビュー座標）とビュー高さ。操作パネルの自動表示に使う。
    /// point=nil はホバー終了（ポインタがパネル上／ウィンドウ外へ出た）。
    var onHover: (CGPoint?, CGFloat) -> Void = { _, _ in }
    /// 読み上げのキー操作（"playPause" / "stop"）。
    var onShortcut: (String) -> Void = { _ in }
    /// 右→左読み（縦書き等）。左右タップ/矢印の向き判定に使う。
    var isRTL: Bool = false
    /// 旧 Readium 用の列ピッチ。foliate は正規ページネーションのため未使用（常に0）。
    var columnPitch: CGFloat = 0
    /// テーマの地色。reader（bind 前は nil の model 経由）ではなくビューから直接受け取る。
    var pageBackground: UIColor = .systemBackground

    func makeUIViewController(context: Context) -> DictionaryHostViewController {
        // WebView の生成時点でテーマ色を渡す（reader.html の --page-bg を documentStart で確定させ、
        // 本文が出るまでの地肌が白く光らないようにする）。
        let host = DictionaryHostViewController(
            webView: reader.engine.makeWebView(pageBackground: pageBackground))
        host.onRegister = onRegisterDictionary
        host.selectionText = { [weak reader] in reader?.selectedText ?? "" }
        host.onDropEPUB = onDropEPUB
        host.onPage = onPage
        host.onShortcut = onShortcut
        host.onHover = onHover
        host.isRTL = isRTL
        host.setColumnPitch(columnPitch, isImagePage: isImagePage)
        host.setMeasurementGrid(showMeasureGrid)
        host.setPageBackground(pageBackground)
        return host
    }

    func updateUIViewController(_ vc: DictionaryHostViewController, context: Context) {
        vc.onPage = onPage
        vc.onShortcut = onShortcut
        vc.onHover = onHover
        vc.isRTL = isRTL
        vc.setColumnPitch(columnPitch, isImagePage: isImagePage)
        vc.setMeasurementGrid(showMeasureGrid)
        // 露出する地肌を本文背景と揃える（テーマ変更にも追従・開いた瞬間の白ちらつき防止）。
        vc.setPageBackground(pageBackground)
        reader.engine.updatePageBackground(pageBackground)
    }
}

// MARK: - リーダーの状態・ロジック（foliate-js エンジン版）

/// 全文検索の1ヒット（foliate の CFI + 前後文脈つき抜粋）。
struct SearchHit: Identifiable, Hashable {
    let id = UUID()
    let cfi: String
    /// 一致前の文脈・一致文字列・一致後の文脈（旧UIの before/highlight/after と同じ役割）。
    let pre: String
    let match: String
    let post: String
}

/// 目次の1項目。foliate の book.toc（nav.xhtml / NCX どちらでも同じ形）をそのまま写す。
struct TOCEntry: Identifiable, Hashable {
    /// 階層位置（"0.2.1"）。href は本の中で重複しうるので識別子には使えない。
    let id: String
    let label: String
    let href: String
    let subitems: [TOCEntry]

    /// bridge の getTOC() が返した JSON を畳み込む。
    static func parse(_ raw: Any?) -> [TOCEntry] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard let id = dict["id"] as? String else { return nil }
            return TOCEntry(
                id: id,
                label: (dict["label"] as? String) ?? "",
                href: (dict["href"] as? String) ?? "",
                subitems: parse(dict["subitems"])
            )
        }
    }

    /// この項目とその子孫のうち、href が一致するものがあるか（現在章の判定用）。
    func contains(href: String) -> Bool {
        if self.href == href { return true }
        return subitems.contains { $0.contains(href: href) }
    }
}

@MainActor
final class ReaderModel: NSObject, ObservableObject {
    /// foliate エンジン（WebView + JS ブリッジ）の準備完了フラグ。旧 `navigator != nil` に相当。
    @Published var engineReady: Bool = false
    @Published var status: String = "読み込み中…"
    @Published var isPlaying: Bool = false
    @Published var canStop: Bool = false
    /// このセクションを音声ファイルに保存中か（ボタンの無効化・進捗表示用）。
    @Published var isSavingAudio: Bool = false
    /// このセクションを動画ファイルに保存中か（ボタンの無効化・進捗表示用）。
    @Published var isSavingVideo: Bool = false
    /// 本全体での現在位置（0...1）。スライダー・%表示に使う。
    @Published var progression: Double = 0
    /// 右→左読み。左右タップ・矢印キーの向きをこれで決める。
    /// 判定は bridge の pageDirection（実際に組まれた本文の向き）。spine の
    /// page-progression-direction は当てにならないので見ていない。
    /// **これは章ごとの値**（縦書きの本でも前付け・目次・奥付は横組み）。relocate のたびに
    /// 更新され、いま画面に組まれているものと必ず一致する。
    @Published var isRTL: Bool = false
    /// 本全体としての右→左読み。**進捗スライダーの鏡像だけ**はこちらを使う。
    /// 章ごとの isRTL で鏡像化すると、前付けと本文を行き来するたびに摘みが左右へ飛ぶ。
    @Published var bookIsRTL: Bool = false
    /// 本文が縦書きで組まれているか（動画の縦横・UI表示用）。isRTL 同様、章ごとの値。
    @Published var isVertical: Bool = false
    /// 適用中の書字方向（自動 / 強制縦書き / 強制横書き）。
    @Published var writingMode: WritingMode = .auto
    /// 表示モード。既定は読みやすさ優先の friendly。raw は EPUB の指定を確かめる用。
    @Published var renderMode: RenderMode = .friendly
    /// この本の OPF が主張する書字方向（"vertical"/"horizontal"/nil）。自動時の表示補足用。
    @Published var bookWritingHint: String?
    /// 目次（nav.xhtml / NCX のどちらでも同じ形）。
    @Published var toc: [TOCEntry] = []
    /// 目次サイドバーの表示。しおり側と違いモデルが持つのは、AX の出ない
    /// 状態遷移を TestBus から機械検証できるようにするため。
    @Published var showTOC = false
    /// いま読んでいる章の href（目次サイドバーの現在位置表示用）。
    @Published var currentTocHref: String = ""
    /// 固定レイアウト（写真集・漫画など）。見開き・ずらし機能を出すため。
    @Published var isFixedLayout: Bool = false
    /// 現在ページが画像のみか（列フィットの適用除外に使う。画像は全ブリード維持）。
    @Published var currentPageIsImage: Bool = false
    /// 旧 Readium 用の列ピッチ。foliate は正規ページネーションのため常に 0。
    @Published var columnPitch: CGFloat = 0
    /// 「読み上げ辞書に登録」フォーム用（非nilで表示）。
    @Published var dictInput: ReadingEntry?
    /// 統合辞書シートの表示（モデル所有＝登録フォームとの提示競合を requestDictionaryRegister で解決するため）。
    @Published var showDictionary = false
    /// 設定シート（オーディオ＋表示）の表示。
    @Published var showSettings = false
    /// 本文の現在選択テキスト（bridge の selectionchange 通知で同期）。
    /// 右クリックメニューの出し分けは同期判定が要るため、都度の JS 往復でなくこれを読む。
    var selectedText: String = ""
    /// 読み辞書（全書籍共通・UserDefaults 永続化）。音声エンジンには渡さず、
    /// 合成前に本文を読み仮名へ置き換えるために使う。
    @Published var readingEntries: [ReadingEntry] = ReadingDictionaryStore.load() {
        didSet {
            ReadingDictionaryStore.save(readingEntries)
            dictionary = ReadingDictionary(entries: readingEntries)
        }
    }
    /// コンパイル済みの辞書適用器（readingEntries 変更のたびに作り直す）。
    private var dictionary = ReadingDictionary(entries: ReadingDictionaryStore.load())
    /// 検索結果。
    @Published var searchResults: [SearchHit] = []
    @Published var isSearching = false

    // MARK: 操作パネルの自動表示（Kindle 風）
    // 本文を常に全面に使い、上下バーはポインタが端に寄ったときだけ重ねて出す。

    /// 上バー（書棚・タイトル・操作アイコン）を表示中か。
    @Published private(set) var chromeTop = false
    /// 下バー（進捗スライダー・読み上げ操作）を表示中か。
    @Published private(set) var chromeBottom = false
    /// 実際に下バーを見せるか。音声/動画の保存中は進捗表示が要るので出したままにする。
    var showsBottomChrome: Bool { chromeBottom || isSavingAudio || isSavingVideo }

    /// 本文ビューの上端からこの距離(pt)以内にポインタが入ると上バーを出す。
    static let chromeTopHotZone: CGFloat = 72
    /// 本文ビューの下端からこの距離(pt)以内にポインタが入ると下バーを出す。
    static let chromeBottomHotZone: CGFloat = 110

    /// 本文ビュー上のポインタが反応帯に入っているか。
    private var pointerTop = false
    private var pointerBottom = false
    /// パネル自身にポインタが乗っているか（乗っている間は消さない）。
    private var hoverTop = false
    private var hoverBottom = false
    /// 消すのを少し遅らせるタスク。本文からパネルへポインタが移る一瞬だけ
    /// どちらのホバーも切れるので、即座に消すとちらつく。
    private var chromeHideTask: Task<Void, Never>?

    /// foliate エンジン（WebView 生成は NavigatorContainer が makeWebView() で行う）。
    let engine = FoliateEngine()
    /// VOICEVOX 合成・再生（Readium 非依存の独立実装）。設定は AudioSettings から都度反映。
    private let speaker = VoicevoxSpeaker()

    /// 最新の保存済みエンジン設定（URL・話者・話速・無音長）を speaker に反映する。
    /// 再生/保存の直前に呼ぶことで、設定シートの変更を再起動なしで効かせる。
    private func applyAudioSettings() {
        speaker.config = AudioSettingsStore.load().makeConfig()
    }
    /// 読み上げループ。
    private var ttsTask: Task<Void, Never>?
    /// セクション音声保存の実行タスク（キャンセル用）。
    private var saveTask: Task<Void, Never>?
    /// セクション動画保存の実行タスク（キャンセル用）。
    private var videoTask: Task<Void, Never>?
    /// 保存ファイル名に使う本のタイトル。
    private var bookTitle: String = ""

    private weak var model: AppModel?
    private var bookID: UUID?
    /// 最後に relocate で受けた CFI（位置保存・しおり用）。
    private var latestCFI: String?
    /// 開いたときに復元する CFI。
    private var initialCFI: String?

    func bind(model: AppModel, bookID: UUID) {
        self.model = model
        self.bookID = bookID
    }

    // MARK: - 操作パネルの自動表示

    /// 本文ビュー上のポインタ位置から反応帯の判定を更新する。
    /// - Parameters:
    ///   - y: 本文ビュー座標の y。nil はホバー終了（パネル上か、ウィンドウ外へ出た）。
    ///   - viewHeight: 本文ビューの高さ（下端側の判定に使う）。
    func updateContentPointer(y: CGFloat?, viewHeight: CGFloat) {
        if let y, viewHeight > 0 {
            pointerTop = y <= Self.chromeTopHotZone
            pointerBottom = y >= viewHeight - Self.chromeBottomHotZone
        } else {
            pointerTop = false
            pointerBottom = false
        }
        refreshChrome()
    }

    /// パネル自身へのホバー（SwiftUI の onHover から）。指定した側だけ更新する。
    func setChromeHover(top: Bool? = nil, bottom: Bool? = nil) {
        if let top { hoverTop = top }
        if let bottom { hoverBottom = bottom }
        refreshChrome()
    }

    /// ホバー状態からパネルの表示を決める。出すのは即座に、消すのは少し待ってから。
    private func refreshChrome() {
        chromeHideTask?.cancel()
        if pointerTop || hoverTop { chromeTop = true }
        if pointerBottom || hoverBottom { chromeBottom = true }
        // 消す方向の変化だけ遅延させる（待っている間に別のホバーが来たら維持される）。
        guard (chromeTop && !(pointerTop || hoverTop))
                || (chromeBottom && !(pointerBottom || hoverBottom)) else { return }
        chromeHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard let self, !Task.isCancelled else { return }
            // 遅延後の最新状態で判定する（キャプチャした値は古くなり得る）。
            chromeTop = pointerTop || hoverTop
            chromeBottom = pointerBottom || hoverBottom
        }
    }

    /// 共通CSS＋この本のCSSを結合して UserDefaults の activeCSSKey に反映し、結合結果を返す。
    /// 注入 transform（EpubOpener）はこのキーを動的に読むので、以後のページに反映される。
    @discardableResult
    func refreshActiveCSS() -> String {
        let global = UserDefaults.standard.string(forKey: EpubOpener.userCSSKey) ?? ""
        let perBook = bookID.flatMap { model?.bookCSS(for: $0) }
        let resolved = EpubOpener.resolvedCSS(global: global, perBook: perBook)
        UserDefaults.standard.set(resolved, forKey: EpubOpener.activeCSSKey)
        return resolved
    }

    func load(book: BookEntry) async {
        guard book.fileExists, let data = try? Data(contentsOf: book.fileURL) else {
            status = "ファイルが見つかりません: \(book.path)"; return
        }
        bookTitle = book.title
        refreshActiveCSS()   // 開く前に解決済みCSSを用意（最初のページから適用させる）
        engine.provider.bookData = data
        // 位置は locatorJSON 欄に CFI を保存する新方式。旧 Readium Locator(JSON) は無視して先頭から。
        if let saved = book.locatorJSON, saved.hasPrefix("epubcfi(") { initialCFI = saved }
        engine.onMessage = { [weak self] body in self?.handleMessage(body) }
        status = "エンジン初期化中…"
        // これで NavigatorContainer が WebView を生成 → reader.html ロード → bridge-ready → open。
        engineReady = true
    }

    // MARK: JS(bridge.js) → Swift メッセージ

    private func handleMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String else { return }
        switch type {
        case "bridge-ready":
            openInJS()
        case "ready":
            let title = (body["title"] as? String) ?? ""
            status = "OK: \(title)"
            isRTL = (body["dir"] as? String) == "rtl"
            bookIsRTL = (body["bookDir"] as? String) == "rtl"
            isVertical = (body["vertical"] as? Bool) ?? false
            bookWritingHint = body["bookWritingHint"] as? String
            if let raw = body["writingMode"] as? String, let m = WritingMode(rawValue: raw) {
                writingMode = m
            }
            isFixedLayout = (body["fixedLayout"] as? Bool) ?? false
            loadTOC()
        case "shortcut":
            // 本文ビュー上のキー操作（スペース=再生／一時停止、Return・Esc=停止）。
            if let action = body["action"] as? String { handleShortcut(action) }
        case "relocate":
            if let f = body["fraction"] as? Double { progression = f }
            if let cfi = body["cfi"] as? String, !cfi.isEmpty { latestCFI = cfi }
            // 向きは章ごとに変わるので、表示が落ち着くたびに取り直す。ready の1回きりだと
            // 着地した章が前付け（横組み）か本文（縦組み）かで当たり外れが出ていた。
            if let d = body["dir"] as? String { isRTL = (d == "rtl") }
            if let v = body["vertical"] as? Bool { isVertical = v }
            if let bd = body["bookDir"] as? String { bookIsRTL = (bd == "rtl") }
            currentPageIsImage = (body["isImagePage"] as? Bool) ?? false
            currentTocHref = (body["tocHref"] as? String) ?? currentTocHref
            persistProgress()
        case "dblclick":
            // 本文のダブルクリック → その語の位置から読み上げ開始。
            startSpeakingFromSelection()
        case "selection":
            selectedText = (body["text"] as? String) ?? ""
        case "searchHit":
            if let cfi = body["cfi"] as? String {
                searchResults.append(SearchHit(
                    cfi: cfi,
                    pre: (body["pre"] as? String) ?? "",
                    match: (body["match"] as? String) ?? "",
                    post: (body["post"] as? String) ?? ""
                ))
            }
        case "searchDone":
            isSearching = false
        case "error":
            status = "エラー: \((body["message"] as? String) ?? "?")"
        default:
            break
        }
    }

    /// bridge-ready 後に本を開き、初期スタイルを流し込む。
    private func openInJS() {
        var opts: [String: Any] = [:]
        if let cfi = initialCFI { opts["cfi"] = cfi }
        // 書字方向は最初の組版より前に渡す必要がある（後から入れても組み直しになる）。
        opts["writingMode"] = (model?.writingMode(for: bookID) ?? .auto).rawValue
        // ツールバーのアイコンが実際の表示と食い違わないよう、開く前に状態も揃えておく。
        renderMode = RenderMode(rawValue: model?.settings.renderMode ?? "") ?? .friendly
        opts["renderMode"] = renderMode.rawValue
        Task {
            await engine.call("window.__reader.open(\(FoliateEngine.jsonArg(opts)))")
            pushStyle()
        }
    }

    // MARK: 書字方向（自動 / 強制縦書き / 強制横書き）

    /// 書字方向を切り替えて本を組み直す。現在位置は JS 側が CFI で保つ。
    /// 本ごとの指定として記憶するので、次に開いたときも同じ向きになる。
    func setWritingMode(_ mode: WritingMode) { applyWritingMode(mode, remember: true) }

    /// 全書籍の既定が変わったときに、この本へ適用すべき向きを取り直す。
    /// 本ごとの上書きを持つ本は既定に引きずられない。
    func refreshWritingModeFromSettings() {
        guard let model else { return }
        applyWritingMode(model.writingMode(for: bookID), remember: false)
    }

    private func applyWritingMode(_ mode: WritingMode, remember: Bool) {
        guard writingMode != mode else { return }
        writingMode = mode
        if remember, let bookID { model?.setWritingMode(bookID: bookID, mode: mode) }
        guard engineReady else { return }
        // 組み直しは本を開き直す形になるので、現在位置を CFI で渡して復元させる。
        let cfi = latestCFI ?? ""
        Task {
            _ = await engine.callAsync(
                "return await window.__reader.setWritingMode("
                + "\(FoliateEngine.quote(mode.rawValue)), \(FoliateEngine.quote(cfi)))")
        }
    }

    // MARK: 目次

    /// 目次を JS から取り込む。本を開き直すたびに呼ばれる（内容は変わらないが作り直しても安い）。
    private func loadTOC() {
        Task {
            let raw = await engine.callJSON("window.__reader.getTOC()")
            toc = TOCEntry.parse(raw)
        }
    }

    /// 目次項目へジャンプする。
    func jumpToTOC(_ entry: TOCEntry) {
        guard engineReady, !entry.href.isEmpty else { return }
        Task { await engine.call("window.__reader.goTo(\(FoliateEngine.quote(entry.href)))") }
    }

    /// 現在のアプリ設定（テーマ・フォント）＋解決済みユーザーCSSを JS へ反映。
    private func pushStyle() {
        let s = model?.settings
        let css = UserDefaults.standard.string(forKey: EpubOpener.activeCSSKey) ?? ""
        let dict: [String: Any] = [
            "theme": s?.theme ?? "light",
            "fontScale": s?.fontSize ?? 1.0,
            "lineHeight": s?.lineHeight ?? 1.8,
            "userCSS": css,
        ]
        Task { await engine.call("window.__reader.setStyle(\(FoliateEngine.jsonArg(dict)))") }
    }

    /// 設定シートで保存された表示設定（テーマ・フォント・行間）を現在ページへ即反映する。
    func applyDisplaySettings() { pushStyle() }

    /// 表示モード（読みやすさ優先／EPUB のまま）を設定から取り込んで反映する。
    func applyRenderMode() {
        let raw = model?.settings.renderMode ?? RenderMode.friendly.rawValue
        renderMode = RenderMode(rawValue: raw) ?? .friendly
        pushRenderMode()
    }

    /// ツールバーからの往復切り替え。設定にも残して、設定画面の表示と食い違わないようにする。
    func toggleRenderMode() {
        renderMode = (renderMode == .friendly) ? .raw : .friendly
        pushRenderMode()
        if var s = model?.settings {
            s.renderMode = renderMode.rawValue
            model?.updateSettings(s)
        }
        status = renderMode == .raw
            ? String(localized: "EPUB のまま表示")
            : String(localized: "読みやすさ優先で表示")
    }

    private func pushRenderMode() {
        Task { await engine.call("window.__reader.setRenderMode('\(renderMode.rawValue)')") }
    }

    /// 1画面ぶんのページ送り。foliate の正規ページネーション（next/prev）に委譲する。
    /// 縦書き・横書き・RTL・固定レイアウトすべて foliate が正しく処理する。
    func pageStep(forward: Bool) async {
        guard engineReady else { return }
        await engine.call(forward ? "window.__reader.next()" : "window.__reader.prev()")
    }

    /// スライダー等からのシーク。本全体の割合(0...1)へジャンプ。
    func seek(to fraction: Double) async {
        let f = min(max(fraction, 0), 1)
        progression = f
        guard engineReady else { return }
        await engine.call("window.__reader.goToFraction(\(f))")
    }

    // MARK: 位置の記憶

    func persistProgress() {
        guard let bookID, let cfi = latestCFI, !cfi.isEmpty else { return }
        model?.saveProgressCFI(bookID: bookID, cfi: cfi, fraction: progression)
    }

    // MARK: TTS（foliate の文抽出 + VOICEVOX 合成・再生）

    func togglePlayPause() {
        if ttsTask != nil {
            // 再生中 ⇄ 一時停止（文の途中位置も保持される）。
            if isPlaying { speaker.pause(); isPlaying = false }
            else { speaker.resume(); isPlaying = true }
            return
        }
        // いま表示しているページ（可視範囲の先頭）から読み上げ開始。
        startTTS(mode: "visible")
    }

    /// 読み上げのキー操作の入口。bridge.js（本文にフォーカスがあるとき）と
    /// レスポンダチェーン（無いとき）の両方から来るので、続けて届いた分は捨てる。
    private var lastShortcut: (action: String, at: Date)?
    func handleShortcut(_ action: String) {
        let now = Date()
        if let last = lastShortcut, last.action == action, now.timeIntervalSince(last.at) < 0.3 { return }
        lastShortcut = (action, now)
        switch action {
        case "playPause": if engineReady { togglePlayPause() }
        case "stop": stopSpeaking()
        default: break
        }
    }

    func stopSpeaking() {
        ttsTask?.cancel()
        ttsTask = nil
        speaker.stop()
        isPlaying = false
        canStop = false
        Task { await engine.call("window.__reader.ttsStop()") }
    }

    /// ダブルクリックした語の位置から読み上げを開始する。
    func startSpeakingFromSelection() {
        guard engineReady else { return }
        ttsTask?.cancel()
        ttsTask = nil
        speaker.stop()
        Task {
            // WKWebView のダブルクリック単語選択が確定するのを少し待つ。
            try? await Task.sleep(nanoseconds: 250_000_000)
            startTTS(mode: "selection")
        }
    }

    /// 読み上げループ本体。JS から文リスト（mark+text）を取り、文ごとに
    /// ハイライト（ttsMark）→ VOICEVOX 合成→再生 を繰り返す。ブロックが尽きたら次ブロックへ。
    private func startTTS(mode: String) {
        guard engineReady, ttsTask == nil else { return }
        applyAudioSettings()
        isPlaying = true
        canStop = true
        status = String(localized: "読み上げ中…")
        ttsTask = Task { [weak self] in
            guard let self else { return }
            // ttsStart/ttsNextBlock は async（Promise）。callAsyncJSON で解決を待つ。
            var block = await self.engine.callAsyncJSON(
                "return await window.__reader.ttsStart(\(FoliateEngine.quote(mode)))")
            while !Task.isCancelled {
                guard let sentences = block as? [[String: Any]] else { break }  // null = 本の終わり
                for s in sentences {
                    if Task.isCancelled { break }
                    let text = ((s["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if let mark = s["mark"] as? String {
                        await self.engine.call("window.__reader.ttsMark(\(FoliateEngine.quote(mark)))")
                    }
                    do {
                        // 読み辞書を適用してから合成（表示・ハイライトは原文のまま）。
                        try await self.speaker.speak(self.prepareSpeech(text))
                    } catch is CancellationError {
                        break
                    } catch {
                        if !Task.isCancelled {
                            self.status = "読み上げエラー: \(error.localizedDescription)（VOICEVOX起動確認）"
                        }
                        await self.finishTTS()
                        return
                    }
                }
                if Task.isCancelled { break }
                // 段落間の小休止。
                try? await Task.sleep(nanoseconds: 200_000_000)
                block = await self.engine.callAsyncJSON("return await window.__reader.ttsNextBlock()")
            }
            await self.finishTTS()
            if !Task.isCancelled { self.status = String(localized: "読み上げ終了") }
        }
    }

    private func finishTTS() async {
        await engine.call("window.__reader.ttsStop()")
        isPlaying = false
        canStop = false
        ttsTask = nil
    }

    // MARK: - セクション音声ファイル保存（章単位）

    /// いま表示しているセクション（章）の全文を VOICEVOX で合成し、1本の WAV に連結して
    /// 環境設定の保存先ディレクトリへ書き出す。読み替えルールは再生時と同じく適用する。
    /// 再生中は不可（同じ speaker を共有するため）。
    func saveCurrentSectionAudio() {
        guard engineReady, saveTask == nil, ttsTask == nil else { return }
        saveTask = Task { [weak self] in
            _ = await self?.performSectionSave()
        }
    }

    /// 保存の実体。成功時は書き出した WAV の URL を返す（テスト自動化から await できる）。
    /// status への進捗表示・isSavingAudio・saveTask の後始末もここで行う。
    @discardableResult
    func performSectionSave() async -> URL? {
        guard engineReady, ttsTask == nil else { return nil }
        applyAudioSettings()
        isSavingAudio = true
        status = String(localized: "セクションの文を収集中…")
        defer { isSavingAudio = false; saveTask = nil }

        // 1) 現在セクションの全文を収集（表示ページは動かさない）。
        let collected = await engine.callAsyncJSON(
            "return await window.__reader.ttsCollectSection()")
        guard let sentences = collected as? [String], !sentences.isEmpty else {
            status = String(localized: "保存する文がありません（VOICEVOX起動確認）")
            return nil
        }

        // 2) 文ごとに合成（読み替えルール適用）。進捗を status に出す。
        var wavs: [Data] = []
        for (idx, raw) in sentences.enumerated() {
            if Task.isCancelled { status = String(localized: "保存を中止しました"); return nil }
            let prepared = prepareSpeech(raw)
            guard !prepared.isEmpty else { continue }
            status = String(
                format: String(localized: "音声を合成中… %lld / %lld"),
                idx + 1, sentences.count)
            do {
                wavs.append(try await speaker.synthesizeWAV(prepared))
            } catch {
                status = "保存エラー: \(error.localizedDescription)（VOICEVOX起動確認）"
                return nil
            }
        }

        // 3) 連結してファイルへ書き出し。
        guard let merged = WAV.concatenate(wavs) else {
            status = String(localized: "音声の連結に失敗しました")
            return nil
        }
        let dir = TTSSaveLocation.resolveDirectory()
        let scoped = dir.startAccessingSecurityScopedResource()
        defer { if scoped { dir.stopAccessingSecurityScopedResource() } }
        let fileURL = dir.appendingPathComponent(saveFileName())
        do {
            try merged.write(to: fileURL)
            status = String(
                format: String(localized: "保存しました: %@"), fileURL.lastPathComponent)
            return fileURL
        } catch {
            status = "保存に失敗: \(error.localizedDescription)"
            return nil
        }
    }

    /// 保存を中止する。
    func cancelSaveAudio() {
        saveTask?.cancel()
    }

    /// 保存ファイル名（本タイトル + 日時 + 拡張子）。ファイル名に使えない文字は除去する。
    private func saveFileName(ext: String = "wav") -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = df.string(from: Date())
        let base = bookTitle.isEmpty ? "section" : bookTitle
        let safe = base.components(
            separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "_")
        let trimmed = String(safe.prefix(60))
        return "\(trimmed) \(stamp).\(ext)"
    }

    // MARK: - セクション動画ファイル保存（章単位・読み上げ＋縦書きグロー）

    /// いま表示しているセクション（章）の全文で、VOICEVOX 読み上げに同期した
    /// 縦書きグロー動画（カラオケ字幕風）を生成し、環境設定の保存先へ MP4/WebM で書き出す。
    /// 描画・録画は narration エンジン（オフスクリーン WKWebView + Canvas + MediaRecorder）が担う。
    /// 録画はリアルタイム（本文 5 分なら約 5 分）。再生・音声保存中は不可。
    func saveCurrentSectionVideo() {
        guard engineReady, videoTask == nil, saveTask == nil, ttsTask == nil else { return }
        videoTask = Task { [weak self] in
            _ = await self?.performSectionVideoSave()
        }
    }

    /// 動画保存の実体。成功時は書き出したファイルの URL を返す（テスト自動化から await できる）。
    /// forceVertical で向きを上書きできる（nil=本の書字方向 isRTL に従う。テスト/横書き確認用）。
    @discardableResult
    func performSectionVideoSave(forceVertical: Bool? = nil) async -> URL? {
        guard engineReady, ttsTask == nil else { return nil }
        applyAudioSettings()
        isSavingVideo = true
        status = String(localized: "セクションの文を収集中…")
        defer { isSavingVideo = false; videoTask = nil }

        // 1) 現在セクションの全文を収集（表示ページは動かさない）。音声保存と同じ経路。
        let collected = await engine.callAsyncJSON(
            "return await window.__reader.ttsCollectSection()")
        guard let sentences = collected as? [String], !sentences.isEmpty else {
            status = String(localized: "保存する文がありません（VOICEVOX起動確認）")
            return nil
        }

        // 2) 読み辞書を適用（読み上げ再生・音声保存と同じ読みにする）。
        let lines = sentences
            .map { prepareSpeech($0) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            status = String(localized: "保存する文がありません（VOICEVOX起動確認）")
            return nil
        }

        // 3) 各行を Swift 側(URLSession)で合成し、query+WAV をレンダラに渡す。
        //    ブラウザから VOICEVOX へ fetch すると foliate:// origin が CORS(403)/ATS で
        //    弾かれるため、通信は必ず Swift で行い、結果だけ harness へ受け渡す。
        var rendLines: [VideoNarrationRenderer.Config.Line] = []
        for (idx, prepared) in lines.enumerated() {
            if Task.isCancelled { status = String(localized: "保存を中止しました"); return nil }
            status = String(
                format: String(localized: "音声を合成中… %lld / %lld"), idx + 1, lines.count)
            do {
                let (queryData, wav) = try await speaker.synthesizeLine(prepared)
                rendLines.append(.init(
                    text: prepared.text,
                    queryJSON: String(decoding: queryData, as: UTF8.self),
                    wav: wav))
            } catch {
                status = "保存エラー: \(error.localizedDescription)（VOICEVOX起動確認）"
                return nil
            }
        }
        guard !rendLines.isEmpty else {
            status = String(localized: "保存する文がありません（VOICEVOX起動確認）")
            return nil
        }

        // 4) narration エンジンでレイアウト→フレーム吸い出し→エンコード。
        //    向きは実際に組まれた本文に合わせる: 縦書きなら縦動画、横書きなら横動画。
        let config = VideoNarrationRenderer.Config.make(
            lines: rendLines,
            theme: model?.settings.theme ?? "dark",
            vertical: forceVertical ?? isVertical)
        let result = await VideoNarrationRenderer.render(config: config) { [weak self] msg in
            self?.status = msg
        }
        guard let result, Task.isCancelled == false else {
            if Task.isCancelled { status = String(localized: "保存を中止しました") }
            return nil
        }

        // 5) ファイルへ書き出し。
        let dir = TTSSaveLocation.resolveDirectory()
        let scoped = dir.startAccessingSecurityScopedResource()
        defer { if scoped { dir.stopAccessingSecurityScopedResource() } }
        let fileURL = dir.appendingPathComponent(saveFileName(ext: result.ext))
        do {
            try result.data.write(to: fileURL)
            status = String(
                format: String(localized: "保存しました: %@"), fileURL.lastPathComponent)
            return fileURL
        } catch {
            status = "保存に失敗: \(error.localizedDescription)"
            return nil
        }
    }

    /// 動画保存を中止する。
    func cancelSaveVideo() {
        videoTask?.cancel()
    }

    /// 見開きずらし。画像ページの組を丸ごと1ページずらす（透明ページの入れ忘れ等の救済）。
    func toggleSpreadOffset() {
        Task {
            let raw = await engine.call("window.__reader.toggleSpread()")
            let offset = (raw as? String)?.contains("\"spreadOffset\":1") == true
            status = offset ? String(localized: "見開きを1ページずらした")
                            : String(localized: "見開きのずらしを戻した")
        }
    }

    // MARK: - フォントサイズ・配色

    func changeFontSize(by delta: Double) {
        let size = min(max((model?.settings.fontSize ?? 1.0) + delta, 0.5), 3.0)
        if var s = model?.settings { s.fontSize = size; model?.updateSettings(s) }
        pushStyle()
    }

    func setTheme(_ name: String) {
        if var s = model?.settings { s.theme = name; model?.updateSettings(s) }
        pushStyle()
    }

    /// テーマ名 → ページ背景色。bridge.js の palettes と同値。
    /// ビュー側は bind 前（model が nil の1フレーム目）でもこれを直接呼べるよう static にしてある。
    static func pageBackgroundColor(theme: String) -> UIColor {
        switch theme {
        case "dark":  return UIColor(hex: 0x1C1C1E)
        case "sepia": return UIColor(hex: 0xF4ECD8)
        case "auto":  return UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(hex: 0x1C1C1E) : UIColor(hex: 0xFFFFFF) }
        default:      return UIColor(hex: 0xFFFFFF)  // light
        }
    }

    /// 現在テーマのページ背景色。
    /// 地肌・WebView 背景をこの色に揃えて、開いた瞬間や幅変化時の白ちらつきを防ぐ。
    /// ※ bind(model:) 前は model が nil で light（白）に落ちるため、
    ///   本を開いた最初のフレームを塗るビュー側では使わないこと（static 版を使う）。
    var pageBackgroundColor: UIColor {
        Self.pageBackgroundColor(theme: model?.settings.theme ?? "light")
    }

    // MARK: - しおり

    func addBookmark() {
        guard let bookID, let cfi = latestCFI, !cfi.isEmpty else { return }
        let bm = Bookmark(
            id: UUID(),
            locatorJSON: cfi,          // CFI を格納（新方式）
            progression: progression,
            excerpt: "",               // foliate 版は抜粋なし（行は「（本文位置）」表示になる）
            createdAt: Date()
        )
        model?.addBookmark(bookID: bookID, bookmark: bm)
    }

    func jump(to bookmark: Bookmark) {
        guard bookmark.locatorJSON.hasPrefix("epubcfi(") else {
            status = String(localized: "旧形式のしおりは開けません（再作成してください）")
            return
        }
        Task { await engine.call("window.__reader.goTo(\(FoliateEngine.quote(bookmark.locatorJSON)))") }
    }

    // MARK: - 本文検索

    func runSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, engineReady else { return }
        searchResults = []
        isSearching = true
        // 結果は bridge から searchHit メッセージで逐次届き、searchDone で完了する。
        Task { await engine.call("window.__reader.runSearch(\(FoliateEngine.quote(q)))") }
    }

    func jumpToSearchResult(_ hit: SearchHit) {
        // 検索ヒットのハイライトは foliate が検索実行時に張っている。位置へ飛ぶだけ。
        Task { await engine.call("window.__reader.goTo(\(FoliateEngine.quote(hit.cfi)))") }
    }

    func clearSearchHighlight() {
        Task { await engine.call("window.__reader.clearSearch()") }
    }

    // MARK: - 読み上げ辞書

    func requestDictionaryRegister(surface: String) {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if showDictionary {
            // 辞書シート表示中は sheet(item:) が提示できない（presenter 使用中）。
            // 先に閉じて、dismiss アニメーション後にフォームを出す。
            showDictionary = false
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                dictInput = ReadingEntry(surface: s)
            }
        } else {
            dictInput = ReadingEntry(surface: s)
        }
    }

    /// 辞書エントリの追加・更新（id が既にあれば置き換え）。
    @discardableResult
    func saveDictWord(_ entry: ReadingEntry) -> Bool {
        var saved = entry
        saved.surface = entry.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.reading = entry.reading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.surface.isEmpty, !saved.reading.isEmpty else { return false }
        if let index = readingEntries.firstIndex(where: { $0.id == saved.id }) {
            readingEntries[index] = saved
        } else {
            readingEntries.append(saved)
        }
        status = "\(saved.surface) → \(SpeechGaps.hiraganaToKatakana(saved.reading))"
        return true
    }

    /// 辞書エントリの削除。
    func deleteDictWord(id: UUID) {
        readingEntries.removeAll { $0.id == id }
    }

    // MARK: - 読み辞書のプレビュー

    /// 辞書を適用した結果（編集シートのプレビューと TestBus 検証用）。
    func previewReadingRules(_ text: String) -> String {
        dictionary.prepare(text).text
    }

    /// 合成に渡す直前の形へ変換する（辞書適用＋挿入境界の記録）。
    func prepareSpeech(_ text: String) -> PreparedSpeech {
        dictionary.prepare(text)
    }
}

// MARK: - 計りレイヤー（測定オーバーレイ・DEBUG限定）

#if DEBUG
extension ReaderModel {
    /// 本文 iframe に計りレイヤー（ルーラー + 16色2レーンの絶対座標リボン）を canvas で注入する。
    /// ネイティブ層の `MeasurementGridView` と **同じ配色・同じ符号化**（cell=10px,
    /// 下位レーン色=palette[cell%16] / 上位レーン色=palette[(cell/16)%16]）を踏襲し、
    /// ネイティブ座標系と Web 座標系で物差しを統一する。座標は viewport(client) 基準。
    /// 実行は bridge の evalInContent（foliate の本文 iframe 内 eval）経由。
    func showMeasureOverlay() async {
        _ = await engine.call("window.__reader.evalInContent(\(FoliateEngine.quote(Self.overlayInjectJS)))")
    }

    /// 計りレイヤーを除去する。
    func hideMeasureOverlay() async {
        _ = await engine.call("window.__reader.evalInContent(\(FoliateEngine.quote(Self.overlayRemoveJS)))")
    }

    /// テスト用のページ送り（実UIと同じ pageStep 経路）。
    func testTurnPage(forward: Bool) async {
        await pageStep(forward: forward)
    }

    /// 任意 JS を本文 iframe で実行し、結果を文字列で返す（座標系の実測・デバッグ用）。
    func evalJS(_ js: String) async -> String {
        let out = await engine.call("window.__reader.evalInContent(\(FoliateEngine.quote(js)))")
        return (out as? String) ?? "<no result>"
    }

    /// 現在ページの画像/本文の `getBoundingClientRect()` を測り、色帯の読み（cell/桁）付きで返す。
    /// 色帯（AI の目）と数値（コード）の両方で裏が取れる。
    func measureOverlay() async -> Any? {
        guard let s = await engine.call(
            "window.__reader.evalInContent(\(FoliateEngine.quote(Self.measureJS)))") as? String,
              let data = s.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        // measureJS は JSON 文字列を返し evalInContent がさらに JSON 化するため、二重を1段剥がす。
        if let inner = parsed as? String, let d2 = inner.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d2) {
            return obj
        }
        return parsed
    }

    /// 16色パレット（ネイティブ MeasurementGridView.palette と一致）。
    private static let paletteJSArray =
        "['#E6194B','#F58231','#FFE119','#BFEF45','#3CB44B','#469990','#42D4F4','#4363D8'," +
        "'#000075','#911EB4','#F032E6','#FABED4','#9A6324','#FFFAC8','#AAFFC3','#A9A9A9']"

    private static let overlayID = "__epub_measure_overlay__"

    /// 計りレイヤーを canvas で描画して document に載せる JS。
    private static let overlayInjectJS = """
    (function(){
      var ID='\(overlayID)';
      var old=document.getElementById(ID); if(old) old.remove();
      var dpr=window.devicePixelRatio||1;
      // 可視ビューポート寸法（縦書き横スクロールで innerWidth はレイアウト幅=大きい値を返すため）。
      var vv=window.visualViewport;
      var W=vv?vv.width:window.innerWidth;
      var H=vv?vv.height:window.innerHeight;
      var cv=document.createElement('canvas');
      cv.id=ID;
      cv.width=Math.round(W*dpr); cv.height=Math.round(H*dpr);
      // WebKit は縦書きRTLで position:fixed;left:0 を「視覚ビューポート原点(0,0)」でなく
      // レイアウトビューポート原点（html 左端。ここでは右に寄っている）に固定する（既知の罠）。
      // → いったん left:0/top:0 で置いて実着地点を getBoundingClientRect で測り、その分だけ
      //   負にシフトして gBCR 空間の(0,0)＝可視ビューポート左上に合わせる。これで canvas ピクセル
      //   (x,y) が getBoundingClientRect の (x,y)（measure と同一座標系）と一致する。
      cv.style.cssText='position:fixed;left:0px;top:0px;'
        +'width:'+W+'px;height:'+H+'px;'
        +'z-index:2147483647;pointer-events:none;margin:0;padding:0;'
        +'writing-mode:horizontal-tb;direction:ltr;';
      document.documentElement.appendChild(cv);
      var land=cv.getBoundingClientRect();
      cv.style.left=(-land.left)+'px';
      cv.style.top=(-land.top)+'px';
      var ctx=cv.getContext('2d'); ctx.scale(dpr,dpr);
      var cell=10;
      var pal=\(paletteJSArray);
      // 上辺(X)・左辺(Y)の 16色2レーン リボン
      ctx.globalAlpha=0.9;
      for(var i=0,x=0;x<W;i++,x+=cell){
        ctx.fillStyle=pal[i%16];             ctx.fillRect(x,0,cell,cell);
        ctx.fillStyle=pal[Math.floor(i/16)%16]; ctx.fillRect(x,cell,cell,cell);
      }
      for(var j=0,y=0;y<H;j++,y+=cell){
        ctx.fillStyle=pal[j%16];             ctx.fillRect(0,y,cell,cell);
        ctx.fillStyle=pal[Math.floor(j/16)%16]; ctx.fillRect(cell,y,cell,cell);
      }
      ctx.globalAlpha=1;
      var band=cell*2;
      // 16セル(=160px)ごとの境界線
      ctx.strokeStyle='rgba(0,0,0,0.6)'; ctx.lineWidth=1; ctx.beginPath();
      for(var k=0,xx=0;xx<W;k++,xx+=cell){ if(k%16===0){ctx.moveTo(xx+0.5,0);ctx.lineTo(xx+0.5,band);} }
      for(var m=0,yy=0;yy<H;m++,yy+=cell){ if(m%16===0){ctx.moveTo(0,yy+0.5);ctx.lineTo(band,yy+0.5);} }
      ctx.stroke();
      // 10% グリッド
      ctx.strokeStyle='rgba(128,128,128,0.35)'; ctx.lineWidth=1; ctx.beginPath();
      for(var g=1;g<10;g++){ var gx=Math.round(W*g/10)+0.5, gy=Math.round(H*g/10)+0.5;
        ctx.moveTo(gx,0);ctx.lineTo(gx,H); ctx.moveTo(0,gy);ctx.lineTo(W,gy); }
      ctx.stroke();
      // 外周枠 + 四辺の % 目盛り
      ctx.strokeStyle='rgba(255,45,85,0.9)'; ctx.lineWidth=2; ctx.strokeRect(1,1,W-2,H-2);
      ctx.beginPath();
      for(var p=0;p<=100;p+=10){ var px=Math.round((W-1)*p/100), py=Math.round((H-1)*p/100);
        ctx.moveTo(px,band);ctx.lineTo(px,band+12); ctx.moveTo(px,H);ctx.lineTo(px,H-12);
        ctx.moveTo(band,py);ctx.lineTo(band+12,py); ctx.moveTo(W,py);ctx.lineTo(W-12,py); }
      ctx.stroke();
      // 中央十字 + viewport 寸法
      var cx=Math.round(W/2), cy=Math.round(H/2);
      ctx.strokeStyle='rgba(52,199,89,0.9)'; ctx.lineWidth=2; ctx.beginPath();
      ctx.moveTo(cx,cy-24);ctx.lineTo(cx,cy+24); ctx.moveTo(cx-24,cy);ctx.lineTo(cx+24,cy); ctx.stroke();
      ctx.fillStyle='rgba(52,199,89,0.95)'; ctx.font='bold 11px -apple-system,monospace';
      ctx.fillText('viewport '+W+'x'+H+' px / cell='+cell+'px', cx+6, cy+18);
      // 凡例 0..F（色→桁の復号用）
      var lx=cx-130, ly=cy+26, sw=15, hh=13, hex='0123456789ABCDEF';
      ctx.fillStyle='rgba(0,0,0,0.55)'; ctx.fillRect(lx-2,ly-2,sw*16+4,hh+4);
      for(var q=0;q<16;q++){ ctx.fillStyle=pal[q]; ctx.fillRect(lx+q*sw,ly,sw,hh);
        ctx.fillStyle='#fff'; ctx.font='bold 9px monospace'; ctx.fillText(hex[q], lx+q*sw+3, ly+10); }
      // 原点マーカー
      ctx.strokeStyle='rgba(255,45,85,1)'; ctx.lineWidth=2; ctx.beginPath();
      ctx.moveTo(0,0);ctx.lineTo(16,0); ctx.moveTo(0,0);ctx.lineTo(0,16); ctx.stroke();
      return true;
    })();
    """

    private static let overlayRemoveJS = """
    (function(){ var e=document.getElementById('\(overlayID)'); if(e){e.remove();return true;} return false; })();
    """

    /// 画像/本文の bbox を測って JSON 文字列で返す JS。色帯の読み（cell/桁）も添える。
    private static let measureJS = """
    (function(){
      var cell=10;
      function r1(v){ return Math.round(v*10)/10; }
      function band(v){ var c=Math.round(v/cell); return {cell:c, low:c%16, high:Math.floor(c/16)%16}; }
      // 可視ビューポート（縦書き横スクロールで innerWidth はレイアウト幅=大きい値を返すため）。
      var vv=window.visualViewport;
      var vw=vv?Math.round(vv.width):window.innerWidth, vh=vv?Math.round(vv.height):window.innerHeight;
      var els=[].slice.call(document.querySelectorAll('img,svg,image'));
      var images=els.map(function(el){
        var r=el.getBoundingClientRect();
        return { tag: el.tagName.toLowerCase(),
          x:r1(r.left), y:r1(r.top), w:r1(r.width), h:r1(r.height),
          right:r1(r.right), bottom:r1(r.bottom),
          gapLeft:r1(r.left), gapRight:r1(vw-r.right), gapTop:r1(r.top), gapBottom:r1(vh-r.bottom),
          centerX:r1(r.left+r.width/2), centerY:r1(r.top+r.height/2),
          leftBand:band(r.left), rightBand:band(r.right) };
      });
      var b=document.body.getBoundingClientRect();
      return JSON.stringify({
        viewport:{w:vw,h:vh,centerX:Math.round(vw/2),centerY:Math.round(vh/2)},
        imageOnlyPage: document.body.classList.contains('reader-image-page'),
        body:{x:r1(b.left),y:r1(b.top),w:r1(b.width),h:r1(b.height)},
        images:images
      });
    })();
    """
}
#endif

// MARK: - カスタムCSSのライブ反映

extension ReaderModel {
    /// カスタムCSSを現在の本に即時反映する（保存後のライブプレビュー用）。
    /// foliate の setStyles は renderer が保持し、以後のページにも適用され続ける。
    func applyUserCSS(_ css: String) {
        Task {
            let dict: [String: Any] = ["userCSS": css]
            await engine.call("window.__reader.setStyle(\(FoliateEngine.jsonArg(dict)))")
        }
    }
}

// MARK: - しおり一覧

/// 左サイドバーに常駐するしおりパネル。上部の「現在地をしおり」ボタンで現在位置を保存し、
/// 下にしおり一覧を並べる。行タップで移動、スワイプ/コンテキストメニューで削除。
private struct BookmarksSidebar: View {
    @ObservedObject var model: AppModel
    let bookID: UUID
    let onAdd: () -> Void
    let onJump: (Bookmark) -> Void
    let onClose: () -> Void

    private var items: [Bookmark] { model.bookmarks(for: bookID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("しおり").font(.title3.weight(.semibold))
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help("サイドバーを閉じる")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Button(action: onAdd) {
                Text("現在地をしおり")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 16)

            if items.isEmpty {
                Text("しおりはありません。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                Spacer()
            } else {
                List {
                    ForEach(items) { bm in
                        Button { onJump(bm) } label: {
                            BookmarkRow(bookmark: bm)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    .onDelete { indexSet in
                        let list = items
                        for i in indexSet where list.indices.contains(i) {
                            model.removeBookmark(bookID: bookID, bookmarkID: list[i].id)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}

// MARK: - 目次サイドバー

/// 目次（nav.xhtml / NCX）から章へ飛ぶサイドバー。階層は DisclosureGroup で畳む。
private struct TOCSidebar: View {
    @ObservedObject var reader: ReaderModel
    let onJump: (TOCEntry) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("目次").font(.title3.weight(.semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help("サイドバーを閉じる")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if reader.toc.isEmpty {
                Text("この本には目次がありません。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                Spacer()
            } else {
                List {
                    ForEach(reader.toc) { entry in
                        TOCRow(entry: entry, currentHref: reader.currentTocHref, onJump: onJump)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}

/// 目次の1行。子を持つ項目は展開でき、見出し自体もタップで飛べる。
private struct TOCRow: View {
    let entry: TOCEntry
    let currentHref: String
    let onJump: (TOCEntry) -> Void
    /// 現在読んでいる章を含む枝は最初から開いておく。
    @State private var expanded: Bool

    init(entry: TOCEntry, currentHref: String, onJump: @escaping (TOCEntry) -> Void) {
        self.entry = entry
        self.currentHref = currentHref
        self.onJump = onJump
        _expanded = State(initialValue: entry.contains(href: currentHref))
    }

    private var isCurrent: Bool { !currentHref.isEmpty && entry.href == currentHref }

    private var label: some View {
        Button { onJump(entry) } label: {
            Text(entry.label.isEmpty ? "（無題）" : entry.label)
                .font(.callout)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        if entry.subitems.isEmpty {
            label.listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(entry.subitems) { sub in
                    TOCRow(entry: sub, currentHref: currentHref, onJump: onJump)
                }
            } label: {
                label
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
    }
}

// MARK: - 本文検索

private struct SearchView: View {
    @ObservedObject var reader: ReaderModel
    let onJump: (SearchHit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("本文を検索", text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { reader.runSearch(query) }
                if reader.isSearching { ProgressView().controlSize(.small) }
                Button("閉じる") { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if reader.searchResults.isEmpty {
                Spacer()
                Text(reader.isSearching ? "検索中…" : "検索語を入力してください")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(reader.searchResults) { hit in
                    Button {
                        onJump(hit)
                        dismiss()
                    } label: {
                        SearchResultRow(hit: hit, query: query)
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 500)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { fieldFocused = true }
        }
    }
}

private struct SearchResultRow: View {
    let hit: SearchHit
    let query: String

    var body: some View {
        // 旧 UI と同じ「前後の文脈は secondary・一致だけ太字」。
        HStack(spacing: 12) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            (
                Text(hit.pre).foregroundColor(.secondary)
                    + Text(hit.match).bold()
                    + Text(hit.post).foregroundColor(.secondary)
            )
            .font(.callout)
            .lineLimit(2)
        }
    }
}

private struct BookmarkRow: View {
    let bookmark: Bookmark

    private var percent: String { "\(Int((bookmark.progression * 100).rounded()))%" }
    private var title: String {
        bookmark.excerpt.isEmpty ? String(localized: "（本文位置）") : bookmark.excerpt
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(percent)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(bookmark.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - カスタムCSSエディタ

/// ユーザー独自CSSを編集するシート。スコープ（この本だけ / 全書籍）を切り替えて編集する。
/// 本別CSSは共通CSSより後に注入され、共通CSSを上書きできる。保存で永続化＋現在ページに即反映。
private struct CSSEditorView: View {
    @Binding var globalCSS: String
    @Binding var bookCSS: String
    let bookTitle: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    enum Scope: String, CaseIterable, Identifiable { case book, global; var id: String { rawValue } }
    @State private var scope: Scope = .book
    @State private var draft = ""

    /// よく使う雛形（タップで挿入）。合成入力が効かない Catalyst でも無タイプで編集できる。
    private static let snippets: [(String, String)] = [
        ("行間広め", "html { line-height: 2.0 !important; }"),
        ("字間", "body { letter-spacing: 0.05em !important; }"),
        ("本文色", "body, p { color: #333 !important; }"),
        ("明朝→ゴシック", "body { font-family: sans-serif !important; }"),
        ("段落間", "p { margin-bottom: 0.8em !important; }"),
    ]

    private var scopeHint: String {
        scope == .book
            ? "「\(bookTitle)」だけに適用。全書籍CSSの後に注入され上書きします。"
            : "すべての本に適用（下地）。書字方向に依存しない指定を推奨（line-height, color, font-family 等）。"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Picker("スコープ", selection: $scope) {
                    Text("この本だけ").tag(Scope.book)
                    Text("全書籍").tag(Scope.global)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: scope) { _ in loadDraft() }

                Text(scopeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.snippets, id: \.0) { name, code in
                            Button(name) {
                                if !draft.isEmpty && !draft.hasSuffix("\n") { draft += "\n" }
                                draft += code + "\n"
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                    .padding(.horizontal)
                }

                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .border(Color.secondary.opacity(0.3))
                    .padding(.horizontal)
            }
            .padding(.vertical, 8)
            .navigationTitle("カスタムCSS")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        commitDraft()
                        onSave()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("クリア", role: .destructive) { draft = "" }
                }
            }
            .onAppear { loadDraft() }
        }
    }

    /// 現在スコープの保存値を draft に読み込む。
    private func loadDraft() {
        draft = (scope == .book) ? bookCSS : globalCSS
    }

    /// draft を現在スコープの保存先へ書き戻す。
    private func commitDraft() {
        if scope == .book { bookCSS = draft } else { globalCSS = draft }
    }
}

// MARK: - 読み上げ辞書シート

/// 「辞書」ボタンから開くシート。語もパターンも同じ一覧に並び、適用レイヤー順に表示する。
private struct DictionarySheet: View {
    @ObservedObject var reader: ReaderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EntryListView(reader: reader)
                .navigationTitle("読み上げ辞書")
                .navigationDestination(for: ReadingEntry.self) { entry in
                    EntryEditForm(reader: reader, input: entry)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("閉じる") { dismiss() }
                    }
                }
        }
    }
}

/// 読み辞書の一覧。適用レイヤーごとに区切って並べるので、置換の順番がそのまま目に見える。
private struct EntryListView: View {
    @ObservedObject var reader: ReaderModel
    @State private var testInput = ""

    /// レイヤー降順のグループ（＝実際に適用される順）。同レイヤー内は長い表記が先。
    private var groups: [(layer: Int, entries: [ReadingEntry])] {
        let grouped = Dictionary(grouping: reader.readingEntries, by: \.layer)
        return grouped
            .map { layer, entries in
                (layer: layer, entries: entries.sorted { $0.surface.count > $1.surface.count })
            }
            .sorted { $0.layer > $1.layer }
    }

    var body: some View {
        List {
            if reader.readingEntries.isEmpty {
                Text("登録された語はありません")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.layer) { group in
                Section("レイヤー \(group.layer)") {
                    ForEach(group.entries) { entry in
                        NavigationLink(value: entry) { EntryRow(entry: entry) }
                    }
                }
            }
            Section {
                NavigationLink(value: ReadingEntry(surface: reader.selectedText)) {
                    Label("語を追加", systemImage: "plus")
                }
            } footer: {
                Text("上のレイヤーから順に置き換え、置き換えた部分は下のレイヤーでは触りません。長い語を上に置けば、1文字の語に食われません。読み上げにだけ効き、画面表示は変わりません。")
            }
            Section("テスト") {
                TextField("試したい文を入力", text: $testInput)
                if !testInput.isEmpty {
                    Label(reader.previewReadingRules(testInput), systemImage: "speaker.wave.2")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 一覧の1行（表記 → 読み と、効き方を表すしるし）。
private struct EntryRow: View {
    let entry: ReadingEntry

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.surface)
                .font(entry.kind == .pattern ? .system(.body, design: .monospaced) : .body)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            Text(entry.reading)
                .foregroundStyle(.secondary)
            Spacer()
            if entry.padsBoundary {
                Image(systemName: "arrow.left.and.right")
                    .foregroundStyle(.secondary)
                    .help("前後に区切りを入れて、隣の語と続けて解析されるのを防ぐ")
            }
            if entry.kind == .pattern {
                Text("パターン")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !entry.enabled {
                Text("無効")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(entry.enabled ? 1 : 0.5)
    }
}

/// 辞書1件の登録/編集フォーム。右クリック（シート）と辞書シート内（プッシュ）の両方から使う。
private struct EntryEditForm: View {
    @ObservedObject var reader: ReaderModel
    @State var input: ReadingEntry
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    /// まだ辞書に無い＝新規登録。
    private var isNew: Bool { !reader.readingEntries.contains { $0.id == input.id } }

    /// 正規表現としてコンパイルできるか（空は「未入力」なので警告しない）。
    private var patternIsValid: Bool {
        input.kind == .word || input.surface.isEmpty
            || (try? NSRegularExpression(pattern: input.surface)) != nil
    }

    var body: some View {
        Form {
            Section {
                Picker("照合", selection: $input.kind) {
                    ForEach(ReadingEntryKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("表記") {
                TextField(
                    input.kind == .word ? "本文中の書き方（例: 斎ひとし）" : "正規表現（例: 第(\\d+)話）",
                    text: $input.surface)
                    .font(input.kind == .pattern ? .system(.body, design: .monospaced) : .body)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !patternIsValid {
                    Label("正規表現が不正です（この行は無視されます）", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
            }
            Section("読み") {
                TextField(
                    input.kind == .word ? "カタカナで入力（ひらがな可）" : "置換後（$1 で捕捉を参照）",
                    text: $input.reading)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section {
                Stepper(value: $input.layer, in: ReadingEntry.layerRange) {
                    Text("レイヤー \(input.layer)")
                }
            } footer: {
                Text("大きいほど先に置き換わり、置き換えた部分は下のレイヤーでは触られません。「斎藤ひとし」を「斎」より上に置けば、1文字の語に壊されません。")
            }
            Section {
                Toggle("前後に区切りを入れる", isOn: $input.padsBoundary)
                Toggle("有効", isOn: $input.enabled)
            } footer: {
                Text("区切りを入れると、隣の語と続けて解析されて読み違えるのを防げます。区切りで生じる無音は合成前に取り除くので、間延びはしません。")
            }
            if failed {
                Text("表記と読みの両方を入力してください")
                    .foregroundStyle(.red)
            }
            Section {
                Button(isNew ? "登録" : "保存") { save() }
                    .disabled(input.surface.trimmingCharacters(in: .whitespaces).isEmpty
                        || input.reading.trimmingCharacters(in: .whitespaces).isEmpty)
                if !isNew {
                    Button("この語を削除", role: .destructive) {
                        reader.deleteDictWord(id: input.id)
                        close()
                    }
                }
            }
        }
        .navigationTitle(isNew ? "読み上げ辞書に登録" : "語を編集")
    }

    private func save() {
        if reader.saveDictWord(input) { close() } else { failed = true }
    }

    /// シート提示（右クリック）とプッシュ提示（辞書シート内）の両方を閉じる。
    private func close() {
        if reader.dictInput != nil { reader.dictInput = nil }
        dismiss()
    }
}
