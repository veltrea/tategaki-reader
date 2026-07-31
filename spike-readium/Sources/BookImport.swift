import SwiftUI
import UniformTypeIdentifiers

// MARK: - 書棚に入れられるファイル

/// 書棚に登録できるファイルの種類と、フォルダからの拾い集め。
///
/// 対応形式が増えたときにドロップ・ファイルパネル・フォルダ走査の三か所で食い違わないよう、
/// 「何を受け付けるか」はここだけに書く。
enum ImportableBook {
    /// ドロップやファイルパネルで受け付ける型。
    static let contentTypes: [UTType] = [.epub]
    /// 拡張子での判定（フォルダを走査するときは UTType 解決より速く確実）。
    static let fileExtensions: Set<String> = ["epub"]

    static func isImportable(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// 一度に取り込む上限。フォルダを取り違えてホームディレクトリ全体を落とされても、
    /// 走査と登録が果てしなく続かないようにする。
    static let collectLimit = 5_000

    /// フォルダを再帰的にたどって、登録できるファイルを集める。
    ///
    /// 並びは Finder と同じ感覚になるようパスの自然順（数字を数として比較）。書棚は
    /// 追加順に積むので、この並びがそのまま「1巻→2巻→…」の並びになる。
    static func collect(in folder: URL, limit: Int = collectLimit) -> [URL] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        var found: [URL] = []
        for case let url as URL in walker {
            guard isImportable(url) else { continue }
            // .epub という名前のフォルダを本と取り違えないよう実体を確かめる。
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            found.append(url)
            if found.count >= limit { break }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// URL の並びを「登録できるファイル」の並びへ展開する（フォルダはその中身に置き換える）。
    /// 重複（同じ本がフォルダ経由とファイル経由の両方で来た等）はここで落とす。
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        for url in urls {
            // ドロップ／ファイルパネル由来の URL は権限つきで渡ってくる。走査のあいだだけ開く
            //（App Sandbox 無効なので実際には無くても読めるが、無害な保険）。
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let items = isDir.boolValue ? collect(in: url) : (isImportable(url) ? [url] : [])
            for item in items where seen.insert(item.standardizedFileURL.path).inserted {
                out.append(item)
            }
        }
        return out
    }
}

// MARK: - ドロップの堅牢ローダ（書棚・リーダー共通）

/// ドロップされた `NSItemProvider` から、登録できるファイルの URL を取り出す。
///
/// Catalyst の Finder ドラッグは `public.file-url` を持たず `org.idpf.epub-container`（+ finder.node）で
/// 渡るため、`loadItem(public.file-url)` は失敗する。**in-place ファイル表現（オリジナルの実パス）**を
/// 優先し、取れない場合のみテンポラリコピーを安定領域へ退避してから開く。
///
/// フォルダは中身を再帰的に集めて渡す。フォルダに対しては**コピー経路を絶対に使わない**
///（蔵書フォルダを丸ごと複製しかねないため）。実パスが取れなければ諦める。
enum BookDrop {
    /// - Parameter deliver: 取り込むファイル群（main で呼ばれる）。フォルダを開いた結果が
    ///   空だったときは空配列で呼ぶ（「1冊も無かった」と伝えるため）。
    /// - Returns: この provider を受理して読み込みを開始したか。
    @discardableResult
    static func load(from provider: NSItemProvider, deliver: @escaping ([URL]) -> Void) -> Bool {
        let ids = provider.registeredTypeIdentifiers
        // フォルダを先に見る。Finder のフォルダは public.folder のほかに public.file-url も
        // 持つことがあり、ファイルとして拾うと中身をたどらないまま終わる。
        if let folderType = ids.first(where: { UTType($0)?.conforms(to: .folder) == true }) {
            dlog("[Drop] types=\(ids) -> folder \(folderType)")
            loadFolder(provider, typeID: folderType, deliver: deliver)
            return true
        }
        let typeID = ids.first(where: { UTType($0)?.conforms(to: .epub) == true })
            ?? ids.first(where: { UTType($0)?.conforms(to: .data) == true
                               || UTType($0)?.conforms(to: .fileURL) == true })
        guard let typeID else {
            dlog("[Drop] no usable type in \(ids)")
            return false
        }
        dlog("[Drop] types=\(ids) -> using \(typeID)")
        loadFile(provider, typeID: typeID, deliver: deliver)
        return true
    }

    /// フォルダの実パスを取り、その場で中身を集める。
    ///
    /// in-place の URL はコールバックを抜けると無効になりうるので、走査は**この中で**済ませる。
    /// 集めた個々のファイル URL は実パスなので、以後もそのまま読める（App Sandbox 無効）。
    private static func loadFolder(_ provider: NSItemProvider, typeID: String,
                                   deliver: @escaping ([URL]) -> Void) {
        provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeID) { url, isInPlace, err in
            if let url {
                dlog("[Drop] folder in-place \(url.path) isInPlace=\(isInPlace)")
                DispatchQueue.main.async { deliver(collectAccessing(url)) }
                return
            }
            dlog("[Drop] folder in-place failed (err=\(String(describing: err))); trying file-url")
            // フォルダはコピーで受け取らない（蔵書ごと複製しかねない）。パスだけをもらう。
            loadFileURL(provider) { url in
                guard let url else { return }
                DispatchQueue.main.async { deliver(collectAccessing(url)) }
            }
        }
    }

