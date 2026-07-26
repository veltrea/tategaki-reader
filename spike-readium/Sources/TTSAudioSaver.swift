import Foundation

// MARK: - 読み上げエンジン設定（環境設定）

/// 読み上げエンジン（VOICEVOX / AivisSpeech）の接続・音声パラメータ設定。UserDefaults に永続化。
struct AudioSettings: Codable, Equatable {
    /// エンジン種別プリセット。URL の既定ポートを決めるだけで、実際の接続先は baseURLString。
    var engine: String = "voicevox"                  // "voicevox" | "aivis"
    var baseURLString: String = "http://127.0.0.1:50021"
    var speaker: Int = 2                             // style id（四国めたん ノーマル）
    var speedScale: Double = 1.0                    // 話速
    var pauseLengthScale: Double = 1.5              // 無音（改行・句読点の間）の長さ

    /// エンジンプリセットの既定 URL。
    static func defaultURL(for engine: String) -> String {
        engine == "aivis" ? "http://127.0.0.1:10101" : "http://127.0.0.1:50021"
    }

    var baseURL: URL {
        URL(string: baseURLString) ?? URL(string: AudioSettings.defaultURL(for: engine))!
    }

    /// VoicevoxSpeaker.Config へ変換。
    func makeConfig() -> VoicevoxSpeaker.Config {
        VoicevoxSpeaker.Config(
            baseURL: baseURL, speaker: speaker,
            speedScale: speedScale, pauseLengthScale: pauseLengthScale)
    }

    init(engine: String = "voicevox", baseURLString: String = "http://127.0.0.1:50021",
         speaker: Int = 2, speedScale: Double = 1.0, pauseLengthScale: Double = 1.5) {
        self.engine = engine
        self.baseURLString = baseURLString
        self.speaker = speaker
        self.speedScale = speedScale
        self.pauseLengthScale = pauseLengthScale
    }

    // 欠損キーは既定で補う（設定項目を後から増やしても旧データを読める）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "voicevox"
        baseURLString = try c.decodeIfPresent(String.self, forKey: .baseURLString)
            ?? "http://127.0.0.1:50021"
        speaker = try c.decodeIfPresent(Int.self, forKey: .speaker) ?? 2
        speedScale = try c.decodeIfPresent(Double.self, forKey: .speedScale) ?? 1.0
        pauseLengthScale = try c.decodeIfPresent(Double.self, forKey: .pauseLengthScale) ?? 1.5
    }
}

/// AudioSettings の UserDefaults 永続化。
enum AudioSettingsStore {
    private static let key = "audio.settings.v1"

    static func load() -> AudioSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AudioSettings.self, from: data)
        else { return AudioSettings() }
        return s
    }

    static func save(_ s: AudioSettings) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - 読み上げ音声の保存先（環境設定）

/// 読み上げをファイル保存するときの出力先ディレクトリ。
///
/// このアプリは App Sandbox 無効（entitlements 無し）なので、フォルダピッカーで選んだ
/// パス文字列をそのまま保存・再利用できる（security-scoped bookmark は不要）。
/// 未設定のときは ~/Downloads を既定にする。
enum TTSSaveLocation {
    private static let pathKey = "tts.saveDirectoryPath"

    /// ユーザーが選んだ保存先の表示用パス（未設定なら nil）。
    static var displayPath: String? {
        UserDefaults.standard.string(forKey: pathKey)
    }

