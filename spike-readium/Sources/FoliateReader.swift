import Foundation
import UIKit
import WebKit

// MARK: - 現在の本のバイト列を scheme handler へ供給する共有ボックス

final class FoliateBookProvider {
    var bookData: Data?
}

// MARK: - foliate: スキームのリソース配信
// foliate:///app/...            → アプリバンドル Resources/foliate/...（reader.html・bridge.js・foliate-js/*）
// foliate:///book/current.epub  → 現在開いている EPUB のバイト列

final class FoliateSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "foliate"
    private let provider: FoliateBookProvider
    private let root: URL

    init(provider: FoliateBookProvider) {
        self.provider = provider
        self.root = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("foliate", isDirectory: true)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(Self.err("no url")); return }
        let path = url.path

        if path == "/book/current.epub" {
            guard let data = provider.bookData else {
                task.didFailWithError(Self.err("no book")); return
            }
            respond(task, url: url, data: data, mime: "application/epub+zip")
            return
        }

        if path.hasPrefix("/app/") {
            let rel = String(path.dropFirst("/app/".count))
            let fileURL = root.appendingPathComponent(rel)
            // ディレクトリトラバーサル防止（root 配下のみ許可）。
            guard fileURL.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path),
                  let data = try? Data(contentsOf: fileURL) else {
                task.didFailWithError(Self.err("not found: \(rel)")); return
            }
            respond(task, url: url, data: data, mime: Self.mime(for: fileURL.pathExtension))
            return
        }

        task.didFailWithError(Self.err("unhandled: \(path)"))
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
        let headers = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
        ]
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    private static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "epub": return "application/epub+zip"
        default: return "application/octet-stream"
        }
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "Foliate", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// MARK: - foliate エンジン（WKWebView + JS ブリッジの薄いラッパ）
// reader.html(bridge.js) をロードし、JS 呼び出しと JS→Swift メッセージ配線を提供する。
// リーダー本体（ReaderModel）と書棚のメタデータ抽出（EpubProbe）の両方から使う。

@MainActor
final class FoliateEngine: NSObject, WKScriptMessageHandler {
    let provider = FoliateBookProvider()
    private(set) var webView: WKWebView?
    /// bridge.js からのメッセージ（type キー付き辞書）。
    var onMessage: (([String: Any]) -> Void)?

    /// WebView を生成して reader.html をロードする（既存があれば再利用）。
    /// - Parameter pageBackground: 本文テーマの地色。reader.html の `--page-bg` へ
    ///   atDocumentStart で注入し、本文 iframe 描画前から地肌をテーマ色にする（白ちらつき防止）。
    @discardableResult
    func makeWebView(pageBackground: UIColor? = nil) -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(FoliateSchemeHandler(provider: provider),
                                   forURLScheme: FoliateSchemeHandler.scheme)
        config.userContentController.add(self, name: "foliate")
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // ページの CSS が評価されるより前に地色を決める。load() 後に evaluateJavaScript で
        // 入れると「白 → テーマ色」の1フレームが必ず見えるため、ユーザースクリプトで先回りする。
        let bg = pageBackground ?? UIColor(red: 28/255, green: 28/255, blue: 30/255, alpha: 1)
        config.userContentController.addUserScript(WKUserScript(
            source: Self.pageBackgroundJS(bg),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = true
        // リサイズ中や描画前に「コンテンツの外側」に見える色。既定のシステム色（ライト=白）だと
        // 本を開いた瞬間などに白く光るため、テーマ色（不明なら暗色）にしておく
        //（実テーマ色は host.setPageBackground が上書きする）。
        web.backgroundColor = bg
        web.scrollView.backgroundColor = bg
        if #available(iOS 15.0, *) {
            web.underPageBackgroundColor = bg
        }
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif
        webView = web
        web.load(URLRequest(url: URL(string: "foliate:///app/reader.html")!))
        return web
    }

    /// `--page-bg` を設定する JS（初回注入・テーマ変更時の更新の両方で使う）。
    static func pageBackgroundJS(_ color: UIColor) -> String {
        "document.documentElement.style.setProperty('--page-bg', '\(color.cssHex)');"
    }

    /// 表示中のページの地色を差し替える（テーマ変更に追従）。
    func updatePageBackground(_ color: UIColor) {
        webView?.evaluateJavaScript(Self.pageBackgroundJS(color))
    }

