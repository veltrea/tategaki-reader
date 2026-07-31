import SwiftUI
import UniformTypeIdentifiers

/// デバッグ時だけログに出す。読み込んだ本の絶対パスは持ち主の蔵書そのものなので、
/// リリースビルドでは unified log に残さない。
@inline(__always) func dlog(_ message: @autoclosure () -> String) {
    #if DEBUG
    NSLog("%@", message())
    #endif
}

@main
struct EpubReaderSpikeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .commands {
            // アプリメニューの「環境設定… ⌘,」。Catalyst の既定メニューには入らないので自前で置く。
            // 書棚・リーダーのどちらからでも開けるよう、フラグは AppModel が持つ。
            CommandGroup(replacing: .appSettings) {
                Button("環境設定…") { model.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // 「ファイル > 開く…（⌘O）」は UIKit 既定の項目が ⌘O を押さえており、
            // SwiftUI 側で同じキーの項目を足すと黙って捨てられる（⌘F と同じ）。
            // AppDelegate の buildMenu で既定側を差し替えている。
            CommandGroup(replacing: .newItem) { }
            // 「ファイル > 書棚を切り替える／書棚を管理…」。
            // 書棚の切り替えは「どの蔵書を読むか」の選択なので、開く・書き出しと同じファイル側に置く。
            CommandGroup(after: .newItem) {
                ShelfProfileCommands(model: model)
            }
            // 「ファイル > 書き出し」。開く…（上）と保存系の間に置く。
            CommandGroup(after: .saveItem) {
                ExportCommands(model: model)
            }
            // 「編集 > 検索…（⌘F）」は SwiftUI では足せない（⌘F が UIKit の予約キーで、
            // 同じキーの項目は黙って捨てられる）。AppDelegate の buildMenu で差し替えている。
            // 環境設定の「表示」タブと同じ項目を「表示」メニューにも置く。
            // Catalyst が既定で用意する View メニューへ足す（自前の CommandMenu("表示") を
            // 作ると同じ名前のメニューが二つ並んでしまう）。
            CommandGroup(after: .toolbar) {
                DisplayCommands(model: model)
            }
            // 「移動」「読み上げ」は Catalyst の既定メニューに無いので新規に作る
            //（既定に在る「表示」と違い、同名が二つ並ぶ心配がない）。
            CommandMenu("移動") {
                NavigationCommands(model: model)
            }
            CommandMenu("読み上げ") {
                SpeechCommands(model: model)
            }
        }
    }
}

