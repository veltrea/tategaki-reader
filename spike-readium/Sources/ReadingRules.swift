import Foundation

// MARK: - 読み辞書（音声エンジンに渡す前の前処理）
//
// 音声エンジン側のユーザー辞書は使わない。エンジンの辞書は形態素解析のコストで語を
// 選ぶため、短い登録語が長い熟語を食い荒らす（1文字の「斎」を登録すると「斎藤」まで
// 巻き添えで読み替わる）。優先順位を指定しても、それは解析コストの調整であって
// 「置換する順番」ではないので、この事故は原理的に防げない。
//
// そこで辞書はアプリ側に持ち、合成へ渡す文字列だけを読み仮名へ置換してからエンジンに
// 渡す。置換順はレイヤー（1..10・大きいほど先）で決め、置換し終えた領域はロックして
// 以降のレイヤーでは走査しない。長い語を上のレイヤーに置けば、短い語は決して届かない。
// 画面表示と文ハイライト（ttsMark）は原文のままなので、見た目には影響しない。

/// 辞書エントリの照合方式。
enum ReadingEntryKind: String, Codable, CaseIterable, Identifiable {
    /// 表層をそのまま照合する（正規表現の記号もただの文字として扱う）。
    case word
    /// ICU 正規表現で照合する。読みの中で $1 などの捕捉参照が使える。
    case pattern

    var id: String { rawValue }
    var label: String { self == .word ? "語" : "パターン" }
}

/// 読み辞書の1件。
struct ReadingEntry: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    /// 本文中の書き方。`kind == .pattern` のときは正規表現。
    var surface: String = ""
    /// 読み。かなでもカタカナでもよい（合成直前にカタカナへ揃える）。
    var reading: String = ""
    /// 適用レイヤー 1...10。大きいほど先に適用され、短い語に食われなくなる。
    var layer: Int = 5
    var kind: ReadingEntryKind = .word
    /// 読みの前後に半角スペースを入れ、隣接する語との結合解析を断ち切る。
    /// 挿入した空白が生む無音は合成前に取り除くので、間延びはしない。
    var padsBoundary: Bool = false
    var enabled: Bool = true

    /// レイヤーの取りうる範囲。
    static let layerRange = 1 ... 10
}

// MARK: - 合成に渡す直前のテキスト

/// エンジンへ渡す文字列と、辞書が挿入した境界の位置。
///
/// `injectedGaps` は「ポーズを生む区切りを先頭から数えた序数」の集合で、
/// audio_query が返すポーズのうち無音化してよいものを指す。
public struct PreparedSpeech: Equatable {
    public let text: String
    public let injectedGaps: Set<Int>

    public init(text: String, injectedGaps: Set<Int>) {
        self.text = text
        self.injectedGaps = injectedGaps
    }

    public var isEmpty: Bool { text.isEmpty }

    /// 辞書を通さない素の文字列（テスト再生など）。
    public static func plain(_ text: String) -> PreparedSpeech {
        PreparedSpeech(text: text, injectedGaps: [])
    }
}

// MARK: - 区切りとポーズの対応

/// 音声エンジンがポーズを置く区切りの数え方。
///
/// audio_query は、区切り記号の並びとちょうど同じ順序で pause_mora を返す。
/// ただし実測（VOICEVOX 0.25.1）で次の癖があり、素朴に数えると対応がずれる。
///   - 連続した区切りは1つのポーズに潰れる（`"ア  イ"` のポーズは1つ）
///   - 前後どちらかに読む文字が無い区切りはポーズを生まない（文頭・文末の句点）
///   - 改行はポーズを生まない
enum SpeechGaps {
    /// 挿入した境界を最終文字列の中で見失わないための私用領域マーカー。
    /// 置換の途中で普通の空白にしてしまうと、原文由来の空白と区別できなくなる。
    static let boundaryMarker: Character = "\u{E000}"

    /// ポーズを生む区切り文字。
    static let separators: Set<Character> = [
        "、", "。", "！", "？", "…", "‥", "―", "—", "　", " ", boundaryMarker,
    ]
    /// ポーズも生まず、読む文字でもない字（区切りの前後判定から除く）。
    static let ignored: Set<Character> = ["\n", "\r", "\t"]

    /// 空白として扱う字（ここだけで構成された区切りは無音化してよい）。
    static func isBlank(_ c: Character) -> Bool {
        c == " " || c == "　" || c == boundaryMarker
    }

    /// 読み上げられる字か（区切りでも無視文字でもない）。
    static func isSpoken(_ c: Character) -> Bool {
        !separators.contains(c) && !ignored.contains(c)
    }

    /// ひらがな→カタカナ変換（エンジンはカタカナ読みを前提に解析するため）。
    static func hiraganaToKatakana(_ s: String) -> String {
        String(s.unicodeScalars.map { scalar -> Character in
            if (0x3041 ... 0x3096).contains(scalar.value),
               let up = Unicode.Scalar(scalar.value + 0x60) {
                return Character(up)
            }
            return Character(scalar)
        })
    }

    /// ポーズを生む区切りの範囲を、先頭から順に返す。
    static func gapRuns(in text: String) -> [Range<String.Index>] {
        var runs: [Range<String.Index>] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard separators.contains(text[i]) else {
                i = text.index(after: i)
                continue
            }
            var j = i
            while j < text.endIndex, separators.contains(text[j]) {
                j = text.index(after: j)
            }
            // 前にも後ろにも読む字があるときだけポーズになる。
            if text[text.startIndex ..< i].contains(where: isSpoken),
               text[j ..< text.endIndex].contains(where: isSpoken) {
                runs.append(i ..< j)
            }
            i = j
        }
        return runs
    }
}