    func teardown() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "foliate")
        webView?.removeFromSuperview()
        webView = nil
    }

    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        Task { @MainActor in self.onMessage?(body) }
    }

    /// JS を実行し戻り値を返す（bridge の API は JSON 文字列を返す規約）。
    @discardableResult
    func call(_ js: String) async -> Any? {
        guard let webView else { return nil }
        return try? await webView.evaluateJavaScript(js)
    }

    /// JSON 文字列を返す JS を呼び、デコードして返す。
    func callJSON(_ js: String) async -> Any? {
        guard let out = await call(js) as? String, let data = out.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// async JS（Promise を返す式）を await して結果を得る。
    /// evaluateJavaScript は Promise を解決しないため、bridge の async API はこちらで呼ぶ。
    func callAsync(_ body: String) async -> Any? {
        guard let webView else { return nil }
        return try? await webView.callAsyncJavaScript(body, arguments: [:], contentWorld: .page)
    }

    /// async JS の戻り値（JSON 文字列）をデコードして返す。
    func callAsyncJSON(_ body: String) async -> Any? {
        guard let out = await callAsync(body) as? String, let data = out.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// 辞書/配列 → JS 文字列リテラル引数。
    static func jsonArg(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return "'{}'" }
        return quote(json)
    }

    /// 任意文字列 → JS の単一引用符リテラル。
    static func quote(_ s: String) -> String {
        let esc = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "'\(esc)'"
    }
}

extension UIColor {
    /// CSS の #rrggbb 表記。動的色（auto テーマ）は現在の外観で解決してから変換する。
    var cssHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolvedColor(with: .current).getRed(&r, green: &g, blue: &b, alpha: &a)
        let v = (Int(round(r * 255)) << 16) | (Int(round(g * 255)) << 8) | Int(round(b * 255))
        return String(format: "#%06x", v)
    }
}

// MARK: - 書棚登録用メタデータ抽出（オフスクリーン foliate）
// EPUB を開かずに foliate の epub.js パーサでタイトル・作者・読み(file-as)・出版社・表紙を取る。

@MainActor
enum EpubProbe {
    struct Result {
        var title: String?
        var author: String?
        var authorSort: String?
        var publisher: String?
        var coverPNG: Data?
    }

    /// 呼び出しごとに使い捨てのオフスクリーン WebView で確実に取る（多重呼び出しは直列化推奨）。
    static func probe(url: URL) async -> Result? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let engine = FoliateEngine()
        engine.provider.bookData = data

        // 画面外に付けておく（WKWebView はウィンドウ外でも JS 実行可だが、確実性のため親に載せる）。
        let host = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        let web = engine.makeWebView()
        web.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        web.isHidden = true
        host?.addSubview(web)

        defer {
            web.removeFromSuperview()
            engine.teardown()
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Result?, Never>) in
            var finished = false
            engine.onMessage = { body in
                guard !finished, let type = body["type"] as? String else { return }
                switch type {
                case "bridge-ready":
                    Task { await engine.call("window.__reader.probe()") }
                case "probe":
                    finished = true
                    if body["error"] != nil { cont.resume(returning: nil); return }
                    var r = Result()
                    r.title = (body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    r.author = (body["author"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    r.authorSort = (body["authorSort"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    r.publisher = (body["publisher"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    if let b64 = body["cover"] as? String, let img = Data(base64Encoded: b64) {
                        // 表紙は 400x600 以内の PNG に正規化（書棚キャッシュ形式は従来どおり）。
                        if let ui = UIImage(data: img) {
                            let maxSize = CGSize(width: 400, height: 600)
                            let scale = min(1, min(maxSize.width / max(ui.size.width, 1),
                                                   maxSize.height / max(ui.size.height, 1)))
                            let size = CGSize(width: ui.size.width * scale, height: ui.size.height * scale)
                            let fmt = UIGraphicsImageRendererFormat()
                            fmt.scale = 1
                            let png = UIGraphicsImageRenderer(size: size, format: fmt).pngData { _ in
                                ui.draw(in: CGRect(origin: .zero, size: size))
                            }
                            r.coverPNG = png
                        } else {
                            r.coverPNG = img
                        }
                    }
                    cont.resume(returning: r)
                case "error":
                    finished = true
                    cont.resume(returning: nil)
                default:
                    break
                }
            }
            // タイムアウト保険（15秒）。
            Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if !finished { finished = true; cont.resume(returning: nil) }
            }
        }
    }
}
