import SwiftUI
import UIKit

// MARK: - 書棚の1冊

/// 書棚に並ぶ1冊分の永続化データ。
/// サンドボックス無効なので生ファイルパスをそのまま保存して再オープンできる。
struct BookEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var path: String
    var title: String
    var addedAt: Date
    var lastOpenedAt: Date
    /// 最後に読んでいた位置（foliate の EPUB CFI 文字列。旧 Readium 時代は Locator JSON だった）。
    var locatorJSON: String?
    /// カバー画像のファイル名（Application Support/Covers 内）。
    var coverFileName: String?
    /// しおり（旧データ互換のため optional）。
    var bookmarks: [Bookmark]?
    /// この本だけに適用するカスタムCSS（旧データ互換のため optional）。
    /// 全書籍共通CSS(reader.userCSS)の後に注入され、共通CSSを上書きできる。
    var customCSS: String?
    /// この本だけの書字方向（nil = 全書籍の既定に従う）。WritingMode の rawValue。
    var writingMode: String?
    /// この本だけの綴じ方向（nil = 全書籍の既定に従う）。BindingDirection の rawValue。
    var bindingDirection: String?
    /// この本だけの画像ページの見開き（nil = 全書籍の既定に従う）。SpreadMode の rawValue。
    var imageSpread: String?
    /// この本だけの本文の見開き（nil = 全書籍の既定に従う）。SpreadMode の rawValue。
    var textSpread: String?
    /// この本だけの強制アスペクト比（nil = 強制しない）。"844:1200" 形式。
    /// 本によって正しい値が違うので、これだけは全書籍の既定を持たない。
    var forcedAspect: String?
    /// 作者・出版社（EPUB メタデータから抽出。旧データ互換のため optional）。
    var author: String?
    var publisher: String?
    /// 作者の読み（opf:file-as / Contributor.sortAs）。五十音インデックスの並び・頭文字判定に使う。
    var authorSort: String?
    /// 作者の読みの手動オーバーライド（かな）。file-as が漢字/未取得のときにユーザーが設定。最優先。
    var authorYomi: String?
    /// 読了率 0...1（最後に位置を保存したときの totalProgression。旧データ互換のため optional）。
    var progress: Double?

    var fileURL: URL { URL(fileURLWithPath: path) }
    /// ソート・フィルタ用の表示値（未取得は空文字扱い）。
    var authorText: String { author ?? "" }
    var publisherText: String { publisher ?? "" }

    /// 索引に使える「読み」。優先順: 手動読み → かなの file-as →（将来: 名前辞書）→ nil。
    var resolvedAuthorReading: String? {
        if let y = authorYomi?.trimmingCharacters(in: .whitespacesAndNewlines), !y.isEmpty { return y }
        if let sa = authorSort?.trimmingCharacters(in: .whitespacesAndNewlines), !sa.isEmpty,
           BookEntry.isKanaString(sa) { return sa }
        return nil
    }
    /// インデックス用の並び替えキー（読みが取れれば読み、無ければ表示名）。
    var authorSortKey: String { resolvedAuthorReading ?? authorText }

    /// 文字列がすべて かな（＋空白・長音・中黒）かを判定。file-as がかな読みかの判定に使う。
    static func isKanaString(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return t.unicodeScalars.allSatisfy { sc in
            let v = sc.value
            return (0x3041...0x3096).contains(v)   // ひらがな
                || (0x30A1...0x30FA).contains(v)   // カタカナ
                || v == 0x30FC                     // ー 長音
                || v == 0x30FB                     // ・ 中黒
                || v == 0x3000 || v == 0x20        // 全角/半角スペース
        }
    }
    /// 表示用の読了率（%）。まだ読んでいない本は nil。ごく僅かでも読んだら 1% と出す
    ///（0% と表示されると「読んでいない」と誤読されるため）。
    var progressPercent: Int? {
        guard let p = progress, p > 0 else { return nil }
        return max(1, min(100, Int((p * 100).rounded())))
    }
    /// 一度でも開いて位置が残っている本か（＝「続きを読む」対象）。
    var hasStartedReading: Bool { locatorJSON != nil }
    var fileExists: Bool { FileManager.default.fileExists(atPath: path) }
    var bookmarkList: [Bookmark] { bookmarks ?? [] }
}

