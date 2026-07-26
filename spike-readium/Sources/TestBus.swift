#if DEBUG
import Foundation
import Network

/// DEBUG 限定の UI テスト用コマンドバス。
///
/// 目的: Accessibility(AX) では駆動できない操作（SwiftUI の .contextMenu 限定アクション等）を、
/// 外部テスト（epub-test MCP / axdriver.py）から「本物のアプリのアクション」として実行し、
/// かつモデルの真の状態を JSON で取得できるようにする。
///
/// 実装: 127.0.0.1:47831 に JSONL(1行1 JSON) の TCP サーバを立てる。
/// 1リクエスト = 1行の JSON、1レスポンス = 1行の JSON。ハンドラは main で走る。
/// リリースビルドには一切含まれない（#if DEBUG）。
///
/// コマンド例:
///   {"cmd":"ping"}
///   {"cmd":"state"}
///   {"cmd":"setYomi","title_contains":"見本","yomi":"やまだ たろう"}
///   {"cmd":"clearYomi","title_contains":"見本"}
///   {"cmd":"remove","title_contains":"見本"}
///   {"cmd":"open","title_contains":"縦書き"}
///   {"cmd":"openYomiEditor","title_contains":"見本"}   // 実アラートを開く（AXで続けて入力可）
///   {"cmd":"overlayOn"}      // WebView 本文に計りレイヤー（ルーラー+16色帯）を注入
///   {"cmd":"overlayOff"}     // 計りレイヤーを除去
///   {"cmd":"measureImage"}   // 現在ページの画像/本文の getBoundingClientRect を JSON で返す
///   {"cmd":"pointer","y":10,"height":800}  // ホバー位置を注入（操作パネルの自動表示の検証）
///   {"cmd":"chromeState"}    // 上下パネルの表示状態を返す
///   {"cmd":"toggleRenderMode"} // 表示モード（読みやすさ優先⇄EPUB のまま）を往復
///   {"cmd":"renderMode"}     // 現在の表示モードを返す
final class TestBus {
    static let shared = TestBus()

    static let port: UInt16 = 47831

    /// 対象モデル（App 起動時に注入）。
    weak var model: AppModel?
    /// 現在開いているリーダー（ReaderScreen 表示時に注入）。計りレイヤー/測定に使う。
    weak var reader: ReaderModel?
    /// 実アラート（作者の読み）を開くためのビュー側フック（ShelfView が登録）。
    var openYomiEditor: ((BookEntry) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "testbus.tcp")