// MARK: - 辞書の適用

/// 辞書をコンパイルして前処理を行う純ロジック（UI・ネットワーク非依存）。
struct ReadingDictionary {
    /// 置換の途中経過。`locked` の断片は以降のレイヤーで走査しない。
    private struct Segment {
        var text: String
        var locked: Bool
    }

    private struct Compiled {
        let regex: NSRegularExpression
        let template: String
        let padsBoundary: Bool
    }

    private let compiled: [Compiled]

    /// 無効・空・正規表現として不正なエントリはここで除外する（適用時には落ちない）。
    /// 並びはレイヤー降順、同レイヤー内は表層の長い順。長い語が先に確定するので、
    /// レイヤーを付け忘れても短い語が熟語を食う事故は起きにくい。
    init(entries: [ReadingEntry]) {
        let active = entries.filter { $0.enabled && !$0.surface.isEmpty }
        let ordered = active.sorted { (a: ReadingEntry, b: ReadingEntry) -> Bool in
            if a.layer != b.layer { return a.layer > b.layer }
            return a.surface.count > b.surface.count
        }
        compiled = ordered.compactMap(Self.compile)
    }

    private static func compile(_ entry: ReadingEntry) -> Compiled? {
        let pattern: String = entry.kind == .word
            ? NSRegularExpression.escapedPattern(for: entry.surface)
            : entry.surface
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let reading = SpeechGaps.hiraganaToKatakana(entry.reading)
        // 語は読みをそのまま出す（$ を含んでも捕捉参照と誤解させない）。
        let template: String = entry.kind == .word
            ? NSRegularExpression.escapedTemplate(for: reading)
            : reading
        return Compiled(regex: regex, template: template, padsBoundary: entry.padsBoundary)
    }

    /// 辞書を適用し、合成に渡す文字列と挿入境界の位置を返す。
    func prepare(_ raw: String) -> PreparedSpeech {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .plain("") }
        var segments = [Segment(text: normalized, locked: false)]
        for entry in compiled {
            segments = apply(entry, to: segments)
        }
        return resolve(segments)
    }

    /// 1エントリを未確定の断片だけに適用し、置換した箇所をロックして返す。
    private func apply(_ entry: Compiled, to segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for segment in segments {
            guard !segment.locked else {
                out.append(segment)
                continue
            }
            out.append(contentsOf: split(segment.text, by: entry))
        }
        return out
    }

    /// 1つの未確定断片を「一致しなかった部分」と「読みに置き換えてロックした部分」に割る。
    private func split(_ text: String, by entry: Compiled) -> [Segment] {
        let full = NSRange(text.startIndex ..< text.endIndex, in: text)
        let matches = entry.regex.matches(in: text, range: full)
        guard !matches.isEmpty else { return [Segment(text: text, locked: false)] }

        var out: [Segment] = []
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text), !range.isEmpty else { continue }
            if cursor < range.lowerBound {
                out.append(Segment(text: String(text[cursor ..< range.lowerBound]), locked: false))
            }
            var reading = entry.regex.replacementString(
                for: match, in: text, offset: 0, template: entry.template)
            if entry.padsBoundary {
                reading = "\(SpeechGaps.boundaryMarker)\(reading)\(SpeechGaps.boundaryMarker)"
            }
            out.append(Segment(text: reading, locked: true))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            out.append(Segment(text: String(text[cursor...]), locked: false))
        }
        return out
    }

    /// 断片を連結し、マーカーの位置から挿入境界の序数を割り出して空白へ戻す。
    private func resolve(_ segments: [Segment]) -> PreparedSpeech {
        let joined = segments.map(\.text).joined()
        var injected: Set<Int> = []
        for (ordinal, range) in SpeechGaps.gapRuns(in: joined).enumerated() {
            let run = joined[range]
            // 読点などが隣接していたらそちらのポーズを尊重し、無音化しない。
            if run.contains(SpeechGaps.boundaryMarker), run.allSatisfy(SpeechGaps.isBlank) {
                injected.insert(ordinal)
            }
        }
        // マーカーも空白として数えていたので、置き換えても区切りの並びは変わらない。
        let text = joined
            .replacingOccurrences(of: String(SpeechGaps.boundaryMarker), with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PreparedSpeech(text: text, injectedGaps: injected)
    }
}

// MARK: - 永続化

/// 読み辞書の永続化（全書籍共通・UserDefaults）。
enum ReadingDictionaryStore {
    static let key = "tts.readingDictionary.v2"
    /// 旧「読み替えルール」（正規表現のみ・配列順で適用）のキー。
    private static let legacyKey = "tts.readingRules.v1"

    static func load() -> [ReadingEntry] {
        if let data = UserDefaults.standard.data(forKey: key),
           let entries = try? JSONDecoder().decode([ReadingEntry].self, from: data) {
            return entries
        }
        let migrated = migrateLegacy()
        if !migrated.isEmpty { save(migrated) }
        return migrated
    }

    static func save(_ entries: [ReadingEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 旧ルールをパターン種別として引き継ぐ。適用順が配列順だったので、
    /// 先頭ほど上のレイヤーに割り当てて従来の優先関係を保つ。
    private static func migrateLegacy() -> [ReadingEntry] {
        struct LegacyRule: Codable {
            var pattern: String
            var replacement: String
            var enabled: Bool
        }
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let rules = try? JSONDecoder().decode([LegacyRule].self, from: data)
        else { return [] }
        return rules.enumerated().map { index, rule in
            ReadingEntry(
                surface: rule.pattern,
                reading: rule.replacement,
                layer: max(ReadingEntry.layerRange.lowerBound, 10 - index),
                kind: .pattern,
                enabled: rule.enabled)
        }
    }
}