/// しおり1件。
struct Bookmark: Identifiable, Codable, Equatable {
    let id: UUID
    var locatorJSON: String
    var progression: Double
    var excerpt: String
    var createdAt: Date
}

/// 全書籍共通の読書設定（フォント・行間・配色・言語）。Kindle 同様アプリ全体に適用。
struct ReadingSettings: Codable, Equatable {
    var fontSize: Double = 1.0            // 1.0 = 100%
    var lineHeight: Double = 1.8         // 本文の行間（1.0〜2.4 目安）
    var theme: String = "light"          // "light" / "sepia" / "dark" / "auto"
    var language: String = "auto"        // UI言語 "auto" / "ja" / "en"
    /// 全書籍の既定の書字方向。本ごとの指定（BookEntry.writingMode）が優先される。
    var writingMode: String = WritingMode.auto.rawValue
    /// 表示モード。RenderMode を参照。
    var renderMode: String = RenderMode.friendly.rawValue
    /// 全書籍の既定の綴じ方向。本ごとの指定（BookEntry.bindingDirection）が優先される。
    var bindingDirection: String = BindingDirection.auto.rawValue
    /// 全書籍の既定の見開き（画像ページ／本文）。本ごとの指定が優先される。
    var imageSpread: String = SpreadMode.auto.rawValue
    var textSpread: String = SpreadMode.auto.rawValue
    /// 開発時の確認用の操作（測定グリッドなど）をツールバーに出すか。
    var debugMode: Bool = false

    /// 文字サイズ・行間の可動域と刻み（メニューの増減とリセットで使う）。
    /// 文字サイズは設定シートのスライダー（0.6〜2.0）より広く、これまでの
    /// ツールバー操作で許していた範囲をそのまま保つ。
    static let fontSizeRange: ClosedRange<Double> = 0.5 ... 3.0
    static let lineHeightRange: ClosedRange<Double> = 1.0 ... 2.4
    static let fontSizeStep = 0.1
    static let lineHeightStep = 0.1

    init(fontSize: Double = 1.0, lineHeight: Double = 1.8,
         theme: String = "light", language: String = "auto",
         writingMode: String = WritingMode.auto.rawValue,
         renderMode: String = RenderMode.friendly.rawValue,
         bindingDirection: String = BindingDirection.auto.rawValue,
         imageSpread: String = SpreadMode.auto.rawValue,
         textSpread: String = SpreadMode.auto.rawValue,
         debugMode: Bool = false) {
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.theme = theme
        self.language = language
        self.writingMode = writingMode
        self.renderMode = renderMode
        self.bindingDirection = bindingDirection
        self.imageSpread = imageSpread
        self.textSpread = textSpread
        self.debugMode = debugMode
    }

    // 旧バージョン（fontSize/theme のみ）の保存データも欠損キーを既定で補って読めるようにする。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 1.0
        lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.8
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "light"
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "auto"
        writingMode = try c.decodeIfPresent(String.self, forKey: .writingMode)
            ?? WritingMode.auto.rawValue
        renderMode = try c.decodeIfPresent(String.self, forKey: .renderMode)
            ?? RenderMode.friendly.rawValue
        bindingDirection = try c.decodeIfPresent(String.self, forKey: .bindingDirection)
            ?? BindingDirection.auto.rawValue
        imageSpread = try c.decodeIfPresent(String.self, forKey: .imageSpread)
            ?? SpreadMode.auto.rawValue
        textSpread = try c.decodeIfPresent(String.self, forKey: .textSpread)
            ?? SpreadMode.auto.rawValue
        debugMode = try c.decodeIfPresent(Bool.self, forKey: .debugMode) ?? false
    }
}

