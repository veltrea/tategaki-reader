import CryptoKit
import Foundation

// MARK: - 翻訳設定（環境設定）

/// LM Studio（OpenAI 互換 API）を使った対訳表示の設定。UserDefaults に永続化。
///
/// LM Studio は `/v1/models` と `/v1/chat/completions` を素の OpenAI 形式で提供する。
/// 認証は不要（ローカル）だが、別マシンで動かしている場合のために URL は自由入力にする。
struct TranslationSettings: Codable, Equatable {
    /// LM Studio のサーバ URL。`/v1` は付けても付けなくてもよい（`TranslationSettings.apiURL` が吸収する）。
    var baseURLString: String = "http://127.0.0.1:1234"
    /// 使うモデル id（`/v1/models` の id）。空なら一覧の先頭を使う。
    var model: String = ""
    /// 訳文の言語。
    var targetLanguage: String = "ja"
    /// 原文の言語（"auto" はモデルに判定させる）。
    var sourceLanguage: String = "auto"
    /// 直前の段落を「参考」としてプロンプトに含める（代名詞や話者の取り違えを減らす）。
    var useContext: Bool = true
    /// 同時に投げるリクエスト数。ローカル LLM は並列で速くならないことも多いので既定は控えめ。
    var concurrency: Int = 2
    var temperature: Double = 0.2
    /// 推論（thinking）を止めるよう頼む。
    ///
    /// 推論モデルは1段落の訳に思考を数百トークン費やすので、ページ単位の対訳には実用速度で届かない
    /// （実測: qwen3.5-9b で "The Cemetery" の2語に約100秒。gemma-3-4b なら段落1本が約18秒）。
    /// chat template が対応していれば効き、対応していないモデルでは無視される（渡しても壊れない）。
    var disableThinking: Bool = true

    var baseURL: URL {
        URL(string: baseURLString.trimmingCharacters(in: .whitespaces))
            ?? URL(string: "http://127.0.0.1:1234")!
    }

    /// baseURL に OpenAI 互換のパスを足す。ユーザーが `…:1234/v1` まで入れていても二重にしない。
    func apiURL(_ path: String) -> URL {
        var base = baseURL
        if base.lastPathComponent == "v1" { base.deleteLastPathComponent() }
        return base.appendingPathComponent("v1").appendingPathComponent(path)
    }

    init(baseURLString: String = "http://127.0.0.1:1234", model: String = "",
         targetLanguage: String = "ja", sourceLanguage: String = "auto",
         useContext: Bool = true, concurrency: Int = 2, temperature: Double = 0.2,
         disableThinking: Bool = true) {
        self.baseURLString = baseURLString
        self.model = model
        self.targetLanguage = targetLanguage
        self.sourceLanguage = sourceLanguage
        self.useContext = useContext
        self.concurrency = concurrency
        self.temperature = temperature
        self.disableThinking = disableThinking
    }

    // 欠損キーは既定で補う（設定項目を後から増やしても旧データを読める）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURLString = try c.decodeIfPresent(String.self, forKey: .baseURLString)
            ?? "http://127.0.0.1:1234"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? "ja"
        sourceLanguage = try c.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? "auto"
        useContext = try c.decodeIfPresent(Bool.self, forKey: .useContext) ?? true
        concurrency = try c.decodeIfPresent(Int.self, forKey: .concurrency) ?? 2
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.2
        disableThinking = try c.decodeIfPresent(Bool.self, forKey: .disableThinking) ?? true
    }
}

/// TranslationSettings の UserDefaults 永続化。
enum TranslationSettingsStore {
    private static let key = "translation.settings.v1"

    static func load() -> TranslationSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(TranslationSettings.self, from: data)
        else { return TranslationSettings() }
        return s
    }

    static func save(_ s: TranslationSettings) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// 対訳で選べる言語。プロンプトへはモデルが確実に解釈できる英語名で渡す。
enum TranslationLanguage {
    /// (コード, 表示名, プロンプト用の英語名)
    static let all: [(code: String, label: String, english: String)] = [
        ("ja", "日本語", "Japanese"),
        ("en", "English", "English"),
        ("zh", "中文", "Chinese"),
        ("ko", "한국어", "Korean"),
        ("fr", "Français", "French"),
        ("de", "Deutsch", "German"),
        ("es", "Español", "Spanish"),
    ]

    /// プロンプトに載せる英語名。未知のコードはそのまま返す。
    static func english(_ code: String) -> String {
        all.first { $0.code == code }?.english ?? code
    }

