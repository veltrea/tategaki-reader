import AVFoundation
import Foundation

// 音声エンジン側のユーザー辞書（/user_dict）はこのアプリでは使わない。
// 短い登録語が長い熟語を食い荒らす問題を優先度指定では解けないため、辞書は
// ReadingDictionary（アプリ側の前処理）に一本化した。経緯は ReadingRules.swift 冒頭。

/// 話者スタイル1件（/speakers の name × styles を平坦化。UI のドロップダウン用）。
struct VoicevoxSpeakerStyle: Identifiable, Equatable {
    let id: Int          // style id（synthesis の speaker 値）
    let label: String    // "四国めたん / ノーマル"
}

/// VOICEVOX / AivisSpeech の版数・話者一覧を取得する（設定シートの接続確認・話者選択用）。
enum VoicevoxCatalog {

    /// GET /version。到達不可なら nil（＝未接続）。
    static func version(baseURL: URL) async -> String? {
        guard let (data, resp) = try? await URLSession.shared.data(
                from: baseURL.appendingPathComponent("version")),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // "0.25.1" のように JSON 文字列で返る。素の文字列として読む。
        if let s = try? JSONSerialization.jsonObject(with: data) as? String { return s }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
    }

    /// GET /speakers → [{name, styles:[{name, id}]}] を平坦化。失敗なら nil。
    static func speakers(baseURL: URL) async -> [VoicevoxSpeakerStyle]? {
        guard let (data, resp) = try? await URLSession.shared.data(
                from: baseURL.appendingPathComponent("speakers")),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        var out: [VoicevoxSpeakerStyle] = []
        for sp in arr {
            let name = (sp["name"] as? String) ?? "?"
            for st in (sp["styles"] as? [[String: Any]]) ?? [] {
                guard let sid = (st["id"] as? NSNumber)?.intValue else { continue }
                let style = (st["name"] as? String) ?? ""
                out.append(VoicevoxSpeakerStyle(id: sid, label: "\(name) / \(style)"))
            }
        }
        return out
    }
}