extension Comparable {
    /// 値域へ丸める。文字サイズ・行間の増減で使う。
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// 表示モード。既定では EPUB 側の指定の粗さを吸収して「期待どおりの見え方」に寄せる。
/// EPUB に書かれている指定そのものを確かめたいときは raw にする。
enum RenderMode: String, CaseIterable, Identifiable {
    case friendly    // 画像を面いっぱいに、画像だけのページは見開きに組む（既定）
    case raw         // EPUB の指定どおりにエンジンが描いたまま

    var id: String { rawValue }

    var label: String {
        switch self {
        case .friendly: return String(localized: "読みやすさ優先")
        case .raw:      return String(localized: "EPUB のまま")
        }
    }
}

/// 本文の書字方向。EPUB の指定は当てにならない（縦書きのつもりの本が CSS に
/// writing-mode を持たず、OPF の primary-writing-mode にしか書いていない等が普通にある）ので、
/// 読み手が本ごとに上書きできるようにする。
enum WritingMode: String, CaseIterable, Identifiable {
    case auto        // 本の指定に従う（OPF の primary-writing-mode まで見て補う）
    case vertical    // 強制的に縦書き
    case horizontal  // 強制的に横書き

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return String(localized: "自動")
        case .vertical: return String(localized: "縦書き")
        case .horizontal: return String(localized: "横書き")
        }
    }

    var symbolName: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .vertical: return "text.append"
        case .horizontal: return "text.alignleft"
        }
    }
}

/// 綴じ方向（ページを送っていく向き）。
///
/// 自動判定には二つの穴があり、どちらも本のデータだけでは埋まらない。
/// ひとつは spine の page-progression-direction が横組みへ変換された本にも rtl のまま
/// 残っていること。もうひとつは漫画・写真集のように本文が画像だけの本で、
/// 組まれた文字が無いので向きを実測しようがないこと。読み手が本ごとに決められるようにする。
enum BindingDirection: String, CaseIterable, Identifiable {
    case auto    // 本の指定と本文の実測から決める
    case rtl     // 右綴じ（日本の漫画・縦書きの本）
    case ltr     // 左綴じ（洋書・横組みの本）

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return String(localized: "自動")
        case .rtl:  return String(localized: "右綴じ")
        case .ltr:  return String(localized: "左綴じ")
        }
    }

    /// ツールバーのアイコン。矢印は「ページが進んでいく向き」。
    var symbolName: String {
        switch self {
        case .auto: return "arrow.left.arrow.right"
        case .rtl:  return "arrow.left"
        case .ltr:  return "arrow.right"
        }
    }

    /// この順に押して巡回する（ワンタッチ切替用）。
    var next: BindingDirection {
        switch self {
        case .auto: return .rtl
        case .rtl:  return .ltr
        case .ltr:  return .auto
        }
    }
}

/// 見開き（2ページを左右に並べる）の扱い。画像ページと本文とで別々に持つ。
///
/// auto は本の作りに任せる——画像側は「画像だけの面が続く区間を2枚ずつ組む」、
/// 本文側は「エンジンの通常のページ組み（1画面1ページ）」。本の作りが粗くて
/// 期待どおりに組まれないことがあるので、読み手が本ごとに倒せるようにする。
enum SpreadMode: String, CaseIterable, Identifiable {
    case auto     // 本の作りに任せる
    case always   // 常に2ページ並べる
    case never    // 常に1ページ

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:   return String(localized: "自動")
        case .always: return String(localized: "常に見開き")
        case .never:  return String(localized: "常に単ページ")
        }
    }

    /// ツールバーのアイコン。画像ページ用と本文用で絵柄を変える（隣に並ぶので、
    /// 同じ絵だとどちらのボタンを押しているのか分からなくなる）。
    func symbolName(forImages: Bool) -> String {
        switch (self, forImages) {
        case (.auto, true):    return "photo.on.rectangle"
        case (.always, true):  return "photo.on.rectangle.angled"
        case (.never, true):   return "photo"
        case (.auto, false):   return "doc.on.doc"
        case (.always, false): return "doc.on.doc.fill"
        case (.never, false):  return "doc.plaintext"
        }
    }

    /// この順に押して巡回する（ワンタッチ切替用）。
    var next: SpreadMode {
        switch self {
        case .auto:   return .always
        case .always: return .never
        case .never:  return .auto
        }
    }
}