/// メニューバーの下ごしらえ。
///
/// UIKit が Catalyst アプリへ既定で入れる「フォーマット」メニューを丸ごと外す。
/// 中身（フォント／テキスト／拡大・縮小）はテキスト編集ビューが受け皿になる項目で、
/// 本文が WKWebView のこのアプリには効く相手がいない＝押せない項目が並ぶだけになる。
/// HIG がメニューバーに求めるのはアプリ名・ファイル・編集・ウインドウ・ヘルプで、
/// フォーマットは文書編集アプリ向けの任意メニューなので、外して差し支えない。
/// また「編集 > 検索…／次を検索／…」も同じ理由（応える相手がテキストビューしかいない）で
/// 常時グレーだったので、アプリ自前の本文検索へ差し替える。
///
/// なぜ SwiftUI の `.commands` でやらないか: Catalyst は ⌘F・⌘+・⌘- を UIKit 側が押さえており、
/// 同じキーを付けた項目は**メニューから黙って捨てられる**（実測。項目ごと消える）。
/// `remove` してから SwiftUI 側で足しても、組み立ての順番が違うので間に合わない。
/// buildMenu の中で `replace` すれば、その組み立ての中で ⌘F を正規に受け取れる。
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// 「開く…」の対象。SwiftUI 側（RootView の .task）から注入する。
    static weak var model: AppModel?

    #if DEBUG
    /// 組み上がったメニューの識別子一覧（TestBus の menuDump で読む）。
    /// UIKit 既定の項目は識別子を推測すると外すので、実物を見てから remove する。
    static var menuDump: [String] = []
    #endif

    /// 溜めてある書棚の変更を書き切ってから終わる。
    /// 蔵書の保存はまとめて（0.7 秒ぶん）行うので、書く前に落ちる窓がここだけ開く。
    @MainActor
    func applicationWillTerminate(_ application: UIApplication) {
        Self.model?.flushPendingSaves()
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        builder.remove(menu: .format)
        // 「編集」のスペルと文法・自動置換・変換・スピーチ等も、テキスト編集ビュー向けの
        // 一式で本文が WKWebView のこのアプリでは出番がない。検索欄などの入力中に要る機能は、
        // 右クリックや OS のショートカットから届く。
        for id in [UIMenu.Identifier.spelling, .substitutions, .transformations,
                   .speech, .lookup, .share] {
            builder.remove(menu: id)
        }
        // 末尾に残る「作文ツール／自動入力／音声入力を開始／絵文字と記号」はここでは外せない。
        // UIKit がメニューを組み終わった後に AppKit が差し込むもので、この時点の編集メニューには
        // 存在しない（menuDump で確認済み）。Info.plist の NSDisabledDictationMenuItem /
        // NSDisabledCharacterPaletteMenuItem も Catalyst では効かなかった。
        // どれも常時淡色なので残してある。
        let find = UIKeyCommand(
            title: String(localized: "検索…"),
            action: #selector(FindInBookAction.findInBook(_:)),
            input: "f",
            modifierFlags: .command)
        builder.replace(menu: .find, with: UIMenu(title: "", options: .displayInline, children: [find]))
        // 既定の「開く…」は書類ベースのアプリ向けで、押しても何も起きなかった。
        // 同じ位置へ EPUB を選ぶパネルを繋ぐ。
        let open = UIKeyCommand(
            title: String(localized: "開く…"),
            action: #selector(openBookPanel(_:)),
            input: "o",
            modifierFlags: .command)
        // フォルダはファイルと同じパネルでは選べない（BookOpenPanel の説明を参照）ので、
        // 「まとめて登録」は独立した項目にする。
        let openFolder = UIKeyCommand(
            title: String(localized: "フォルダから追加…"),
            action: #selector(addBooksFromFolderPanel(_:)),
            input: "o",
            modifierFlags: [.command, .shift])
        builder.replace(menu: .open,
                        with: UIMenu(title: "", options: .displayInline, children: [open, openFolder]))

        #if DEBUG
        // 消し残しの識別子を実物から拾う（推測だと外れる。実際 autofill/writing-tools は外れた）。
        Self.menuDump = []
        for root in [UIMenu.Identifier.edit, .file, .view] {
            guard let menu = builder.menu(for: root) else { continue }
            for child in menu.children {
                if let sub = child as? UIMenu {
                    Self.menuDump.append("\(root.rawValue) > menu \(sub.identifier.rawValue) 「\(sub.title)」")
                    for leaf in sub.children {
                        if let m = leaf as? UIMenu {
                            Self.menuDump.append("    └ menu \(m.identifier.rawValue) 「\(m.title)」")
                        } else if let c = leaf as? UICommand {
                            Self.menuDump.append("    └ command 「\(c.title)」")
                        } else {
                            Self.menuDump.append("    └ \(type(of: leaf))")
                        }
                    }
                } else if let cmd = child as? UICommand {
                    Self.menuDump.append("\(root.rawValue) > command 「\(cmd.title)」")
                }
            }
        }
        #endif
    }

}

/// 「開く…」の実行先。**レスポンダ共通**に生やしてある。
///
/// SwiftUI のライフサイクルでは AppDelegate がレスポンダチェーンに載らず
/// `canPerformAction` すら呼ばれない（実測。項目が常時淡色になる）。画面側の VC に置く手もあるが、
/// 書棚・リーダー・シートのどこにフォーカスがあっても効いてほしいので、UIResponder の拡張にする。
/// これならチェーン上の誰かが必ず応答し、UIKit の既定判定でメニューが有効になる。
extension UIResponder {
    @objc func openBookPanel(_ sender: Any?) {
        AppDelegate.model?.requestOpenPanel = true
    }

    /// 「フォルダから追加…」。選んだフォルダの中の本をまとめて書棚へ入れる。
    @objc func addBooksFromFolderPanel(_ sender: Any?) {
        AppDelegate.model?.requestFolderPanel = true
    }
}

