import Foundation

// MARK: - 書棚ひとつ分の人格

/// 書棚（プロファイル）ひとつ。
///
/// 蔵書の一覧・分類・お気に入り・読書位置・しおり・表紙・読み辞書・全書籍共通CSS を、この単位で
/// 分ける。**本の実体（EPUB ファイル）は分けない**——同じ本を複数の書棚に登録してよく、書棚を
/// 消してもファイルは消えない。
///
/// **なぜ要るか。** 手元の蔵書には人へ見せられない本が混じる（仕事で預かったデータなど）。
/// 画面を見せるとき欲しいのは「隠す」ことではなく「そのファイルを読んでいない」状態である。
/// 隠す作りは、解除し忘れ・表紙のメモリキャッシュの残り・書棚の地（`ShelfBackdrop`）や
/// 「続きを読む」段のような経路を**一つ見落とせばそのまま漏れる**。読む先を切り替える作りなら、
/// 見落としが原理的に起こらない（読んでいないものは表示できない）。
struct ShelfProfile: Identifiable, Codable, Equatable {
    /// 最初からある書棚。**既存のデータはここに入る。**
    ///
    /// この書棚だけは保存先も UserDefaults のキーも従来のまま使う（`ProfileLocation` /
    /// `ProfileDefaults` を参照）。移行のためにファイルを動かさないので、書棚を増やす仕組みを
    /// 入れたことで既存の蔵書が失われる筋が存在しない。
    static let primaryID = UUID(uuidString: "00000000-0000-0000-0000-00000000E9B0")!

    let id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }

    var isPrimary: Bool { id == Self.primaryID }
}

// MARK: - 一覧と「いまどれを見ているか」（純ロジック）

/// 書棚の一覧と、いま見ている書棚。**本の情報は一切持たない**（`profiles.json` に保存する）。
///
/// 壊れた JSON を読んでも書棚が消えたことにならないよう、`normalized(primaryName:)` が
/// 最初からある書棚の存在と選択の妥当性を必ず立て直す。SwiftUI にも Foundation 以外にも
/// 依らないので `swiftc` 単体で検証できる。
struct ProfileIndex: Codable, Equatable {
    var profiles: [ShelfProfile] = []
    var currentID: UUID = ShelfProfile.primaryID

    init(profiles: [ShelfProfile] = [], currentID: UUID = ShelfProfile.primaryID) {
        self.profiles = profiles
        self.currentID = currentID
    }

    static func initial(primaryName: String) -> ProfileIndex {
        ProfileIndex(
            profiles: [ShelfProfile(id: ShelfProfile.primaryID, name: primaryName)],
            currentID: ShelfProfile.primaryID)
    }

    var current: ShelfProfile? { profiles.first { $0.id == currentID } }

    func profile(_ id: UUID) -> ShelfProfile? { profiles.first { $0.id == id } }

    /// 壊れた・欠けたデータを立て直した姿を返す。
    ///
    /// - 最初からある書棚が無ければ先頭に足す（読み込みに失敗しても既存の蔵書へ戻れる）。
    /// - ID の重複は後から来たほうを捨てる（保存先が同じものを二つ並べない）。
    /// - 名前が空の書棚はメニューで選べなくなるので、既定の名前を入れる。
    /// - いま見ている書棚がもう無ければ、最初からある書棚に戻す。
    func normalized(primaryName: String) -> ProfileIndex {
        var seen: Set<UUID> = []
        var list: [ShelfProfile] = []
        for var p in profiles {
            guard seen.insert(p.id).inserted else { continue }
            if p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                p.name = p.isPrimary ? primaryName : Self.untitledName
            }
            list.append(p)
        }
        if !list.contains(where: \.isPrimary) {
            list.insert(ShelfProfile(id: ShelfProfile.primaryID, name: primaryName), at: 0)
        }
        let current = list.contains { $0.id == currentID } ? currentID : ShelfProfile.primaryID
        return ProfileIndex(profiles: list, currentID: current)
    }

    /// 名前の無い書棚に入れる名前。ローカライズはしない（保存される値であり、表示専用ではないため
    /// 言語を切り替えたときに名前が入れ替わってしまう）。
    static let untitledName = "Shelf"

    /// 書棚を足す。名前が空なら作らない。
    @discardableResult
    mutating func add(name: String) -> ShelfProfile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let p = ShelfProfile(name: trimmed)
        profiles.append(p)
        return p
    }

    @discardableResult
    mutating func rename(_ id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = profiles.firstIndex(where: { $0.id == id })
        else { return false }
        profiles[idx].name = trimmed
        return true
    }

    /// 書棚を消せるか。
    ///
    /// **最初からある書棚と、いま見ている書棚は消せない。** 前者は既存の蔵書の置き場所そのもので、
    /// 後者は消した瞬間に行き先が無くなる（先に切り替えてもらう）。
    func canRemove(_ id: UUID) -> Bool {
        id != ShelfProfile.primaryID && id != currentID && profiles.contains { $0.id == id }
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        guard canRemove(id) else { return false }
        profiles.removeAll { $0.id == id }
        return true
    }
}

// MARK: - 保存先の解決（メインスレッド以外からも引く）

/// いま見ている書棚の保存先。
///
/// `TranslationCache`（actor）からも引くので、`@MainActor` に閉じずロックで守る。
///
/// **最初からある書棚は従来どおり `EpubReaderSpike/` 直下**を使い、増やした書棚だけ
/// `EpubReaderSpike/Profiles/<UUID>/` に置く。既存の `library.json` / `Covers/` /
/// `translation-cache.json` を1バイトも動かさないための決めで、分岐はこの型の中だけに収まる。
final class ProfileLocation: @unchecked Sendable {
    static let shared = ProfileLocation()