/// 画像を強制的に当てはめる縦横比（幅:高さ）。
///
/// 用途は「元データの比率がページごとに揃っていない本を揃える」こと。収めるのではなく
/// **引き伸ばす**（object-fit: fill）ので、比率が違う面は歪む——それを承知で揃えたい
/// ときのための機能である。既定値は本から拾う（EpubProbe/OPF の viewport や先頭画像の実寸）。
struct AspectRatio: Codable, Equatable {
    var width: Double
    var height: Double

    var isValid: Bool { width > 0 && height > 0 }
    var value: Double { height > 0 ? width / height : 0 }

    /// "844:1200" 形式。BookEntry へはこの形で保存する。
    var storageString: String { "\(Int(width.rounded())):\(Int(height.rounded()))" }
    var label: String { "\(Int(width.rounded())) : \(Int(height.rounded()))" }

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// "844:1200" / "3:4" / "1.5" を読む。読めなければ nil。
    init?(storageString raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1)
        if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 {
            self.init(width: w, height: h)
        } else if let v = Double(raw), v > 0 {
            // 比の値だけが入っている形（"1.5"）も受ける。
            self.init(width: v, height: 1)
        } else {
            return nil
        }
    }

    /// メニューに並べる定番の判型（縦長）。
    static let presets: [AspectRatio] = [
        AspectRatio(width: 2, height: 3),      // 文庫・新書に近い
        AspectRatio(width: 3, height: 4),      // 漫画の単行本に多い
        AspectRatio(width: 210, height: 297),  // A 判
        AspectRatio(width: 182, height: 257),  // B5
        AspectRatio(width: 1, height: 1),      // 正方形
    ]
}

// MARK: - リーダーCSSの設定キー（foliate 版）
// 表示スタイルの注入は foliate の renderer.setStyles（bridge.js）が行う。
// ここは「全書籍共通CSS」「解決済みCSS」の保存キーと結合ロジックだけを持つ。

enum EpubOpener {
    /// 全書籍共通CSSの UserDefaults キー。
    static let userCSSKey = "reader.userCSS"
    /// 現在開いている本の「解決済みCSS（共通＋本別）」の UserDefaults キー。
    /// ReaderModel が本を開くたび／編集のたびにここへ書き込み、bridge の setStyle が反映する。
    static let activeCSSKey = "reader.activeCSS"

