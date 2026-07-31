import Foundation

// MARK: - 書棚に永続化するもの一式

/// 書棚まるごとの姿。本の一覧と分類（コレクション）を1ファイルに収める。
struct LibrarySnapshot: Codable, Equatable {
    var books: [BookEntry] = []
    var collections: [ShelfCollection] = []

    // 旧データ（本の配列だけ）から移してきたときのために、collections は欠けていてもよい。
    init(books: [BookEntry] = [], collections: [ShelfCollection] = []) {
        self.books = books
        self.collections = collections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        books = try c.decodeIfPresent([BookEntry].self, forKey: .books) ?? []
        collections = try c.decodeIfPresent([ShelfCollection].self, forKey: .collections) ?? []
    }
}

// MARK: - 保存先と書き込みのまとめ役

/// 書棚の保存を受け持つ。
///
/// **なぜ作り直したか。** 以前は `UserDefaults` の1キーに全冊を JSON blob で置き、
/// 1冊ぶんの変更のたびに全冊をエンコードして書き直していた。実測（1368冊・882KB）で
/// エンコード 8.1ms ＋ UserDefaults への書き込みまで含めて **12.5ms**。これが
///
/// - **ページを送るたび**（`relocate` → `persistProgress` → `saveProgressCFI`）
/// - **1冊登録するたび**（フォルダ一括登録なら冊数ぶん）
///
/// に走るので、蔵書が増えるほど読書も登録も詰まっていく。冊数に比例して重くなる作業を
/// 「1回の変更」ごとにやっていたのが原因で、冊数そのものが限界だったわけではない。
///
/// 直し方は二つ。
///
/// 1. **置き場所を専用ファイルにする** — Application Support の `library.json`。
///    cfprefsd が抱える plist を蔵書で太らせない（他の設定の読み書きまで巻き添えにしない）。
/// 2. **書き込みをまとめる** — 保存の要求は最新の姿を控えるだけにして、少し待ってから
///    1回だけ書く。エンコードとファイル書き出しは直列キューで行い、メインスレッドを止めない。
///
/// 落とさないための約束: 溜めたぶんは**アプリ終了・バックグラウンド移行・本を閉じたとき**に
/// `flush()` で必ず書き切る。`flush()` は書き終わるまで待つ（終了処理の途中で消えないため）。
@MainActor
final class LibraryStore {
    /// 旧保存先。初回だけ読んで新しいファイルへ移す。
    static let legacyBooksKey = "library.books.v1"

    private let fileURL: URL
    /// まだ書いていない最新の姿。`flush()` までここに留まる。
    private var pending: LibrarySnapshot?
    private var flushTask: Task<Void, Never>?
    /// 書き込みは1本の直列キューで行う（メインを止めず、書く順番も入れ替わらない）。
    private let ioQueue = DispatchQueue(
        label: "com.veltrea.EpubReaderSpike.library-io", qos: .utility)

    /// 変更を溜める時間。ページ送りのたびの位置保存をこの窓でまとめて1回にする。
    private let coalescingDelay: UInt64 = 700_000_000  // 0.7 秒

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    /// いま見ている書棚の `library.json`。最初からある書棚は従来の場所
    ///（`EpubReaderSpike/library.json`）のまま——詳しくは `ProfileLocation` を参照。
    private static func defaultFileURL() -> URL {
        ProfileLocation.shared.libraryFileURL
    }

    // MARK: 読み込み（初回は旧データから移行）

    func load() -> LibrarySnapshot {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) {
            return decoded
        }
        return migrateFromUserDefaults()
    }

    /// 旧保存先（UserDefaults の1キー）から移す。
    /// **書き出しが成功したことを確かめてから**旧キーを消す（途中で失敗しても蔵書が消えないため）。
    ///
    /// 移せるのは最初からある書棚だけ。増やした書棚（まだ空）でこれを通すと、旧キーの蔵書が
    /// そちらへ複製されてしまう——スクリーンショット用に空の書棚を作った意味がなくなる。
    private func migrateFromUserDefaults() -> LibrarySnapshot {
        guard ProfileLocation.shared.currentID == ShelfProfile.primaryID else {
            return LibrarySnapshot()
        }
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.legacyBooksKey),
              let books = try? JSONDecoder().decode([BookEntry].self, from: data)
        else { return LibrarySnapshot() }

        let snapshot = LibrarySnapshot(books: books)
        if writeSynchronously(snapshot) {
            defaults.removeObject(forKey: Self.legacyBooksKey)
            dlog("[Library] migrated \(books.count) books to \(fileURL.lastPathComponent)")
        } else {
            dlog("[Library] migration write failed; keeping legacy defaults")
        }
        return snapshot
    }

    // MARK: 保存

    /// 保存を予約する。連続して呼ばれたぶんは最後の1回にまとまる。
    func scheduleSave(_ snapshot: LibrarySnapshot) {
        pending = snapshot
        guard flushTask == nil else { return }   // すでに予約済み。中身だけ差し替わる。
        flushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: coalescingDelay)
            flushTask = nil
            guard !Task.isCancelled else { return }
            writeInBackground()
        }
    }

    /// 溜めたぶんを**書き終わるまで待って**書き出す。終了処理・バックグラウンド移行で使う。
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard let snapshot = pending else { return }
        pending = nil
        _ = writeSynchronously(snapshot)
    }

    private func writeInBackground() {
        guard let snapshot = pending else { return }
        pending = nil
        let url = fileURL
        ioQueue.async { Self.write(snapshot, to: url) }
    }

    @discardableResult
    private func writeSynchronously(_ snapshot: LibrarySnapshot) -> Bool {
        var ok = false
        let url = fileURL
        ioQueue.sync { ok = Self.write(snapshot, to: url) }
        return ok
    }

    @discardableResult
    private nonisolated static func write(_ snapshot: LibrarySnapshot, to url: URL) -> Bool {
        do {
            let data = try JSONEncoder().encode(snapshot)
            // アトミック書き込み。途中で落ちても壊れた JSON が残らない。
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("[Library] save failed: %@", String(describing: error))
            return false
        }
    }
}