/// 「検索…」の実行先はここではなくリーダーのホストビュー（DictionaryHostViewController）。
/// AppDelegate は SwiftUI のライフサイクルではレスポンダチェーンに載らず、
/// canPerformAction が呼ばれないため、置いても項目が淡色のままになる（実測）。
/// 本文ビューに持たせると「本を開いている間だけ有効」も自然に決まる。
@objc protocol FindInBookAction {
    func findInBook(_ sender: Any?)
}

/// 書棚 ⇄ リーダーの切り替え。EPUB のドロップ受付とファイル選択もここで扱う。
struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    /// スリープタイマーの「時間を指定…」の入力欄（分）。
    @State private var customMinutes = ""
    /// 自動ページ送りの「間隔を指定…」の入力欄（秒）。
    @State private var customInterval = ""

    var body: some View {
        Group {
            if let book = model.openedBook {
                ReaderScreen(model: model, book: book)
                    .id(book.id) // 本を変えたらリーダーを作り直す
            } else {
                ShelfView(model: model)
            }
        }
        // フォルダをまとめて登録しているあいだの帯。書棚・リーダーのどちらにいても見えるよう重ねる。
        .overlay(alignment: .top) { BookImportBanner(model: model) }
        // シャットダウン前の猶予。書棚に戻っていても必ず見えるよう、画面全体に重ねる。
        .overlay { SleepTimerShutdownBanner(timer: model.sleepTimer) }
        .animation(.easeInOut(duration: 0.2), value: model.sleepTimer.shutdownCountdown == nil)
        // 書棚の管理。書棚・リーダーのどちらからでもメニューで開けるよう、ここで提示する。
        .sheet(isPresented: $model.showProfileManager) {
            ShelfProfileSheet(model: model)
        }
        .alert("スリープタイマー", isPresented: $model.showSleepTimerCustom) {
            TextField("分", text: $customMinutes)
            Button("開始") {
                if let m = Int(customMinutes.trimmingCharacters(in: .whitespaces)), m > 0 {
                    model.sleepTimer.start(minutes: m)
                }
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("何分後に読み上げを停止するかを分で入力してください。")
        }
        .alert("自動ページ送り", isPresented: $model.showAutoPagerCustom) {
            TextField("秒", text: $customInterval)
            Button("開始") {
                if let s = Int(customInterval.trimmingCharacters(in: .whitespaces)), s > 0 {
                    model.autoPager.start(seconds: s)
                }
            }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("何秒ごとに次のページへ進むかを秒で入力してください。")
        }
        .onChange(of: model.showAutoPagerCustom) { showing in
            if showing { customInterval = String(model.autoPager.seconds) }
        }
        // 画面から退いたら、溜めてある書棚の変更（読書位置など）を書き切る。
        .onChange(of: scenePhase) { phase in
            if phase != .active { model.flushPendingSaves() }
        }
        .onChange(of: model.showSleepTimerCustom) { showing in
            // 開くたびに前回値を入れておく（続けて同じ長さを使うことが多い）。
            if showing { customMinutes = String(model.sleepTimer.lastMinutes) }
        }
        // ウィンドウへのドラッグ＆ドロップで EPUB を開く。フォルダを落とすと、
        // その中の登録できるファイルを再帰的に集めてまとめて書棚へ入れる。
        // ※ `.dropDestination(for: URL.self)` は Catalyst で Finder のファイル(public.file-url)を
        //   受け取れないことがある（public.url=Web URL 前提になりがち）。NSItemProvider から
        //   file-url を明示的に読む堅牢版にする（URL 表現／Data 表現の両対応）。
        .onDrop(of: ImportableBook.contentTypes + [.fileURL, .folder], isTargeted: nil) { providers in
            handleDropped(providers)
        }
        // Finder で .epub をダブルクリック／アプリのアイコンにドロップしたときの入口。
        // Catalyst では起動時・起動中とも UIScene の openURLContexts 経由で届き、SwiftUI がここへ流す。
        // アイコンにはフォルダも落とせるので、ウィンドウへのドロップと同じ扱い（中身をまとめて登録）にする。
        .onOpenURL { url in
            dlog("[Open] onOpenURL \(url.absoluteString)")
            guard url.isFileURL else { return }
            model.add(urls: [url])
        }
        .task {
            model.seedSampleIfNeeded()
            // メニュー「開く…」（UIKit 側で組む）の対象。
            AppDelegate.model = model
        }
        .task {
            // 外部からの操作口（読み辞書の自動化・UI テスト）を開いてモデルを注入。
            // 配布版で受け付けるのは辞書まわりだけ（TestBus.releaseCommands）。
            TestBus.shared.model = model
            TestBus.shared.start()
        }
        // メニュー「開く…」と書棚の「本を追加」からのファイル選択。
        // ドロップと同じく、フォルダを選べば中の本をまとめて登録する。
        .onChange(of: model.requestOpenPanel) { requested in
            guard requested else { return }
            model.requestOpenPanel = false
            BookOpenPanel.present { model.add(urls: $0) }
        }
        // 「フォルダから追加…」。フォルダだけを選ぶパネル（下の requestFolderPanel の説明を参照）。
        .onChange(of: model.requestFolderPanel) { requested in
            guard requested else { return }
            model.requestFolderPanel = false
            BookOpenPanel.present(foldersOnly: true) { model.add(urls: $0, openIfSingle: false) }
        }
    }

    /// ドロップされた NSItemProvider 群から本を取り出して書棚へ入れる（書棚・リーダー共通の BookDrop 経由）。
    ///
    /// provider ごとに非同期で解決されるので、複数まとめて落とされたときは
    /// 届いた順に取り込みの列へ並ぶ（`AppModel` が直列に処理する）。
    private func handleDropped(_ providers: [NSItemProvider]) -> Bool {
        // 複数落とされたときは1冊でも開かない（どれを開くべきか決められないため）。
        let single = providers.count == 1
        var accepted = false
        for provider in providers {
            if BookDrop.load(from: provider, deliver: { model.add(urls: $0, openIfSingle: single) }) {
                accepted = true
            }
        }
        return accepted
    }
}