    /// 共通CSS＋本別CSSを結合して返す（本別を後に置くので共通を上書きできる）。
    static func resolvedCSS(global: String, perBook: String?) -> String {
        [global, perBook ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

// MARK: - アプリ全体モデル（書棚 + 現在開いている本）

@MainActor
final class AppModel: ObservableObject {
    @Published var books: [BookEntry] = []
    @Published var openedBook: BookEntry?
    /// メニュー「ファイル > 開く…」から fileImporter を出すためのフラグ。
    @Published var requestOpenPanel = false
    /// 設定シート（オーディオ＋表示）の表示。書棚・リーダーのどちらからでも、
    /// またメニュー「環境設定… ⌘,」からも開くので、画面ではなくアプリ側で持つ。
    @Published var showSettings = false
    /// 本文検索シートの表示。ツールバーの虫めがねと、メニュー「編集 > 検索…（⌘F）」の
    /// どちらからも開くので、リーダー画面ではなくアプリ側で持つ。
    @Published var showSearch = false
    /// 全書籍共通の読書設定（フォント・配色）。
    @Published var settings = ReadingSettings()
    /// いま開いているリーダー。メニューバーの「表示」からは画面階層をたどれないので、
    /// アプリ側で現在のリーダーを持っておき、メニューの操作先にする
    ///（ReaderModel 側の model 参照は weak なので循環しない）。
    @Published var activeReader: ReaderModel?

    private let defaultsKey = "library.books.v1"
    private let settingsKey = "library.settings.v1"

    init() {
        load()
        loadSettings()
    }

    // MARK: 永続化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([BookEntry].self, from: data)
        else { return }
        books = decoded.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(books) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(ReadingSettings.self, from: data)
        else { return }
        settings = decoded
    }

    func updateSettings(_ newValue: ReadingSettings) {
        settings = newValue
        if let data = try? JSONEncoder().encode(newValue) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    /// 表示設定の一部だけを書き換える（本を開いていないときのメニュー操作用）。
    func editSettings(_ transform: (inout ReadingSettings) -> Void) {
        var copy = settings
        transform(&copy)
        guard copy != settings else { return }
        updateSettings(copy)
    }

    // MARK: しおり

    func addBookmark(bookID: UUID, bookmark: Bookmark) {
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else { return }
        var list = books[idx].bookmarks ?? []
        // 同じ位置の重複は避ける。
        guard !list.contains(where: { $0.locatorJSON == bookmark.locatorJSON }) else { return }
        list.append(bookmark)
        list.sort { $0.progression < $1.progression }
        books[idx].bookmarks = list
        save()
    }

    func removeBookmark(bookID: UUID, bookmarkID: UUID) {
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[idx].bookmarks?.removeAll { $0.id == bookmarkID }
        save()
    }

    func bookmarks(for bookID: UUID) -> [Bookmark] {
        books.first(where: { $0.id == bookID })?.bookmarkList ?? []
    }

    // MARK: メタデータのバックフィル（旧データに作者・出版社が無い場合）

    private var didBackfill = false
    /// 作者/出版社が未取得の本について、EPUB を開いて埋める（既存データを壊さず追記）。
    func backfillMetadataIfNeeded() {
        guard !didBackfill else { return }
        didBackfill = true
        // 作者/出版社/読み(authorSort)/表紙のいずれかが未取得の本を対象にする。
        // （表紙は probe が失敗した本で丸ごと欠けるため、メタと同じ経路で埋め直す。）
        let targets = books.filter { b in
            guard b.fileExists else { return false }
            let missingMeta = b.author == nil && b.publisher == nil
            let missingSort = b.author != nil && b.authorSort == nil
            let missingCover = b.coverFileName == nil
            return missingMeta || missingSort || missingCover
        }
        guard !targets.isEmpty else { return }
        Task {
            for book in targets {
                guard let meta = await EpubProbe.probe(url: book.fileURL) else { continue }
                guard let idx = books.firstIndex(where: { $0.id == book.id }) else { continue }
                if let a = meta.author { books[idx].author = a }
                if let p = meta.publisher { books[idx].publisher = p }
                if let sa = meta.authorSort { books[idx].authorSort = sa }
                // タイトルもファイル名フォールバックのままなら書き戻す。
                if let t = meta.title, !t.isEmpty,
                   books[idx].title == book.fileURL.deletingPathExtension().lastPathComponent {
                    books[idx].title = t
                }
                if books[idx].coverFileName == nil, let png = meta.coverPNG {
                    let name = "\(book.id).png"
                    try? png.write(to: coversDir.appendingPathComponent(name))
                    books[idx].coverFileName = name
                }
            }
            save()
        }
    }

    // MARK: 本別カスタムCSS

    func bookCSS(for bookID: UUID) -> String {
        books.first(where: { $0.id == bookID })?.customCSS ?? ""
    }

    func setBookCSS(bookID: UUID, css: String) {
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else { return }
        let trimmed = css.trimmingCharacters(in: .whitespacesAndNewlines)
        books[idx].customCSS = trimmed.isEmpty ? nil : css
        save()
    }

    // MARK: 本別の書字方向

    /// この本に適用する書字方向。本ごとの指定が無ければ全書籍の既定を使う。
    func writingMode(for bookID: UUID?) -> WritingMode {
        if let id = bookID,
           let raw = books.first(where: { $0.id == id })?.writingMode,
           let m = WritingMode(rawValue: raw) { return m }
        return WritingMode(rawValue: settings.writingMode) ?? .auto
    }

    /// 本ごとの書字方向を記憶する。既定と同じ値なら本別の指定は持たない
    ///（あとで既定を変えたときに追従させるため）。
    func setWritingMode(bookID: UUID, mode: WritingMode) {
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[idx].writingMode = (mode.rawValue == settings.writingMode) ? nil : mode.rawValue
        save()
    }

    // MARK: 本別の表示の強制（綴じ方向・見開き・アスペクト比）
    //
    // どれも「本のデータからは正しく決められないので読み手が決める」ための上書きで、
    // 本ごとに覚える。書字方向と同じく、既定と同じ値なら本別の指定は持たない
    //（あとで既定を変えたときに追従させるため）。

    func bindingDirection(for bookID: UUID?) -> BindingDirection {
        if let id = bookID,
           let raw = books.first(where: { $0.id == id })?.bindingDirection,
           let d = BindingDirection(rawValue: raw) { return d }
        return BindingDirection(rawValue: settings.bindingDirection) ?? .auto
    }

    func setBindingDirection(bookID: UUID, direction: BindingDirection) {
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[idx].bindingDirection =
            (direction.rawValue == settings.bindingDirection) ? nil : direction.rawValue
        save()
    }

    func imageSpread(for bookID: UUID?) -> SpreadMode {
        if let id = bookID,
           let raw = books.first(where: { $0.id == id })?.imageSpread,
           let m = SpreadMode(rawValue: raw) { return m }
        return SpreadMode(rawValue: settings.imageSpread) ?? .auto
    }

    func setImageSpread(bookID: UUID, mode: SpreadMode) {
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[idx].imageSpread = (mode.rawValue == settings.imageSpread) ? nil : mode.rawValue
        save()
    }

    func textSpread(for bookID: UUID?) -> SpreadMode {
        if let id = bookID,
           let raw = books.first(where: { $0.id == id })?.textSpread,
           let m = SpreadMode(rawValue: raw) { return m }
        return SpreadMode(rawValue: settings.textSpread) ?? .auto
    }

    func setTextSpread(bookID: UUID, mode: SpreadMode) {
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[idx].textSpread = (mode.rawValue == settings.textSpread) ? nil : mode.rawValue
        save()
    }

    /// 強制アスペクト比。本ごとにしか持たない（正しい値が本によって違うため）。
    func forcedAspect(for bookID: UUID?) -> AspectRatio? {
        guard let id = bookID else { return nil }
        return AspectRatio(storageString: books.first(where: { $0.id == id })?.forcedAspect)
    }

    func setForcedAspect(bookID: UUID, aspect: AspectRatio?) {
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[idx].forcedAspect = (aspect?.isValid == true) ? aspect?.storageString : nil
        save()
    }

    // MARK: 作者読みの手動オーバーライド

    func setAuthorYomi(bookID: UUID, yomi: String) {
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else { return }
        let trimmed = yomi.trimmingCharacters(in: .whitespacesAndNewlines)
        books[idx].authorYomi = trimmed.isEmpty ? nil : trimmed
        save()
    }

    // MARK: カバー保存場所

    private var coversDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EpubReaderSpike/Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 表示済みカバーのメモリキャッシュ。ディスクの PNG は 400x600 あるが、書棚のセルは
    /// 150x220pt（Retina で 300x440px）でしか見えない。SwiftUI は body 評価のたびに
    /// coverImage を呼ぶので、素の UIImage(contentsOfFile:) だと絞り込みや並び替えのたびに
    /// 全冊分をディスクから読み直して丸ごとデコードすることになる。
    private let coverCache = NSCache<NSString, UIImage>()

    /// セル表示に必要な最大辺（px）。これ以上大きくデコードしても画面では見えない。
    private static let coverThumbnailPixels = 460

    func coverImage(for book: BookEntry) -> UIImage? {
        guard let name = book.coverFileName else { return nil }
        let key = name as NSString
        if let cached = coverCache.object(forKey: key) { return cached }
        let url = coversDir.appendingPathComponent(name)
        guard let image = Self.downsampledImage(at: url, maxPixels: Self.coverThumbnailPixels)
        else { return nil }
        // コストはおおよそのピクセル数。総量が増えたら OS が古いものから捨てる。
        coverCache.setObject(image, forKey: key,
                             cost: Int(image.size.width * image.size.height))
        return image
    }

    /// ImageIO でサムネイルを直接生成する（フル解像度に展開してから縮小しない）。
    private static func downsampledImage(at url: URL, maxPixels: Int) -> UIImage? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    /// カバーを差し替え/削除したときにキャッシュを捨てる。
    private func invalidateCoverCache(_ name: String?) {
        guard let name else { return }
        coverCache.removeObject(forKey: name as NSString)
    }

    // MARK: 本を開く

    func open(url: URL) {
        Task { await register(url: url, thenOpen: true) }
    }

    /// 同梱サンプルを初回だけ書棚に登録（開発時にすぐ試せるように）。
    /// 縦書きサンプルに加え、画像位置・余白の測定用メジャー本もシードする。
    func seedSampleIfNeeded() {
        let seededKey = "library.seeded.v2"
        guard books.isEmpty, !UserDefaults.standard.bool(forKey: seededKey) else { return }
        UserDefaults.standard.set(true, forKey: seededKey)
        let names = ["sample-vertical", "ruler-measure"]
        Task {
            for name in names {
                if let url = Bundle.main.url(forResource: name, withExtension: "epub") {
                    await register(url: url, thenOpen: false)
                }
            }
        }
    }

    private func register(url: URL, thenOpen: Bool) async {
        // ドロップ/ピッカー由来のURLは念のためアクセス開始（sandbox無効でも無害）。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // 既存の本ならメタ更新して開くだけ。
        if let existing = books.first(where: { $0.path == url.path }) {
            var e = existing
            e.lastOpenedAt = Date()
            replace(e)
            if thenOpen { openedBook = e }
            return
        }

        // 新規: タイトル・作者・出版社・カバーを取得（foliate のオフスクリーンパーサ）。
        var title = url.deletingPathExtension().lastPathComponent
        var author: String? = nil
        var publisher: String? = nil
        var authorSort: String? = nil
        var coverName: String? = nil
        let id = UUID()
        if let meta = await EpubProbe.probe(url: url) {
            if let t = meta.title, !t.isEmpty { title = t }
            author = meta.author
            authorSort = meta.authorSort
            publisher = meta.publisher
            if let png = meta.coverPNG {
                let name = "\(id).png"
                try? png.write(to: coversDir.appendingPathComponent(name))
                coverName = name
            }
        }

        let entry = BookEntry(
            id: id, path: url.path, title: title,
            addedAt: Date(), lastOpenedAt: Date(),
            locatorJSON: nil, coverFileName: coverName,
            author: author, publisher: publisher, authorSort: authorSort
        )
        books.insert(entry, at: 0)
        save()
        if thenOpen { openedBook = entry }
    }

    // MARK: 読書位置の記憶

    /// foliate-js 版の位置保存。locatorJSON 欄に CFI を格納する（新方式）。
    func saveProgressCFI(bookID: UUID, cfi: String, fraction: Double) {
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[idx].locatorJSON = cfi
        books[idx].lastOpenedAt = Date()
        // 書棚の「続きを読む」段とカバーのバッジに出す読了率。
        if fraction.isFinite { books[idx].progress = min(max(fraction, 0), 1) }
        save()
    }

    // MARK: 書棚操作

    func closeBook() {
        openedBook = nil
        books.sort { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    func remove(_ book: BookEntry) {
        if let name = book.coverFileName {
            try? FileManager.default.removeItem(at: coversDir.appendingPathComponent(name))
            invalidateCoverCache(name)
        }
        books.removeAll { $0.id == book.id }
        save()
    }

    private func replace(_ book: BookEntry) {
        guard let idx = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[idx] = book
        save()
    }
}
