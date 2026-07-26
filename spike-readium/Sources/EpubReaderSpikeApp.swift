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
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .commands {
            // 「ファイル」メニューに「開く…」（⌘O）を追加。
            CommandGroup(replacing: .newItem) {
                Button("開く…") { model.requestOpenPanel = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}

/// 書棚 ⇄ リーダーの切り替え。EPUB のドロップ受付とファイル選択もここで扱う。
struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let book = model.openedBook {
                ReaderScreen(model: model, book: book)
                    .id(book.id) // 本を変えたらリーダーを作り直す
            } else {
                ShelfView(model: model)
            }
        }
        // ウィンドウへのドラッグ＆ドロップで EPUB を開く。
        // ※ `.dropDestination(for: URL.self)` は Catalyst で Finder のファイル(public.file-url)を
        //   受け取れないことがある（public.url=Web URL 前提になりがち）。NSItemProvider から
        //   file-url を明示的に読む堅牢版にする（URL 表現／Data 表現の両対応）。
        .onDrop(of: [.epub, .fileURL], isTargeted: nil) { providers in
            handleDropped(providers)
        }
        .task { model.seedSampleIfNeeded() }
        #if DEBUG
        .task {
            // DEBUG 限定: UI テスト用コマンドバスを起動しモデルを注入。
            TestBus.shared.model = model
            TestBus.shared.start()
        }
        #endif
        // メニュー/ボタンからのファイル選択。
        .fileImporter(
            isPresented: $model.requestOpenPanel,
            allowedContentTypes: [.epub],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                model.open(url: url)
            }
        }
    }

    /// ドロップされた NSItemProvider 群から EPUB を取り出して開く（書棚・リーダー共通の EPUBDrop 経由）。
    private func handleDropped(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if EPUBDrop.load(from: provider, deliver: { model.open(url: $0) }) { accepted = true }
        }
        return accepted
    }
}

// MARK: - EPUB ドロップの堅牢ローダ（書棚・リーダー共通）

/// ドロップされた `NSItemProvider` から EPUB のファイル URL を取り出す。
/// Catalyst の Finder ドラッグは `public.file-url` を持たず `org.idpf.epub-container`（+ finder.node）で
/// 渡るため、`loadItem(public.file-url)` は失敗する。**in-place ファイル表現（オリジナルの実パス）**を
/// 優先し、取れない場合のみテンポラリコピーを安定領域へ退避してから開く。
enum EPUBDrop {
    /// - Returns: この provider を受理して読み込みを開始したか。
    @discardableResult
    static func load(from provider: NSItemProvider, deliver: @escaping (URL) -> Void) -> Bool {
        let ids = provider.registeredTypeIdentifiers
        let typeID = ids.first(where: { UTType($0)?.conforms(to: .epub) == true })
            ?? ids.first(where: { UTType($0)?.conforms(to: .data) == true || UTType($0)?.conforms(to: .fileURL) == true })
        guard let typeID else {
            dlog("[Drop] no usable type in \(ids)")
            return false
        }
        dlog("[Drop] types=\(ids) -> using \(typeID)")
        // 1) in-place（オリジナルの実パス。sandbox 無効なので以後も読める）。
        provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeID) { url, isInPlace, err in
            if let url, url.pathExtension.lowercased() == "epub" {
                dlog("[Drop] in-place \(url.path) isInPlace=\(isInPlace)")
                DispatchQueue.main.async { deliver(url) }
                return
            }
            dlog("[Drop] in-place failed (err=\(String(describing: err))); trying copy")
            // 2) コピー（テンポラリはクロージャ後に消えるので安定領域へ複製してから開く）。
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { tmp, err2 in
                guard let tmp, let stable = copyToImports(tmp) else {
                    dlog("[Drop] copy path failed err=\(String(describing: err2))")
                    return
                }
                dlog("[Drop] copied to \(stable.path)")
                DispatchQueue.main.async { deliver(stable) }
            }
        }
        return true
    }

    /// テンポラリの EPUB を Application Support/DroppedImports に複製して安定パスを返す。
    private static func copyToImports(_ src: URL) -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("DroppedImports", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        try? fm.removeItem(at: dest)
        do { try fm.copyItem(at: src, to: dest); return dest }
        catch { dlog("[Drop] copy failed: \(error)"); return nil }
    }
}