    /// ファイルとして落ちてきたものを解決する。実体がフォルダだった場合（型が
    /// `com.apple.finder.node` しか無い等）もここで気付いて中身を集める。
    ///
    /// 順は in-place（実パス）→ file-url（実パス）→ コピー。**フォルダはコピーまで落とさない**
    /// ——蔵書フォルダを丸ごと複製しかねないため、実パスが取れなければ諦める。
    private static func loadFile(_ provider: NSItemProvider, typeID: String,
                                 deliver: @escaping ([URL]) -> Void) {
        provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeID) { url, isInPlace, err in
            if let url, let urls = resolve(url) {
                dlog("[Drop] in-place \(url.path) isInPlace=\(isInPlace) -> \(urls.count) file(s)")
                DispatchQueue.main.async { deliver(urls) }
                return
            }
            dlog("[Drop] in-place failed (err=\(String(describing: err))); trying file-url")
            loadFileURL(provider) { fileURL in
                if let fileURL, let urls = resolve(fileURL) {
                    dlog("[Drop] file-url \(fileURL.path) -> \(urls.count) file(s)")
                    DispatchQueue.main.async { deliver(urls) }
                    return
                }
                if let fileURL, isDirectory(fileURL) { return } // フォルダはコピーしない
                // 最後の手段: コピー（テンポラリはクロージャ後に消えるので安定領域へ複製する）。
                provider.loadFileRepresentation(forTypeIdentifier: typeID) { tmp, err2 in
                    guard let tmp, !isDirectory(tmp), let stable = copyToImports(tmp) else {
                        dlog("[Drop] copy path failed err=\(String(describing: err2))")
                        return
                    }
                    dlog("[Drop] copied to \(stable.path)")
                    DispatchQueue.main.async { deliver([stable]) }
                }
            }
        }
    }

    /// `public.file-url` から実パスをもらう（持っていなければ nil を返して次の手へ）。
    private static func loadFileURL(_ provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        let type = UTType.fileURL.identifier
        guard provider.hasItemConformingToTypeIdentifier(type) else {
            dlog("[Drop] no file-url representation")
            completion(nil)
            return
        }
        provider.loadItem(forTypeIdentifier: type) { item, err in
            let url = fileURL(from: item)
            if url == nil { dlog("[Drop] file-url failed err=\(String(describing: err))") }
            completion(url)
        }
    }

    /// フォルダを走査する（セキュリティスコープは expand が開く）。
    private static func collectAccessing(_ url: URL) -> [URL] {
        let found = ImportableBook.expand([url])
        dlog("[Drop] folder \(url.lastPathComponent) -> \(found.count) file(s)")
        return found
    }

    /// ファイル／フォルダのどちらで来ても、取り込む対象へ均す。対象外なら nil。
    private static func resolve(_ url: URL) -> [URL]? {
        if isDirectory(url) { return collectAccessing(url) }
        return ImportableBook.isImportable(url) ? [url] : nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// `loadItem` が返す値（URL / NSURL / ブックマークや文字列の Data）からファイル URL を作る。
    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let data = item as? Data {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) { return url }
            if let text = String(data: data, encoding: .utf8) { return URL(string: text) }
        }
        if let text = item as? String { return URL(string: text) }
        return nil
    }

    /// テンポラリの本を Application Support/DroppedImports に複製して安定パスを返す。
    private static func copyToImports(_ src: URL) -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = appSupport.appendingPathComponent("DroppedImports", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        try? fm.removeItem(at: dest)
        do { try fm.copyItem(at: src, to: dest); return dest }
        catch { dlog("[Drop] copy failed: \(error)"); return nil }
    }
}

// MARK: - 取り込み中の帯

/// フォルダをまとめて登録しているあいだの進み具合と、終わったときの短い報告。
///
/// 書棚にいても本を開いていても見えるよう RootView に重ねる（シャットダウン告知と同じ置き方）。
/// 画面の操作は塞がない——何十冊もの登録を待つあいだ、読書ができなくなるのは困るため。
struct BookImportBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack {
            if let progress = model.importProgress {
                running(progress)
            } else if let report = model.importReport {
                finished(report)
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: model.importProgress)
        .animation(.easeInOut(duration: 0.2), value: model.importReport)
    }

    private func running(_ p: AppModel.ImportProgress) -> some View {
        HStack(spacing: 14) {
            ProgressView(value: p.fraction)
                .progressViewStyle(.circular)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: String(localized: "書棚に登録中… %lld / %lld"),
                            Int64(p.done), Int64(p.total)))
                    .font(.callout.weight(.semibold))
                Text(p.current)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 220, alignment: .leading)
            Button("中止") { model.cancelImport() }
                .buttonStyle(.bordered)
        }
        .modifier(BannerChrome())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("importBanner")
        .accessibilityLabel("取り込み中")
        .accessibilityValue(String(format: String(localized: "%lld / %lld"),
                                   Int64(p.done), Int64(p.total)))
    }

    private func finished(_ report: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .foregroundStyle(.secondary)
            Text(report)
                .font(.callout)
            Button {
                model.importReport = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .modifier(BannerChrome())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("importReport")
        .accessibilityLabel(report)
    }
}

/// 帯の見た目（進行中・報告で共通）。
private struct BannerChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
            // ShapeStyle の .separator は Catalyst 17 以降。配備先が 16 なので UIColor から作る。
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(uiColor: .separator)))
            .shadow(radius: 12)
            .padding(.top, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