    /// フォルダピッカーで選ばれたディレクトリを保存先として記録する。
    static func setDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: pathKey)
    }

    /// 設定を消して既定（~/Downloads）に戻す。
    static func clear() {
        UserDefaults.standard.removeObject(forKey: pathKey)
    }

    /// 実際の書き込み先ディレクトリ。未設定なら ~/Downloads。存在しなければ作成する。
    static func resolveDirectory() -> URL {
        let dir: URL
        if let path = displayPath, !path.isEmpty {
            dir = URL(fileURLWithPath: path, isDirectory: true)
        } else if let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first {
            dir = downloads
        } else {
            // 最後の砦: ホーム直下（Catalyst は homeDirectoryForCurrentUser 不可のため NSHomeDirectory）。
            dir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Downloads", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - WAV 連結

/// VOICEVOX が返す複数の WAV(16bit PCM) を1本のファイルに連結するユーティリティ。
/// 全チャンクが同一フォーマット（同じ speaker/engine の出力）である前提。
enum WAV {
    /// 複数 WAV を連結して1本の WAV データにする。パースに失敗したら nil。
    static func concatenate(_ wavs: [Data]) -> Data? {
        var fmtChunk: [UInt8]?
        var pcm = [UInt8]()
        for wav in wavs {
            guard let parsed = parse([UInt8](wav)) else { return nil }
            if fmtChunk == nil { fmtChunk = parsed.fmt }
            pcm.append(contentsOf: parsed.data)
        }
        guard let fmt = fmtChunk, !pcm.isEmpty else { return nil }
        return Data(build(fmt: fmt, pcm: pcm))
    }

    /// RIFF/WAVE から `fmt ` チャンク本体と `data` チャンク本体を取り出す。
    private static func parse(_ b: [UInt8]) -> (fmt: [UInt8], data: [UInt8])? {
        guard b.count > 12,
              Array(b[0 ..< 4]) == Array("RIFF".utf8),
              Array(b[8 ..< 12]) == Array("WAVE".utf8)
        else { return nil }
        var i = 12
        var fmt: [UInt8]?
        var data: [UInt8]?
        while i + 8 <= b.count {
            let id = Array(b[i ..< i + 4])
            let size = Int(u32(b, i + 4))
            let bodyStart = i + 8
            let end = min(bodyStart + size, b.count)
            guard bodyStart <= end else { break }
            if id == Array("fmt ".utf8) { fmt = Array(b[bodyStart ..< end]) }
            else if id == Array("data".utf8) { data = Array(b[bodyStart ..< end]) }
            // チャンクは偶数境界に整列（奇数サイズなら1バイトパディング）。
            i = bodyStart + size + (size & 1)
        }
        guard let f = fmt, let d = data else { return nil }
        return (f, d)
    }

    /// fmt チャンク本体と連結済み PCM から標準的な WAV バイト列を組み立てる。
    private static func build(fmt: [UInt8], pcm: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        let dataSize = UInt32(pcm.count)
        let fmtSize = UInt32(fmt.count)
        // RIFF チャンクサイズ = "WAVE"(4) + fmtチャンク(8+fmtSize) + dataチャンク(8+dataSize)
        let riffSize = 4 + (8 + fmtSize) + (8 + dataSize)
        out.append(contentsOf: Array("RIFF".utf8)); out.append(contentsOf: le(riffSize))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); out.append(contentsOf: le(fmtSize))
        out.append(contentsOf: fmt)
        out.append(contentsOf: Array("data".utf8)); out.append(contentsOf: le(dataSize))
        out.append(contentsOf: pcm)
        return out
    }

    /// 行ごとの WAV を「タイムラインの開始時刻」に配置して 1 本に合成する（動画の音声トラック用）。
    /// 連結（concatenate）と違い、行間の無音（gap/pause）ぶんを開けて並べるので、
    /// 動画の字幕掃引（同じ start を使う）と音声がぴったり合う。16bit PCM 前提・重なりは加算クランプ。
    /// - Parameters:
    ///   - lines: (その行の WAV, 絶対開始秒) の並び。全 WAV は同一フォーマット（同一 speaker 出力）前提。
    ///   - totalDuration: タイムライン総尺（秒）。末尾に tail ぶん余白を足して確保する。
    static func compose(lines: [(wav: Data, start: Double)],
                        totalDuration: Double, tail: Double = 0.4) -> Data? {
        guard let first = lines.first, let p0 = parse([UInt8](first.wav)) else { return nil }
        let fmt = p0.fmt
        guard fmt.count >= 16 else { return nil }
        let channels = Int(u16(fmt, 2))
        let sampleRate = Int(u32(fmt, 4))
        let bits = Int(u16(fmt, 14))
        guard bits == 16, channels >= 1, sampleRate > 0 else { return nil }

        let totalFrames = Int((totalDuration + tail) * Double(sampleRate)) + 1
        var out = [Int16](repeating: 0, count: max(1, totalFrames * channels))
        for line in lines {
            guard let p = parse([UInt8](line.wav)) else { continue }
            let pcm = p.data
            let startIdx = Int(line.start * Double(sampleRate)) * channels
            let n = pcm.count / 2
            for i in 0 ..< n {
                let dst = startIdx + i
                if dst < 0 || dst >= out.count { continue }
                let s = Int16(bitPattern: UInt16(pcm[i * 2]) | (UInt16(pcm[i * 2 + 1]) << 8))
                out[dst] = Int16(clamping: Int(out[dst]) + Int(s))
            }
        }
        var bytes = [UInt8](); bytes.reserveCapacity(out.count * 2)
        for v in out {
            let u = UInt16(bitPattern: v)
            bytes.append(UInt8(u & 0xFF)); bytes.append(UInt8(u >> 8))
        }
        return Data(build(fmt: fmt, pcm: bytes))
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func le(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}