    /// UI 表示名。
    static func label(_ code: String) -> String {
        code == "auto" ? String(localized: "自動判定") : (all.first { $0.code == code }?.label ?? code)
    }
}

// MARK: - LM Studio クライアント（OpenAI 互換）

struct LMStudioModel: Identifiable, Hashable {
    let id: String
}

enum LMStudioError: LocalizedError {
    case badResponse(Int)
    case emptyChoice
    case notReachable

    var errorDescription: String? {
        switch self {
        case let .badResponse(code): return String(format: String(localized: "LM Studio がエラーを返しました (HTTP %d)"), code)
        case .emptyChoice:           return String(localized: "LM Studio の応答が空でした")
        case .notReachable:          return String(localized: "LM Studio に接続できません")
        }
    }
}

/// LM Studio の OpenAI 互換 API を叩く薄いクライアント。
///
/// URLSession を注入できるようにしてあるので、ネットワークを持たない単体テストからも使える
/// （このプロジェクトの JS/TS 方針と同じく、ロジックを実行環境から切り離しておく）。
enum LMStudioClient {

    /// GET /v1/models。到達不可なら nil（＝未接続）。
    static func models(settings: TranslationSettings, session: URLSession = .shared) async -> [LMStudioModel]? {
        var req = URLRequest(url: settings.apiURL("models"))
        req.timeoutInterval = 8
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]]
        else { return nil }
        // 埋め込み専用モデルは翻訳に使えないので落とす（LM Studio は同じ一覧に混ぜて返す）。
        return arr.compactMap { $0["id"] as? String }
            .filter { !$0.contains("embed") }
            .map(LMStudioModel.init(id:))
    }

    /// POST /v1/chat/completions。1往復で本文だけを返す。
    static func chat(
        settings: TranslationSettings, model: String,
        system: String, user: String,
        session: URLSession = .shared
    ) async throws -> String {
        var req = URLRequest(url: settings.apiURL("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // ローカルの大きめモデルは1段落でも数十秒かかることがある。既定の60秒では足りない。
        req.timeoutInterval = 300
        var body: [String: Any] = [
            "model": model,
            "temperature": settings.temperature,
            "stream": false,
            // 暴走への保険。訳文は原文とだいたい同じ長さなので、これだけあれば切れない。
            "max_tokens": min(4096, max(512, user.count)),
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if settings.disableThinking {
            // Qwen 系などの chat template が読む変数。対応していないモデルでは無視される。
            body["chat_template_kwargs"] = ["enable_thinking": false]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LMStudioError.badResponse(code) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw LMStudioError.emptyChoice }

        let cleaned = cleanCompletion(content)
        guard !cleaned.isEmpty else { throw LMStudioError.emptyChoice }
        return cleaned
    }

    /// 推論モデルの思考ブロックや前置きを落として訳文だけにする。
    ///
    /// LM Studio で動く推論系モデル（qwen3 系など）は `<think>…</think>` を本文に混ぜて返す。
    /// また指示に反して "Translation:" と前置きしたり、全体を引用符で囲むモデルもある。
    static func cleanCompletion(_ raw: String) -> String {
        var s = raw
        // <think>…</think>（閉じタグが無いまま切れることもあるので、その場合は以降を全部落とす）。
        while let open = s.range(of: "<think>") {
            if let close = s.range(of: "</think>", range: open.upperBound ..< s.endIndex) {
                s.removeSubrange(open.lowerBound ..< close.upperBound)
            } else {
                s.removeSubrange(open.lowerBound ..< s.endIndex)
                break
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // 行頭のラベル（"Translation:" / "日本語訳:" など）を1行だけ剥がす。
        let labels = ["translation:", "translated:", "japanese:", "訳:", "日本語訳:", "翻訳:"]
        for label in labels where s.lowercased().hasPrefix(label) {
            s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        // 全体を囲む引用符（対で、かつ内側に同じ記号が出てこない場合だけ）。
        for (open, close) in [("\"", "\""), ("「", "」"), ("“", "”")] {
            if s.hasPrefix(open), s.hasSuffix(close), s.count > open.count + close.count {
                let inner = String(s.dropFirst(open.count).dropLast(close.count))
                if !inner.contains(close) { s = inner }
                break
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: プロンプト

    /// 翻訳のシステムプロンプト。指示は英語で書く（モデルの追従率が素直に高い）。
    static func systemPrompt(settings: TranslationSettings) -> String {
        let target = TranslationLanguage.english(settings.targetLanguage)
        let source = settings.sourceLanguage == "auto"
            ? "the source language"
            : TranslationLanguage.english(settings.sourceLanguage)
        return """
        You are a professional literary translator. Translate the given passage from \(source) into \(target).

        Rules:
        - Output ONLY the translation. No preface, no notes, no romanization, no quotation marks around the whole output.
        - Translate the passage as a whole; keep the author's tone, register and paragraph structure.
        - Keep proper nouns consistent. Do not add or drop information.
        - If the passage is a heading or a fragment, translate it as such — do not turn it into a sentence.
        """
    }

    /// 1段落ぶんのユーザープロンプト。直前の段落は文脈としてだけ渡す（訳出させない）。
    static func userPrompt(text: String, previous: String?) -> String {
        guard let previous, !previous.isEmpty else { return text }
        return """
        [Context — the preceding passage. Do NOT translate this part.]
        \(previous)

        [Passage to translate]
        \(text)
        """
    }
}

// MARK: - 訳のキャッシュ

/// 段落テキスト → 訳文のキャッシュ。
///
/// ページを行き来するたびに同じ段落を訳し直すとローカル LLM では待ち時間が支配的になるので、
/// （モデル・訳先言語・原文）の組をキーにして訳を貯める。メモリとディスクの二段。
actor TranslationCache {
    static let shared = TranslationCache()

    private var map: [String: String] = [:]
    private var loaded = false
    private var saveTask: Task<Void, Never>?

    /// 上限。超えたら古い順に落とす（挿入順は order で持つ）。
    private static let limit = 4000
    private var order: [String] = []

    /// 訳の貯め先。**書棚ごとに分ける**（原文がそのまま入るので、別の書棚を見せているときに
    /// 手元の蔵書の本文が対訳ペインへ出てこないように）。
    private var fileURL: URL { ProfileLocation.shared.translationCacheURL }

    /// いま抱えている訳が**どの書棚のものか**。
    ///
    /// 書き出しはまとめて（2秒ぶん）行うので、書棚を切り替えた直後に書き出しが走ると
    /// `fileURL` は既に新しい書棚を指している——**前の書棚の原文がそのまま新しい書棚の
    /// ファイルへ移ってしまう**。読んだ／書き足した時点の場所を控えておき、書き出しは必ず
    /// そこへ向ける。
    private var origin: URL?

    /// （モデル・訳先言語・原文）からキーを作る。原文は長いので SHA256 に畳む。
    nonisolated static func key(model: String, target: String, text: String) -> String {
        let digest = SHA256.hash(data: Data("\(model)|\(target)|\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func value(for key: String) -> String? {
        loadIfNeeded()
        return map[key]
    }

    func set(_ value: String, for key: String) {
        loadIfNeeded()
        if map[key] == nil { order.append(key) }
        map[key] = value
        if order.count > Self.limit {
            let drop = order.prefix(order.count - Self.limit)
            for k in drop { map.removeValue(forKey: k) }
            order.removeFirst(order.count - Self.limit)
        }
        scheduleSave()
    }

    /// 全消去（設定シートの「訳のキャッシュを消す」用）。
    func clear() {
        saveTask?.cancel()
        saveTask = nil
        map = [:]
        order = []
        loaded = true
        origin = fileURL
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 書棚を切り替えたときに、抱えている訳を手放す（次に要るときは新しい書棚から読み直す）。
    /// 溜めている書き込みは**元の書棚のファイルへ書き切ってから**捨てる。
    func detach() {
        saveTask?.cancel()
        saveTask = nil
        if loaded, let origin { flush(to: origin) }
        map = [:]
        order = []
        loaded = false
        origin = nil
    }

    func count() -> Int {
        loadIfNeeded()
        return map.count
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let url = fileURL
        origin = url
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        map = obj
        order = Array(obj.keys)
    }

    /// 書き込みは束ねる（段落ごとに数百件の I/O を出さない）。
    private func scheduleSave() {
        let target = origin ?? fileURL
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.flush(to: target)
        }
    }

    private func flush(to url: URL) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - 対訳の1行

/// 対訳ペインの1行（原文の段落と、その訳）。
struct TranslationUnit: Identifiable, Equatable {
    enum State: Equatable {
        case pending          // 順番待ち
        case running          // 翻訳中
        case done             // 訳あり
        case failed(String)   // 失敗（理由）
    }

    /// 段落の CFI（本文へジャンプするときの行き先。取れない段落は連番）。
    let id: String
    /// 見出しなら true（ペインで強調表示する）。
    let isHeading: Bool
    let source: String
    var translated: String = ""
    var state: State = .pending

    var isSettled: Bool {
        if case .pending = state { return false }
        if case .running = state { return false }
        return true
    }
}
