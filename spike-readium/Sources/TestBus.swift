import Foundation
import Network
import UniformTypeIdentifiers

/// アプリを外から駆動するコマンドバス。
///
/// 目的は二つある。
///  1. UI テスト: Accessibility(AX) では駆動できない操作（SwiftUI の .contextMenu 限定アクション等）を、
///     外部テスト（epub-test MCP / axdriver.py）から「本物のアプリのアクション」として実行し、
///     かつモデルの真の状態を JSON で取得する。
///  2. 読み辞書の自動化: 熟語を数十件登録して読みを合わせる作業は手では割に合わない。
///     AI エージェントに「登録して、`applyRules` で読み上げに渡る文字列を見て検算する」を
///     回させるため、**辞書まわりだけはリリースビルドでも開けてある**（下の `releaseCommands`）。
///
/// 実装: 127.0.0.1:47831 に JSONL(1行1 JSON) の TCP サーバを立てる。
/// 1リクエスト = 1行の JSON、1レスポンス = 1行の JSON。ハンドラは main で走る。
/// 待ち受けはループバックのみ。リリースビルドで受け付けるコマンドは辞書まわりに限る
///（本の一覧やパス、書棚の切り替え、電源操作まで外から触れると、書棚を分けている意味がなくなるため）。
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

    /// 待ち受けポート。既定は 47831。
    ///
    /// ワークツリーを分けて並行に作業すると、両方のビルドが同じポートを取り合って
    /// 「片方のテストが、もう片方のアプリに当たっていた」という混線が起きる
    ///（allowLocalEndpointReuse を立てているので後から起動した側が黙って奪う）。
    /// 環境変数 EPUB_TEST_BUS_PORT で振り分けられるようにしてある。テスト側（axdriver.py /
    /// bus.py / MCP サーバ）も同じ変数を見るので、ワークツリーごとに値を決めておけばよい。
    static let port: UInt16 = {
        let raw = ProcessInfo.processInfo.environment["EPUB_TEST_BUS_PORT"] ?? ""
        if let n = UInt16(raw.trimmingCharacters(in: .whitespaces)), n >= 1024 { return n }
        return 47831
    }()

    /// リリースビルドでも受け付けるコマンド。
    ///
    /// 読み辞書は「熟語を数十件そろえて初めて意図どおりに読める」たぐいの機能で、手で入れるには
    /// 割に合わない。だからここだけは開発ビルドに閉じ込めず、配布版でも外から編集・検算できる。
    /// 逆に、蔵書の一覧・パス・書棚の切り替え・電源操作・本文への eval は開発ビルド限定のままにする。
    /// ローカルの別プロセスなら誰でもこの口を叩けるので、配布版で開ける範囲は
    /// 「今の書棚の読み辞書」と「その適用結果」に限る。
    static let releaseCommands: Set<String> = [
        "ping", "dictList", "dictAdd", "dictUpdate", "dictDelete", "setRules", "applyRules",
    ]

    /// 対象モデル（App 起動時に注入）。
    weak var model: AppModel?
    /// 現在開いているリーダー（ReaderScreen 表示時に注入）。計りレイヤー/測定に使う。
    weak var reader: ReaderModel?
    /// 実アラート（作者の読み）を開くためのビュー側フック（ShelfView が登録）。
    var openYomiEditor: ((BookEntry) -> Void)?
    /// 書棚に「いま実際に出ている本」（絞り込み・並び替え後）。ShelfView が登録する。
    /// モデルの `books(in:)` と別に持つのは、画面に出ている結果そのものを確かめるため。
    var shelfSnapshot: (() -> [(UUID, String)])?

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
            // 取り込みの検証で「どのファイルが入ったか」を突き合わせるために要る
            //（同じ本の複製はタイトルが同じで見分けられない）。DEBUG 限定のバス越しのみ。
            "path": b.path,
            "author": b.authorText,
            "authorSort": b.authorSort ?? NSNull(),
            "authorYomi": b.authorYomi ?? NSNull(),
            "resolvedReading": b.resolvedAuthorReading ?? NSNull(),
            "authorSortKey": b.authorSortKey,
        ]
    }

    /// スリープタイマーの状態（残り秒・満了時の動作・要求された電源操作）。
    /// `power` は「実際に要求された電源操作」で、実操作 OFF のときは記録だけが入る＝
    /// テストはここを見て「シャットダウンまで到達したか」を Mac を落とさずに検証できる。
    @MainActor
    private func sleepTimerState(_ t: SleepTimer) -> [String: Any] {
        [
            "active": t.isActive,
            "remaining": Int(t.remaining.rounded()),
            "action": t.action.rawValue,
            "shutdownCountdown": t.shutdownCountdown.map { Int($0.rounded()) } ?? NSNull(),
            // 電源操作を「記録だけ」に差し替える逃げ道は開発ビルドにしか無い（配布版は常に実操作）。
            "realPower": Self.realPowerFlag(t),
            "power": t.recordingPower.lastRequest ?? NSNull(),
        ]
    }

    @MainActor
    private static func realPowerFlag(_ t: SleepTimer) -> Bool {
        #if DEBUG
        return t.performsRealPowerAction
        #else
        return true
        #endif
    }

    /// 書棚（プロファイル）の一覧と、いま見ている書棚の保存先。
    ///
    /// パスまで返すのは、「切り替えたつもりで前の書棚のファイルを読み書きしている」類の
    /// 取り違えが画面からは見えないため（最初からある書棚だけ保存先が root 直下という
    /// 分岐があるので、そこを実測で押さえておきたい）。
    @MainActor
    private func profileDump(_ model: AppModel) -> [String: Any] {
        [
            "current": model.currentProfileID.uuidString,
            "list": model.profiles.map { p in
                [
                    "id": p.id.uuidString,
                    "name": p.name,
                    "primary": p.isPrimary,
                    "removable": model.canRemoveProfile(p.id),
                ] as [String: Any]
            },
            "libraryPath": ProfileLocation.shared.libraryFileURL.path,
            "coversPath": ProfileLocation.shared.coversDirectory.path,
            "cssKey": EpubOpener.userCSSKey,
            "dictKey": ReadingDictionaryStore.key,
        ]
    }

    /// 書棚の指定（id / name）。名前は一意とは限らないので、最初に見つけたものを返す。
    @MainActor
    private func resolveProfile(_ cmd: [String: Any], _ model: AppModel) -> UUID? {
        if let raw = cmd["id"] as? String, let id = UUID(uuidString: raw),
           model.profiles.contains(where: { $0.id == id }) {
            return id
        }
        if let name = cmd["name"] as? String {
            return model.profiles.first { $0.name == name }?.id
        }
        return nil
    }

    /// 自動ページ送りの状態（稼働中か・次の送りまでの残り秒・間隔・読み上げ中で見送っているか）。
    @MainActor
    private func autoPagerState(_ p: AutoPager) -> [String: Any] {
        [
            "running": p.isRunning,
            "remaining": Int(p.remaining.rounded()),
            "seconds": p.seconds,
            "holding": p.isHolding,
        ]
    }

    /// title_contains / title / id いずれかで本を1冊特定。
    /// 分類の指定（id / name）。名前は書棚の中で一意とは限らないので、最初に見つけたものを返す。
    private func matchCollection(_ cmd: [String: Any],
                                 _ all: [ShelfCollection]) -> ShelfCollection? {
        if let id = cmd["collection"] as? String,
           let found = all.first(where: { $0.id.uuidString == id }) { return found }
        if let n = cmd["collection_name"] as? String { return all.first { $0.name == n } }
        return nil
    }

    private func match(_ cmd: [String: Any], _ books: [BookEntry]) -> BookEntry? {
        if let id = cmd["id"] as? String { return books.first { $0.id.uuidString == id } }
        if let t = cmd["title"] as? String { return books.first { $0.title == t } }
        if let tc = cmd["title_contains"] as? String { return books.first { $0.title.contains(tc) } }
        return nil
    }

    @MainActor
    private func handle(_ cmd: [String: Any]) async -> [String: Any] {
        let name = (cmd["cmd"] as? String) ?? ""

        #if !DEBUG
        // 配布版で開けてあるのは読み辞書まわりだけ（`releaseCommands` の説明を参照）。
        guard Self.releaseCommands.contains(name) else {
            return ["ok": false, "error": "command not available in this build: \(name)"]
        }
        #endif

        // 計りレイヤー/測定はリーダー（WebView）に対する操作。model 非依存。
        switch name {
        #if DEBUG
        // 計りレイヤーの注入と本文への eval は開発ビルド限定（本文 WebView に任意の JS を通すため）。
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
        #endif
        case "bookmarkSelection":
            // 本文の右クリック「しおりを追加」と同じ経路。選択は eval で作っておく
            //（右クリックメニュー自体は合成イベントで開けないため、経路だけを検証する）。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            reader.addBookmarkAtSelection()
            try? await Task.sleep(nanoseconds: 600_000_000)
            let list = model?.bookmarks(for: reader.bookID ?? UUID()) ?? []
            return [
                "ok": true,
                "count": list.count,
                "last": list.last.map { ["cfi": $0.locatorJSON, "excerpt": $0.excerpt] } ?? NSNull(),
            ]
        case "bookmarkList":
            guard let reader, let id = reader.bookID else {
                return ["ok": false, "error": "reader not attached (open a book first)"]
            }
            let list = model?.bookmarks(for: id) ?? []
            return [
                "ok": true, "count": list.count,
                "items": list.map { ["cfi": $0.locatorJSON, "excerpt": $0.excerpt, "progression": $0.progression] },
            ]
        case "seek":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            let f = (cmd["fraction"] as? NSNumber)?.doubleValue ?? 0
            await reader.seek(to: f)
            return ["ok": true, "fraction": f]
        #if DEBUG
        case "goForward", "goBackward":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            await reader.testTurnPage(forward: name == "goForward")
            return ["ok": true]
        #endif
        case "tapLeft", "tapRight", "tapDown", "tapUp":
            // 左右端タップゾーン／矢印キーと同じ経路（押された向き → ReaderModel が
            // 本単位の書字方向で進む/戻るを解決）。goForward/goBackward は解決済みの
            // 進む/戻るを直接叩くので、左右の向き判定そのものはこちらでないと検証できない。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            let side: PageSide = name == "tapLeft" ? .left
                : name == "tapRight" ? .right
                : name == "tapDown" ? .next : .previous
            await reader.pageStep(side: side)
            return [
                "ok": true,
                "side": name,
                "bookRTL": reader.bookIsRTL,
                "fraction": reader.progression,
            ]
        case "translateOn", "translateOff", "translateRefresh":
            // 対訳ペイン（LM Studio）の開閉と訳し直し。翻訳は非同期に進むので、
            // 結果の確認は translateState をポーリングする。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            if name == "translateRefresh" {
                reader.refreshTranslation(force: (cmd["force"] as? Bool) ?? false)
            } else {
                let want = name == "translateOn"
                if reader.showTranslation != want { reader.toggleTranslation() }
            }
            return ["ok": true, "showTranslation": reader.showTranslation]
        case "translateState":
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            let units: [[String: Any]] = reader.translationUnits.map { u in
                var state = "pending"
                var error: Any = NSNull()
                switch u.state {
                case .pending: state = "pending"
                case .running: state = "running"
                case .done:    state = "done"
                case let .failed(m): state = "failed"; error = m
                }
                return [
                    "id": u.id, "heading": u.isHeading, "state": state,
                    "source": u.source, "translated": u.translated, "error": error,
                ]
            }
            return [
                "ok": true,
                "showTranslation": reader.showTranslation,
                "isTranslating": reader.isTranslating,
                "model": reader.translationModel,
                "error": reader.translationError ?? NSNull(),
                "count": units.count,
                "done": reader.translationUnits.filter(\.isSettled).count,
                "units": units,
            ]
        case "setTranslation":
            // 翻訳設定の書き換え（テストから接続先・モデル・訳先言語を差し替える）。
            var s = TranslationSettingsStore.load()
            if let v = cmd["url"] as? String { s.baseURLString = v }
            if let v = cmd["model"] as? String { s.model = v }
            if let v = cmd["target"] as? String { s.targetLanguage = v }
            if let v = cmd["source"] as? String { s.sourceLanguage = v }
            if let v = cmd["context"] as? Bool { s.useContext = v }
            if let v = cmd["thinking"] as? Bool { s.disableThinking = !v }
            if let v = (cmd["concurrency"] as? NSNumber)?.intValue { s.concurrency = v }
            TranslationSettingsStore.save(s)
            reader?.translationModel = s.model
            return ["ok": true, "url": s.baseURLString, "model": s.model,
                    "target": s.targetLanguage, "concurrency": s.concurrency]
        case "translatePassages":
            // 翻訳せず、bridge が抽出した「いま見えている段落」だけを返す（抽出の検証用）。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            let raw = await reader.engine.callJSON("window.__reader.getVisiblePassages()")
            return ["ok": true, "passages": raw ?? NSNull()]
        case "display":
            // 表示の強制（綴じ方向・見開き・アスペクト比）の取得と変更。
            // 例: {"cmd":"display","binding":"rtl"} / {"cmd":"display","aspect":"844:1200"}
            //     {"cmd":"display","imageSpread":"always","textSpread":"never"}
            //     {"cmd":"display","aspect":""} で比率の固定を解除。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            if let raw = cmd["binding"] as? String, let d = BindingDirection(rawValue: raw) {
                reader.setBindingDirection(d)
            }
            if let raw = cmd["imageSpread"] as? String, let m = SpreadMode(rawValue: raw) {
                reader.setImageSpread(m)
            }
            if let raw = cmd["textSpread"] as? String, let m = SpreadMode(rawValue: raw) {
                reader.setTextSpread(m)
            }
            if let raw = cmd["aspect"] as? String {
                reader.setForcedAspect(AspectRatio(storageString: raw))
            }
            // JS へ投げた変更が返ってくるまで待つ（テストが次の assert へ進む前に確定させる）。
            try? await Task.sleep(nanoseconds: 400_000_000)
            let live = await reader.engine.callJSON("window.__reader.displayState()")
            return [
                "ok": true,
                "binding": reader.bindingDirection.rawValue,
                "imageSpread": reader.imageSpread.rawValue,
                "textSpread": reader.textSpread.rawValue,
                "aspect": reader.forcedAspect?.storageString ?? NSNull(),
                "detectedAspect": reader.detectedAspect?.storageString ?? NSNull(),
                "bookRTL": reader.bookIsRTL,
                "js": live ?? NSNull(),
            ]
        case "spreadState":
            // bridge が組んでいる見開きの実態（どの章とどの章を並べているか）。
            guard let reader else { return ["ok": false, "error": "reader not attached (open a book first)"] }
            let raw = await reader.engine.callJSON("window.__reader.spreadState()")
            return ["ok": true, "spread": raw ?? NSNull()]
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
            // 設定シートを開く（視覚確認・AX 操作用）。書棚でも開けるので model 側で持つ。
            guard let model else { return ["ok": false, "error": "model not attached"] }
            model.showSettings = true
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

        #if DEBUG
        case "menuDump":
            // メニュー識別子の実物（AppDelegate.buildMenu が組んだ直後の姿）。
            return ["ok": true, "items": AppDelegate.menuDump]
        #endif

        // MARK: 書棚（プロファイル）
        // 保存先も返す。「切り替えたのに前の書棚のファイルを読んでいる」類の取り違えは
        // 画面からは見えないので、パスを突き合わせて確かめられるようにしてある。
        case "profiles":
            return ["ok": true, "profiles": profileDump(model)]

        case "switchProfile":
            guard let target = resolveProfile(cmd, model) else {
                return ["ok": false, "error": "profile not found"]
            }
            model.switchProfile(to: target)
            // 蔵書の読み込みと表紙キャッシュの破棄が済むまで1呼吸置く。
            try? await Task.sleep(nanoseconds: 300_000_000)
            return ["ok": true, "profiles": profileDump(model), "books": model.books.count]

        case "addProfile":
            guard let name = cmd["name"] as? String,
                  let created = model.addProfile(name: name) else {
                return ["ok": false, "error": "name is empty"]
            }
            return ["ok": true, "id": created.id.uuidString, "profiles": profileDump(model)]

        // 新しい名前は "to" で受ける（"name" は対象を探すのに使うので、同じ鍵に二役やらせない）。
        case "renameProfile":
            guard let target = resolveProfile(cmd, model),
                  let next = cmd["to"] as? String, model.renameProfile(target, to: next) else {
                return ["ok": false, "error": "rename failed"]
            }
            return ["ok": true, "profiles": profileDump(model)]

        case "removeProfile":
            guard let target = resolveProfile(cmd, model) else {
                return ["ok": false, "error": "profile not found"]
            }
            guard model.removeProfile(target) else {
                return ["ok": false, "error": "not removable (primary or current)"]
            }
            return ["ok": true, "profiles": profileDump(model)]

        // 開閉の両方をここから起こせるようにしてある（シートの「閉じる」は
        // ToolbarItem(.confirmationAction) で AX に現れず、テストから閉じる手が無くなる）。
        case "openProfileManager":
            model.showProfileManager = true
            return ["ok": true]

        case "closeProfileManager":
            model.showProfileManager = false
            return ["ok": true]

        // MARK: スリープタイマー
        // 電源操作は既定で「記録だけ」（SleepTimer.performsRealPowerAction=false）なので、
        // ここから満了させてもテスト機は落ちない。実操作の確認は sleepTimerRealPower で明示的に入れる。
        case "sleepTimerStart":
            let t = model.sleepTimer
            if let raw = cmd["action"] as? String {
                guard let a = SleepTimerAction(rawValue: raw) else {
                    return ["ok": false, "error": "unknown action: \(raw)"]
                }
                t.action = a
            }
            // 秒指定（fire までの待ち時間を縮めたいテスト用）も受ける。
            // start(minutes:) は通さない（「前回指定した分数」をテストの都合で汚さない）。
            if let sec = (cmd["seconds"] as? NSNumber)?.doubleValue, sec > 0 {
                t.startForTest(seconds: sec)
            } else {
                t.start(minutes: (cmd["minutes"] as? NSNumber)?.intValue ?? 30)
            }
            return ["ok": true, "state": sleepTimerState(t)]

        case "sleepTimerCancel":
            model.sleepTimer.cancel()
            return ["ok": true, "state": sleepTimerState(model.sleepTimer)]

        case "sleepTimerFire":
            // 締め切りを現在へ引き寄せて満了させる（待たずに満了時の挙動を検証する）。
            let t = model.sleepTimer
            guard t.deadline != nil else { return ["ok": false, "error": "timer not running"] }
            t.fireNow()
            try? await Task.sleep(nanoseconds: 700_000_000)  // 0.5s 刻みの tick を1回またぐ
            return ["ok": true, "state": sleepTimerState(t)]

        case "sleepTimerShutdownCancel":
            model.sleepTimer.cancelShutdownCountdown()
            return ["ok": true, "state": sleepTimerState(model.sleepTimer)]

        case "sleepTimerShutdownNow":
            model.sleepTimer.shutdownNow()
            return ["ok": true, "state": sleepTimerState(model.sleepTimer)]

        #if DEBUG
        case "sleepTimerRealPower":
            // 実際に電源を操作するかの切り替え（既定 false）。テストで true にするときは
            // 本当に Mac が落ちるので、意図して入れること。配布版にこの逃げ道は無い。
            model.sleepTimer.performsRealPowerAction = (cmd["on"] as? NSNumber)?.boolValue ?? false
            return ["ok": true, "state": sleepTimerState(model.sleepTimer)]
        #endif

        case "spawnProbe":
            // 子プロセスを起こせるか（＝スリープ/シャットダウンの経路が生きているか）だけを、
            // 電源を触らずに確かめる。Catalyst は Process が使えず posix_spawn 頼りなので、
            // ここが通らなければ pmset も osascript も動かない。
            let path = (cmd["path"] as? String) ?? NSTemporaryDirectory() + "spawn-probe"
            let ok = SystemPower.spawn("/usr/bin/touch", [path])
            try? await Task.sleep(nanoseconds: 400_000_000)
            return ["ok": ok, "path": path,
                    "exists": FileManager.default.fileExists(atPath: path)]

        case "sleepTimerResetPower":
            // 記録した電源操作を消す（次の検証を前回の記録と取り違えないため）。
            model.sleepTimer.recordingPower.reset()
            return ["ok": true, "state": sleepTimerState(model.sleepTimer)]

        case "sleepTimerState":
            return ["ok": true, "state": sleepTimerState(model.sleepTimer)]

        // MARK: 自動ページ送り
        case "autoPagerStart":
            let p = model.autoPager
            if let sec = (cmd["seconds"] as? NSNumber)?.intValue, sec > 0 {
                p.start(seconds: sec)
            } else {
                p.start()
            }
            return ["ok": true, "state": autoPagerState(p),
                    "fraction": reader?.progression ?? NSNull()]

        case "autoPagerStop":
            model.autoPager.stop()
            return ["ok": true, "state": autoPagerState(model.autoPager)]

        case "autoPagerFire":
            // 次の送りを現在へ引き寄せて1ページ送らせる（間隔ぶん待たずに挙動を検証する）。
            let p = model.autoPager
            guard p.isRunning else { return ["ok": false, "error": "auto pager not running"] }
            let before = reader?.progression
            p.fireNow()
            // 送り→ relocate の往復（AutoPager 自身の終端判定と同じ待ち）を1回またぐ。
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return ["ok": true, "state": autoPagerState(p),
                    "before": before ?? NSNull(), "fraction": reader?.progression ?? NSNull()]

        case "autoPagerState":
            return ["ok": true, "state": autoPagerState(model.autoPager),
                    "fraction": reader?.progression ?? NSNull()]

        case "closeBook":
            // 書棚へ戻す（メニュー項目の淡色表示など、本を開いていない状態の検証用）。
            model.closeBook()
            return ["ok": true, "opened": model.openedBook?.title ?? NSNull()]

        case "importPaths", "importFolder":
            // フォルダ／ファイルのパスを渡して、ドロップと同じ経路で取り込ませる。
            // ドラッグ操作そのものは AX から起こせないので、解決済みの URL を渡す形で検証する
            //（フォルダの再帰収集は ImportableBook.expand＝ドロップ時と同じ関数を通る）。
            let paths = (cmd["paths"] as? [String]) ?? [(cmd["path"] as? String) ?? ""]
            let urls = paths.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { return ["ok": false, "error": "path required"] }
            let expanded = ImportableBook.expand(urls)
            model.add(urls: urls, openIfSingle: (cmd["open"] as? Bool) ?? false)
            return ["ok": true, "found": expanded.count, "files": expanded.map(\.path)]

        case "dropSimulate":
            // ドロップ経路そのもの（NSItemProvider → BookDrop）を通す。Finder からのドラッグは
            // AX から起こせないので、Finder と同じ型で provider を組んで流し込む。
            // shape: "folder"（public.folder の in-place 表現）/ "epub"（org.idpf.epub-container の
            // in-place 表現）/ "fileURL"（public.file-url しか持たない形＝in-place が失敗する経路）。
            let dropPaths = (cmd["paths"] as? [String]) ?? [(cmd["path"] as? String) ?? ""]
            let dropURLs = dropPaths.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
            guard !dropURLs.isEmpty else { return ["ok": false, "error": "path required"] }
            let shape = (cmd["shape"] as? String) ?? "folder"
            let single = dropURLs.count == 1
            var accepted = 0
            for url in dropURLs {
                let provider = TestDropProvider.make(url: url, shape: shape)
                if BookDrop.load(from: provider, deliver: { [weak model] urls in
                    model?.add(urls: urls, openIfSingle: single && ((cmd["open"] as? Bool) ?? false))
                }) { accepted += 1 }
            }
            return ["ok": true, "accepted": accepted, "shape": shape]

        case "importState":
            // 取り込みの進み具合（帯に出しているものと同じ値）。完了はここを見て待つ。
            var out: [String: Any] = [
                "ok": true,
                "running": model.importProgress != nil,
                "report": model.importReport ?? NSNull(),
                "books": model.books.count,
            ]
            if let p = model.importProgress {
                out["progress"] = [
                    "done": p.done, "total": p.total,
                    "added": p.added, "skipped": p.skipped, "failed": p.failed,
                    "current": p.current,
                ]
            }
            return out

        case "cancelImport":
            model.cancelImport()
            return ["ok": true]

        case "openPanel":
            // メニュー「ファイル > 開く…」と同じ経路でファイルパネルを出す。
            // folders:true は「フォルダを追加…」（フォルダだけを選ぶパネル）。
            if (cmd["folders"] as? Bool) ?? false {
                model.requestFolderPanel = true
            } else {
                model.requestOpenPanel = true
            }
            return ["ok": true]

        case "displayState":
            // 表示まわりの現在値。全書籍の既定と、開いている本に実際に効いている値を並べて返す
            //（メニュー「表示」が既定と本ごとの指定のどちらを書き換えたかを機械検証するため）。
            let s = model.settings
            var out: [String: Any] = [
                "ok": true,
                "settings": [
                    "fontSize": s.fontSize, "lineHeight": s.lineHeight, "theme": s.theme,
                    "renderMode": s.renderMode, "writingMode": s.writingMode,
                    "bindingDirection": s.bindingDirection,
                    "imageSpread": s.imageSpread, "textSpread": s.textSpread,
                    "debugMode": s.debugMode,
                ],
            ]
            if let reader = model.activeReader {
                out["reader"] = [
                    "renderMode": reader.renderMode.rawValue,
                    "writingMode": reader.writingMode.rawValue,
                    "bindingDirection": reader.bindingDirection.rawValue,
                    "imageSpread": reader.imageSpread.rawValue,
                    "textSpread": reader.textSpread.rawValue,
                ]
            }
            if let book = model.openedBook.flatMap({ b in model.books.first { $0.id == b.id } }) {
                // 本ごとの上書き（nil = 既定に追従）。
                out["bookOverrides"] = [
                    "writingMode": book.writingMode as Any? ?? NSNull(),
                    "bindingDirection": book.bindingDirection as Any? ?? NSNull(),
                    "imageSpread": book.imageSpread as Any? ?? NSNull(),
                    "textSpread": book.textSpread as Any? ?? NSNull(),
                ]
            }
            return out

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

        // MARK: お気に入り・分類

        case "favorite", "unfavorite", "toggleFavorite":
            guard let b = match(cmd, model.books) else { return ["ok": false, "error": "book not found"] }
            switch name {
            case "favorite": model.setFavorite(bookID: b.id, true)
            case "unfavorite": model.setFavorite(bookID: b.id, false)
            default: model.toggleFavorite(bookID: b.id)
            }
            return ["ok": true, "title": b.title,
                    "favorite": model.books.first { $0.id == b.id }?.favorite ?? false]

        case "collections":
            return ["ok": true,
                    "collections": model.collections.map { c in
                        [
                            "id": c.id.uuidString,
                            "name": c.name,
                            "parent": c.parentID?.uuidString ?? NSNull(),
                            "order": c.order,
                            "path": CollectionTree.pathName(of: c.id, in: model.collections),
                        ] as [String: Any]
                    },
                    "counts": Dictionary(uniqueKeysWithValues:
                        model.shelfCounts().map { ($0.key.storageString, $0.value) })]

        case "collectionAdd":
            let parent = (cmd["parent"] as? String).flatMap(UUID.init(uuidString:))
                ?? (cmd["parent_name"] as? String).flatMap { n in
                    model.collections.first { $0.name == n }?.id
                }
            guard let id = model.addCollection(name: (cmd["name"] as? String) ?? "", parent: parent)
            else { return ["ok": false, "error": "name is empty"] }
            return ["ok": true, "id": id.uuidString,
                    "path": CollectionTree.pathName(of: id, in: model.collections)]

        case "collectionRename", "collectionRemove", "collectionMove":
            guard let c = matchCollection(cmd, model.collections)
            else { return ["ok": false, "error": "collection not found"] }
            switch name {
            case "collectionRename":
                model.renameCollection(id: c.id, to: (cmd["name"] as? String) ?? "")
            case "collectionRemove":
                model.removeCollection(id: c.id)
            default:
                let parent = (cmd["parent"] as? String).flatMap(UUID.init(uuidString:))
                    ?? (cmd["parent_name"] as? String).flatMap { n in
                        model.collections.first { $0.name == n }?.id
                    }
                model.moveCollection(id: c.id, under: parent)
            }
            return ["ok": true, "collections": model.collections.count]

        case "assign", "unassign":
            guard let b = match(cmd, model.books) else { return ["ok": false, "error": "book not found"] }
            guard let c = matchCollection(cmd, model.collections)
            else { return ["ok": false, "error": "collection not found"] }
            model.setMembership(bookID: b.id, collectionID: c.id, member: name == "assign")
            let updated = model.books.first { $0.id == b.id }
            return ["ok": true, "title": b.title,
                    "collections": (updated?.collectionList ?? []).map(\.uuidString)]

        case "shelfScope":
            if let raw = cmd["scope"] as? String {
                model.setScope(ShelfScope(storageString: raw))
            } else if let n = cmd["name"] as? String,
                      let c = model.collections.first(where: { $0.name == n }) {
                model.setScope(.collection(c.id))
            }
            return ["ok": true, "scope": model.shelfScope.storageString,
                    "count": model.books(in: model.shelfScope).count]

        case "shelfState":
            // 画面に出ている一覧（絞り込み・並び替え後）。切り替え直後は作り直しを挟むので、
            // 呼ぶ側は少し待つか、`model` 側の件数（scopeCount）と突き合わせる。
            let shown = shelfSnapshot?() ?? []
            return ["ok": true,
                    "scope": model.shelfScope.storageString,
                    "scopeCount": model.books(in: model.shelfScope).count,
                    "shownCount": shown.count,
                    "shown": shown.prefix(50).map { ["id": $0.0.uuidString, "title": $0.1] }]

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

// MARK: - ドロップの模擬（Finder のドラッグは AX から起こせないため）

/// Finder がドラッグで渡してくるのと同じ形の `NSItemProvider` を組む。
///
/// 実ドラッグの代わりにこれを `BookDrop` へ流し込めば、フォルダの展開だけでなく
/// **型の解決と実パスの取り出し**（Catalyst で何度も嵌まってきた所）まで通して検証できる。
enum TestDropProvider {
    static func make(url: URL, shape: String) -> NSItemProvider {
        let provider = NSItemProvider()
        switch shape {
        case "fileURL":
            // in-place 表現を持たず public.file-url だけ、という形（フォールバック経路の検証）。
            provider.registerItem(forTypeIdentifier: UTType.fileURL.identifier) { completion, _, _ in
                completion?(url as NSURL, nil)
            }
        default:
            let type = (shape == "epub") ? UTType.epub.identifier : UTType.folder.identifier
            provider.registerFileRepresentation(
                forTypeIdentifier: type, fileOptions: [.openInPlace], visibility: .all
            ) { completion in
                completion(url, true, nil)
                return nil
            }
        }
        return provider
    }
}