    private init() {}

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // ループバックのみに束縛。
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            l.start(queue: queue)
            listener = l
            NSLog("[TestBus] listening on 127.0.0.1:\(Self.port)")
        } catch {
            NSLog("[TestBus] start failed: \(error)")
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isDone, err in
            guard let self else { return }
            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }
            // 改行区切りで完結した行を処理。
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                self.process(line, on: conn)
            }
            if isDone || err != nil {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func process(_ line: Data, on conn: NWConnection) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            respond(["ok": false, "error": "invalid json"], on: conn)
            return
        }
        // ハンドラは UI/モデルに触り、evaluateJavaScript(async) を待つので main actor で非同期実行。
        Task { @MainActor in
            let response = await self.handle(obj)
            self.respond(response, on: conn)
        }
    }

    private func respond(_ response: [String: Any], on conn: NWConnection) {
        var out = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{\"ok\":false}".utf8)
        out.append(0x0A)
        conn.send(content: out, completion: .idempotent)
    }

    // MARK: - コマンド処理（main 実行）

    private func dump(_ b: BookEntry) -> [String: Any] {
        [
            "id": b.id.uuidString,
            "title": b.title,
            "author": b.authorText,
            "authorSort": b.authorSort ?? NSNull(),
            "authorYomi": b.authorYomi ?? NSNull(),
            "resolvedReading": b.resolvedAuthorReading ?? NSNull(),
            "authorSortKey": b.authorSortKey,
        ]
    }

    /// title_contains / title / id いずれかで本を1冊特定。
    private func match(_ cmd: [String: Any], _ books: [BookEntry]) -> BookEntry? {
        if let id = cmd["id"] as? String { return books.first { $0.id.uuidString == id } }
        if let t = cmd["title"] as? String { return books.first { $0.title == t } }
        if let tc = cmd["title_contains"] as? String { return books.first { $0.title.contains(tc) } }
        return nil
    }

    @MainActor
    private func handle(_ cmd: [String: Any]) async -> [String: Any] {
        let name = (cmd["cmd"] as? String) ?? ""

        // 計りレイヤー/測定はリーダー（WebView）に対する操作。model 非依存。
        switch name {
        case "overlayOn":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            await reader.showMeasureOverlay()
            return ["ok": true]
        case "overlayOff":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            await reader.hideMeasureOverlay()
            return ["ok": true]
        case "measureImage", "measure":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            guard let parsed = await reader.measureOverlay() else {
                return ["ok": false, "error": "measure failed (no navigator?)"]
            }
            return ["ok": true, "measure": parsed]
        case "eval":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            let js = (cmd["js"] as? String) ?? ""
            let out = await reader.evalJS(js)
            return ["ok": true, "result": out]
        case "seek":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            let f = (cmd["fraction"] as? NSNumber)?.doubleValue ?? 0
            await reader.seek(to: f)
            return ["ok": true, "fraction": f]
        case "goForward", "goBackward":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            await reader.testTurnPage(forward: name == "goForward")
            return ["ok": true]
        case "search":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            reader.runSearch((cmd["query"] as? String) ?? "")
            return ["ok": true]
        case "searchState":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            return [
                "ok": true,
                "isSearching": reader.isSearching,
                "count": reader.searchResults.count,
                "first": reader.searchResults.first.map {
                    ["cfi": $0.cfi, "excerpt": $0.pre + "【" + $0.match + "】" + $0.post]
                } ?? NSNull(),
            ]
        case "jumpFirstHit":
            guard let reader, let hit = reader.searchResults.first else {
                return ["ok": false, "error": "no search results"]
            }
            reader.jumpToSearchResult(hit)
            return ["ok": true]
        case "setTheme":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            reader.setTheme((cmd["theme"] as? String) ?? "light")
            return ["ok": true]
        case "addBookmark":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            reader.addBookmark()
            return ["ok": true]
        case "writingMode", "writingModeAuto", "writingModeVertical", "writingModeHorizontal":
            // 書字方向（auto/vertical/horizontal）の切替と、実際に組まれた向きの取得。
            // 素の "writingMode" は現在値の問い合わせだけ（MCP のスキーマに任意キーを
            // 足せないので、切替はコマンド名に向きを埋める。saveVideoH/V と同じ流儀）。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            let modeArg = (cmd["mode"] as? String)
                ?? (name == "writingModeAuto" ? "auto"
                    : name == "writingModeVertical" ? "vertical"
                    : name == "writingModeHorizontal" ? "horizontal" : nil)
            if let raw = modeArg, let mode = WritingMode(rawValue: raw) {
                reader.setWritingMode(mode)
                // 組み直し（本を開き直す）を待ってから状態を返す。
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            return [
                "ok": true,
                "writingMode": reader.writingMode.rawValue,
                "vertical": reader.isVertical,
                "rtl": reader.isRTL,
                // 章ごとの rtl（上）と本単位の rtl（下）。スライダーの鏡像は本単位で決まる。
                "bookRTL": reader.bookIsRTL,
                "bookHint": reader.bookWritingHint ?? "",
                "fraction": reader.progression,
                "tocHref": reader.currentTocHref,
            ]
        case "toggleTOC", "tocOn", "tocOff":
            // 目次サイドバーの開閉（SwiftUI の状態遷移は AX に出ないのでここから駆動する）。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            reader.showTOC = (name == "tocOn") ? true : (name == "tocOff" ? false : !reader.showTOC)
            return ["ok": true, "showTOC": reader.showTOC, "count": reader.toc.count]
        case "tocJump":
            // 目次項目へジャンプ（ラベル部分一致）。List の行は Catalyst の AX に出ないので、
            // サイドバーのクリックと同じ経路をここから叩く。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            let query = (cmd["title_contains"] as? String) ?? (cmd["title"] as? String) ?? ""
            func find(_ items: [TOCEntry]) -> TOCEntry? {
                for item in items {
                    if !query.isEmpty, item.label.contains(query) { return item }
                    if let hit = find(item.subitems) { return hit }
                }
                return nil
            }
            guard let target = find(reader.toc) else {
                return ["ok": false, "error": "no toc entry matching \(query)"]
            }
            reader.jumpToTOC(target)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            return [
                "ok": true, "label": target.label, "href": target.href,
                "currentTocHref": reader.currentTocHref, "fraction": reader.progression,
            ]
        case "toc":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            // 階層を平坦化して返す（深さつき）。目次サイドバーの中身の回帰用。
            func flatten(_ items: [TOCEntry], depth: Int) -> [[String: Any]] {
                items.flatMap { item -> [[String: Any]] in
                    [["label": item.label, "href": item.href, "depth": depth]]
                        + flatten(item.subitems, depth: depth + 1)
                }
            }
            let flat = flatten(reader.toc, depth: 0)
            return ["ok": true, "count": flat.count, "current": reader.currentTocHref, "items": flat]
        case "selection":
            // bridge の selectionchange → ReaderModel.selectedText の同期を検証するプローブ。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            return ["ok": true, "text": reader.selectedText]
        case "pointer":
            // 操作パネルの自動表示を検証する。マウスを動かさずにホバー位置だけ注入する
            //（実ポインタでの検証は別途スクショで行う。ここは判定ロジックの回帰用）。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            let height = (cmd["height"] as? NSNumber)?.doubleValue ?? 800
            if let y = (cmd["y"] as? NSNumber)?.doubleValue {
                reader.updateContentPointer(y: CGFloat(y), viewHeight: CGFloat(height))
            } else {
                reader.updateContentPointer(y: nil, viewHeight: CGFloat(height))
            }
            return ["ok": true, "chromeTop": reader.chromeTop, "chromeBottom": reader.showsBottomChrome]
        case "toggleRenderMode":
            // ツールバーのボタンと同じ経路。SwiftUI の Button は AX に出ないのでここから叩く。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            reader.toggleRenderMode()
            return ["ok": true, "renderMode": reader.renderMode.rawValue]
        case "renderMode":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            return ["ok": true, "renderMode": reader.renderMode.rawValue]
        case "chromeState":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            return ["ok": true, "chromeTop": reader.chromeTop, "chromeBottom": reader.showsBottomChrome]
        case "setRules":
            // 読み辞書を UI と同じ経路（readingEntries didSet → 保存 + 再コンパイル）で丸ごと設定。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            let arr = (cmd["entries"] as? [[String: Any]]) ?? (cmd["rules"] as? [[String: Any]]) ?? []
            reader.readingEntries = arr.map(Self.entry(from:))
            return ["ok": true, "count": reader.readingEntries.count]
        case "applyRules":
            // 辞書を text へ適用した結果を返す（読み上げに渡る文字列と、無音化する境界の検証用）。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            let prepared = reader.prepareSpeech((cmd["text"] as? String) ?? "")
            return [
                "ok": true,
                "text": prepared.text,
                "injectedGaps": prepared.injectedGaps.sorted(),
            ]
        case "dictList":
            // アプリ側の読み辞書の全件（適用順＝レイヤー降順・同レイヤーは長い表記が先）。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            let sorted = reader.readingEntries.sorted {
                $0.layer != $1.layer ? $0.layer > $1.layer : $0.surface.count > $1.surface.count
            }
            return ["ok": true, "words": sorted.map(Self.payload(for:))]
        case "dictAdd":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            return ["ok": reader.saveDictWord(Self.entry(from: cmd))]
        case "dictUpdate":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            guard let id = (cmd["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let existing = reader.readingEntries.first(where: { $0.id == id })
            else { return ["ok": false, "error": "unknown entry id"] }
            var updated = Self.entry(from: cmd)
            updated.id = existing.id
            return ["ok": reader.saveDictWord(updated)]
        case "dictDelete":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            guard let id = (cmd["id"] as? String).flatMap(UUID.init(uuidString:)) else {
                return ["ok": false, "error": "unknown entry id"]
            }
            reader.deleteDictWord(id: id)
            return ["ok": true]
        case "openDictForm":
            // 右クリック登録と同じ経路（dictInput 経由）で単語フォームを開く（AX で続けて操作可）。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            reader.requestDictionaryRegister(surface: (cmd["surface"] as? String) ?? "")
            return ["ok": true]
        case "setSaveDir":
            // 読み上げ音声の保存先ディレクトリを設定（フォルダピッカーと同じ経路）。dir="" で既定に戻す。
            let dir = (cmd["dir"] as? String) ?? ""
            if dir.isEmpty { TTSSaveLocation.clear() }
            else { TTSSaveLocation.setDirectory(URL(fileURLWithPath: dir, isDirectory: true)) }
            return ["ok": true, "dir": TTSSaveLocation.resolveDirectory().path]
        case "openSettings":
            // 設定シートを開く（視覚確認・AX 操作用）。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            reader.showSettings = true
            return ["ok": true]
        case "saveSection":
            // 現在セクションを音声保存し、書き出した WAV の実パスを返す（完了まで待つ）。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            guard let url = await reader.performSectionSave() else {
                return ["ok": false, "error": reader.status]
            }
            let size = (try? Data(contentsOf: url))?.count ?? 0
            return ["ok": true, "path": url.path, "bytes": size]
        case "saveVideo", "saveVideoH", "saveVideoV":
            // 現在セクションを動画保存し、書き出した MP4 の実パスを返す（生成完了まで待つ）。
            // saveVideo=本の書字方向で自動 / saveVideoH=横書き強制 / saveVideoV=縦書き強制（横書き経路の確認用）。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            let force: Bool? = name == "saveVideoH" ? false : (name == "saveVideoV" ? true : nil)
            guard let url = await reader.performSectionVideoSave(forceVertical: force) else {
                return ["ok": false, "error": reader.status]
            }
            let size = (try? Data(contentsOf: url))?.count ?? 0
            return ["ok": true, "path": url.path, "bytes": size, "status": reader.status]
        default:
            break
        }

        guard let model else { return ["ok": false, "error": "model not attached"] }
        switch name {
        case "ping":
            return ["ok": true, "port": Int(Self.port)]

        case "state":
            return ["ok": true, "books": model.books.map { dump($0) }]

        case "setYomi", "clearYomi":
            guard let b = match(cmd, model.books) else { return ["ok": false, "error": "book not found"] }
            let yomi = name == "clearYomi" ? "" : ((cmd["yomi"] as? String) ?? "")
            model.setAuthorYomi(bookID: b.id, yomi: yomi)
            let updated = model.books.first { $0.id == b.id }
            return ["ok": true, "book": updated.map { dump($0) } ?? NSNull()]

        case "remove":
            guard let b = match(cmd, model.books) else { return ["ok": false, "error": "book not found"] }
            model.remove(b)
            return ["ok": true, "removed": b.title, "count": model.books.count]

        case "open":
            guard let b = match(cmd, model.books) else { return ["ok": false, "error": "book not found"] }
            model.open(url: b.fileURL)
            return ["ok": true, "opened": b.title]

        case "openYomiEditor":
            guard let b = match(cmd, model.books) else { return ["ok": false, "error": "book not found"] }
            guard let hook = openYomiEditor else { return ["ok": false, "error": "editor hook not registered"] }
            hook(b)
            return ["ok": true, "editing": b.title]

        default:
            return ["ok": false, "error": "unknown cmd: \(name)"]
        }
    }

    // MARK: - 読み辞書の受け渡し

    /// コマンド引数から辞書エントリを組む。旧ルール形式（pattern/replacement）も受ける。
    private static func entry(from cmd: [String: Any]) -> ReadingEntry {
        let surface = (cmd["surface"] as? String) ?? (cmd["pattern"] as? String) ?? ""
        let reading = (cmd["reading"] as? String) ?? (cmd["replacement"] as? String) ?? ""
        let isPattern = (cmd["kind"] as? String) == "pattern" || cmd["pattern"] != nil
        return ReadingEntry(
            surface: surface,
            reading: reading,
            layer: (cmd["layer"] as? NSNumber)?.intValue ?? 5,
            kind: isPattern ? .pattern : .word,
            padsBoundary: (cmd["padsBoundary"] as? Bool) ?? false,
            enabled: (cmd["enabled"] as? Bool) ?? true)
    }

    /// 辞書エントリを JSON へ（MCP 側のアサート用）。
    private static func payload(for entry: ReadingEntry) -> [String: Any] {
        [
            "id": entry.id.uuidString,
            "surface": entry.surface,
            "reading": entry.reading,
            "layer": entry.layer,
            "kind": entry.kind.rawValue,
            "padsBoundary": entry.padsBoundary,
            "enabled": entry.enabled,
        ]
    }
}
#endif