    /// アプリの保存の根（`Application Support/EpubReaderSpike`）。
    let root: URL

    private let lock = NSLock()
    private var id = ShelfProfile.primaryID

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EpubReaderSpike", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    var currentID: UUID {
        lock.lock()
        defer { lock.unlock() }
        return id
    }

    /// 見る先を変える。**呼んだあとに保存先を引き直す側（LibraryStore・表紙・翻訳キャッシュ）を
    /// 必ず作り直すこと**（`AppModel.switchProfile` がまとめて面倒を見る）。
    func move(to newID: UUID) {
        lock.lock()
        id = newID
        lock.unlock()
    }

    func directory(for id: UUID) -> URL {
        let dir = id == ShelfProfile.primaryID
            ? root
            : root.appendingPathComponent("Profiles/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var directory: URL { directory(for: currentID) }
    var libraryFileURL: URL { directory.appendingPathComponent("library.json") }
    var translationCacheURL: URL { directory.appendingPathComponent("translation-cache.json") }

    var coversDirectory: URL {
        let dir = directory.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 消した書棚の保存先を `Profiles/Deleted/` へ寄せる（**消さない**）。
    ///
    /// 中身は「どの本を登録したか・どこまで読んだか・どう分類したか」で、EPUB 本体と違って
    /// 作り直せない。取り違えて消したときに戻せるよう、名前を変えて残すだけにする。
    func retire(_ id: UUID) {
        guard id != ShelfProfile.primaryID else { return }
        let fm = FileManager.default
        let src = root.appendingPathComponent("Profiles/\(id.uuidString)", isDirectory: true)
        guard fm.fileExists(atPath: src.path) else { return }
        let graveyard = root.appendingPathComponent("Profiles/Deleted", isDirectory: true)
        try? fm.createDirectory(at: graveyard, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let dest = graveyard.appendingPathComponent("\(id.uuidString)-\(stamp)", isDirectory: true)
        do { try fm.moveItem(at: src, to: dest) }
        catch { NSLog("[Profile] retire failed: %@", String(describing: error)) }
    }
}

// MARK: - 書棚ごとの UserDefaults キー

/// 書棚ごとに分ける設定のキー。
///
/// **最初からある書棚は従来のキーそのまま**（`reader.userCSS` など）で、増やした書棚だけ
/// `キー#<UUID>` にする。既存の設定を移し替えないので、書棚を増やしても手元の読み辞書・
/// 共通CSS はそのまま残る。
///
/// 分けるのは「蔵書に紐づくもの」だけ——読み辞書（登録語がそのまま作品の固有名詞になる）・
/// 全書籍共通CSS・最後に選んでいた棚。読み上げエンジンの接続先やスリープタイマーのような
/// 「機械の設定」は分けない（書棚を切り替えるたびに繋ぎ直すことになるため）。
enum ProfileDefaults {
    /// 書棚ごとに分ける設定。**増やしたらここへ足すこと**——書棚を消したときに落とすキーの
    /// 一覧もここから引くので、片方だけ足すと消し残る。
    enum Scoped: String, CaseIterable {
        /// 全書籍共通CSS。手元の蔵書に合わせた調整が別の書棚に出ないように。
        case userCSS = "reader.userCSS"
        /// 読み辞書。登録語はそのまま作品の固有名詞になる。
        case readingDictionary = "tts.readingDictionary.v2"
        /// 旧「読み替えルール」（読み辞書へ自動移行する元）。
        case legacyReadingRules = "tts.readingRules.v1"
        /// 最後に選んでいた棚。別の書棚に無い分類を指してしまうため。
        case shelfScope = "library.shelfScope.v1"
    }

    static func key(_ scoped: Scoped) -> String {
        let id = ProfileLocation.shared.currentID
        return id == ShelfProfile.primaryID
            ? scoped.rawValue
            : "\(scoped.rawValue)#\(id.uuidString)"
    }

    /// 消した書棚の設定を落とす。最初からある書棚のキーは**絶対に触らない**
    ///（そちらは接尾辞が付いておらず、手元の読み辞書と共通CSS そのもの）。
    static func removeAll(for id: UUID) {
        guard id != ShelfProfile.primaryID else { return }
        for scoped in Scoped.allCases {
            UserDefaults.standard.removeObject(forKey: "\(scoped.rawValue)#\(id.uuidString)")
        }
    }
}

// MARK: - profiles.json の読み書き

/// 書棚の一覧の保存。蔵書とは別のファイル（`profiles.json`）に置く。
///
/// 書棚の一覧を蔵書と同じファイルへ入れると、いま見ていない書棚の情報を読むために
/// そちらの蔵書ごと読むことになる。一覧だけは常に全部要るので分けてある。
@MainActor
final class ProfileStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? ProfileLocation.shared.root.appendingPathComponent("profiles.json")
    }

    /// 読み込む。ファイルが無い／壊れているときは、最初からある書棚1つだけの姿を返す
    ///（**その場では書かない**。書けなかったときに空の一覧を焼き付けないため）。
    func load(primaryName: String) -> ProfileIndex {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(ProfileIndex.self, from: data)
        else { return .initial(primaryName: primaryName) }
        return decoded.normalized(primaryName: primaryName)
    }

    func save(_ index: ProfileIndex) {
        do {
            let data = try JSONEncoder().encode(index)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[Profile] save failed: %@", String(describing: error))
        }
    }
}