/// VOICEVOX / AivisSpeech の合成＋再生（Readium 非依存の独立実装）。
///
/// audio_query → (speedScale / pauseLengthScale を適用) → synthesis → AVAudioPlayer 再生。
/// VOICEVOX と AivisSpeech は API 互換なので baseURL のポートを変えるだけで両対応。
/// `speak(text:)` は再生完了まで await する。`pause()`/`resume()` は文の途中位置を保持する。
public final class VoicevoxSpeaker: NSObject, AVAudioPlayerDelegate {
    public struct Config {
        public var baseURL: URL
        public var speaker: Int
        public var speedScale: Double
        public var pauseLengthScale: Double

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:50021")!, // AivisSpeech は :10101
            speaker: Int = 2,             // 四国めたん ノーマル
            speedScale: Double = 1.0,
            pauseLengthScale: Double = 1.5 // ユーザー確定の既定値
        ) {
            self.baseURL = baseURL
            self.speaker = speaker
            self.speedScale = speedScale
            self.pauseLengthScale = pauseLengthScale
        }
    }

    public var config: Config
    private let session: URLSession
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Error>?

    public init(config: Config = Config(), session: URLSession = .shared) {
        self.config = config
        self.session = session
        super.init()
    }

    /// 1文を合成し、再生せずに WAV データだけ返す（ファイル保存用）。
    /// speak と同じ audio_query → synthesis 経路なので、聞こえる読みと保存音声が一致する。
    public func synthesizeWAV(_ prepared: PreparedSpeech) async throws -> Data {
        try await synthesizeCore(prepared).wav
    }

    /// 1行を合成し、（speed/pause 適用済みの）audio_query JSON と WAV を両方返す。
    /// 動画レンダラ（harness）に渡すと、ブラウザ側で VOICEVOX へ fetch せずに
    /// （CORS/ATS を回避して）モーラ尺からカラオケ字幕のタイムラインを再構築できる。
    /// synthesis に使ったのと同一の query を返すので、字幕の掃引と音声が一致する。
    public func synthesizeLine(_ prepared: PreparedSpeech) async throws -> (queryJSON: Data, wav: Data) {
        try await synthesizeCore(prepared)
    }

    /// 1文を合成して再生し、再生完了まで待つ。停止(stop)で CancellationError を投げる。
    public func speak(_ prepared: PreparedSpeech) async throws {
        let wav = try await synthesizeCore(prepared).wav
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // 直前の再生が残っていたら終わらせる。
            finishCurrent(with: .failure(CancellationError()))
            do {
                let p = try AVAudioPlayer(data: wav)
                p.delegate = self
                player = p
                continuation = cont
                p.prepareToPlay()
                p.play()
            } catch {
                continuation = nil
                cont.resume(throwing: error)
            }
        }
    }

    /// 一時停止（再生位置保持）。
    public func pause() { player?.pause() }

    /// 一時停止からの再開。
    public func resume() { player?.play() }

    /// 完全停止（実行中の speak は CancellationError で返る）。
    public func stop() {
        player?.stop()
        player = nil
        finishCurrent(with: .failure(CancellationError()))
    }

    private func finishCurrent(with result: Result<Void, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        switch result {
        case .success: cont.resume()
        case let .failure(e): cont.resume(throwing: e)
        }
    }

    // MARK: - VOICEVOX HTTP

    /// audio_query（speed/pause 適用済み）と synthesis を実行し、両方を返す共有コア。
    private func synthesizeCore(_ prepared: PreparedSpeech) async throws -> (queryJSON: Data, wav: Data) {
        // 1) audio_query
        var qc = URLComponents(
            url: config.baseURL.appendingPathComponent("audio_query"),
            resolvingAgainstBaseURL: false
        )!
        qc.queryItems = [
            URLQueryItem(name: "text", value: prepared.text),
            URLQueryItem(name: "speaker", value: String(config.speaker)),
        ]
        var qReq = URLRequest(url: qc.url!)
        qReq.httpMethod = "POST"
        let (qData, qResp) = try await session.data(for: qReq)
        guard (qResp as? HTTPURLResponse)?.statusCode == 200 else {
            throw VoicevoxError.badResponse("audio_query")
        }

        // 2) speedScale / pauseLengthScale を適用し、辞書が挿入した境界の無音を消す
        var query = (try JSONSerialization.jsonObject(with: qData) as? [String: Any]) ?? [:]
        query["speedScale"] = config.speedScale
        if query["pauseLengthScale"] != nil {
            query["pauseLengthScale"] = config.pauseLengthScale
        }
        Self.silenceInjectedGaps(in: &query, prepared: prepared)
        let body = try JSONSerialization.data(withJSONObject: query)

        // 3) synthesis
        var sc = URLComponents(
            url: config.baseURL.appendingPathComponent("synthesis"),
            resolvingAgainstBaseURL: false
        )!
        sc.queryItems = [URLQueryItem(name: "speaker", value: String(config.speaker))]
        var sReq = URLRequest(url: sc.url!)
        sReq.httpMethod = "POST"
        sReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sReq.httpBody = body
        let (wav, sResp) = try await session.data(for: sReq)
        guard (sResp as? HTTPURLResponse)?.statusCode == 200 else {
            throw VoicevoxError.badResponse("synthesis")
        }
        // query は synthesis に送った body（speed/pause 適用済み）を返す＝字幕タイミングと音声が一致。
        return (queryJSON: body, wav: wav)
    }

    /// 辞書が語境界を作るために挿入した空白の無音だけを取り除く。
    ///
    /// 空白を入れると隣接語との結合解析は断ち切れるが、代わりに約0.45秒の無音が入り
    /// 朗読が途切れる。audio_query は区切り記号の並びと同じ順序で pause_mora を返すので、
    /// 挿入した境界に対応するものだけを長さ0にする。読点由来の間はそのまま残る。
    ///
    /// 数え方が食い違ったときは何もしない（無音が残るだけで、読み自体は壊れない）。
    static func silenceInjectedGaps(in query: inout [String: Any], prepared: PreparedSpeech) {
        guard !prepared.injectedGaps.isEmpty,
              var phrases = query["accent_phrases"] as? [[String: Any]]
        else { return }

        let paused = phrases.indices.filter { phrases[$0]["pause_mora"] is [String: Any] }
        guard paused.count == SpeechGaps.gapRuns(in: prepared.text).count else { return }

        for (ordinal, index) in paused.enumerated()
        where prepared.injectedGaps.contains(ordinal) {
            guard var mora = phrases[index]["pause_mora"] as? [String: Any] else { continue }
            mora["vowel_length"] = 0.0
            phrases[index]["pause_mora"] = mora
        }
        query["accent_phrases"] = phrases
    }

    enum VoicevoxError: LocalizedError {
        case badResponse(String)
        var errorDescription: String? {
            if case let .badResponse(api) = self { return "VOICEVOX \(api) 失敗" }
            return nil
        }
    }

    // MARK: - AVAudioPlayerDelegate

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishCurrent(with: .success(()))
    }
}