// MARK: - 本／フォルダを選ぶファイルパネル

/// 本とフォルダを選ぶファイルパネル。
///
/// SwiftUI の `.fileImporter` は Catalyst だと反応しないこと（メニューから叩いても
/// パネルが出ない）があったので、UIKit のドキュメントピッカーを直接提示する。
/// App Sandbox 無効なので、選んだ実パスをコピーせずそのまま読める（asCopy: false）。
///
/// フォルダと複数選択を許すのは、ドロップと同じことをパネルからもできるようにするため
///（受け取った側は同じ `AppModel.add(urls:)` を通り、フォルダは中身へ展開される）。
@MainActor
final class BookOpenPanel: NSObject, UIDocumentPickerDelegate {
    /// 提示中のデリゲート。UIKit 側は delegate を weak で持つので、ここで生かしておく。
    private static var current: BookOpenPanel?

    private let completion: ([URL]) -> Void

    private init(completion: @escaping ([URL]) -> Void) {
        self.completion = completion
    }

    static func present(foldersOnly: Bool = false, completion: @escaping ([URL]) -> Void) {
        guard let host = topViewController() else {
            dlog("[Open] no view controller to present the panel")
            return
        }
        let panel = BookOpenPanel(completion: completion)
        current = panel
        // 本とフォルダを1枚のパネルで混ぜられない。Catalyst のパネルはフォルダを
        // 「潜る先」として扱い、`.folder` を許可の一覧に足してもフォルダを選んだ状態では
        // 『開く』が押せないまま（実測）。フォルダ**だけ**の一覧にすると初めて選べるので、
        // 入口を分けてある。
        let types: [UTType] = foldersOnly ? [.folder] : ImportableBook.contentTypes
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = panel
        host.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        defer { Self.current = nil }
        guard !urls.isEmpty else { return }
        dlog("[Open] picked \(urls.count) item(s)")
        completion(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Self.current = nil
    }

    /// いま一番手前にいるビューコントローラ（シートが出ていればその上へ重ねる）。
    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        var vc = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

// ドロップの受け取り（フォルダ展開を含む）は BookImport.swift の `BookDrop` に移した。
