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
    /// お気に入り（旧データ互換のため optional。nil = 付けていない）。
    var isFavorite: Bool?
    /// 入っている分類の ID。1冊が複数の分類に入れる（作者別と叢書別の両方に置く、など）。
    var collectionIDs: [UUID]?
    /// 一度でも EPUB を開いてメタデータを調べたか。
    ///
    /// 作者の読み(file-as)も表紙も**持っていないのが正しい本**がある。この印が無いと
    /// 「まだ埋まっていない本」として毎回の起動で調べ直すことになり、蔵書が増えるほど
    /// 起動が重くなる（実データで 91 冊が延々と再調査されていた）。
    var metaProbed: Bool?

    var fileURL: URL { URL(fileURLWithPath: path) }
    var favorite: Bool { isFavorite == true }
    var collectionList: [UUID] { collectionIDs ?? [] }
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
    /// 全書籍共通CSSの UserDefaults キー。**書棚ごとに分ける**（手元の蔵書に合わせた調整が、
    /// 別の書棚を見せているときの CSS 編集シートに出てこないように）。
    static var userCSSKey: String { ProfileDefaults.key(.userCSS) }
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
    /// 書棚の分類（入れ子にできる）。
    @Published var collections: [ShelfCollection] = []
    /// いまサイドバーで選んでいる棚。書棚を離れても覚えておく。
    @Published var shelfScope: ShelfScope = .all
    /// 蔵書の中身が変わるたびに増える番号。
    ///
    /// 書棚の絞り込み・並び替えは冊数に比例して重い（実測 1368 冊でソート 20ms）ので、
    /// SwiftUI の body 評価のたびにやり直すわけにいかない。表示側はこの番号を見て
    /// 「変わったときだけ」作り直す。`books` の配列そのものを比べると 1368 要素の
    /// 突き合わせになるので、番号1個で済ませる。
    @Published private(set) var libraryRevision = 0
    @Published var openedBook: BookEntry?
    /// メニュー「ファイル > 開く…」から fileImporter を出すためのフラグ。
    @Published var requestOpenPanel = false
    /// 「フォルダから追加…」でフォルダだけを選ぶパネルを出すためのフラグ。
    /// 本とフォルダを1枚のパネルで混ぜて選ばせられない（Catalyst のパネルはフォルダを
    /// 「選ぶ対象」ではなく「潜る先」として扱い、フォルダを選んでも『開く』が押せない）ため、
    /// フォルダ用の入口を別に持つ。
    @Published var requestFolderPanel = false
    /// 設定シート（オーディオ＋表示）の表示。書棚・リーダーのどちらからでも、
    /// またメニュー「環境設定… ⌘,」からも開くので、画面ではなくアプリ側で持つ。
    @Published var showSettings = false
    /// 本文検索シートの表示。ツールバーの虫めがねと、メニュー「編集 > 検索…（⌘F）」の
    /// どちらからも開くので、リーダー画面ではなくアプリ側で持つ。
    @Published var showSearch = false
    /// スリープタイマーの「時間を指定…」の入力。リーダー下部の月アイコンからも
    /// メニューバーからも開くので、入力欄の提示は RootView（アプリ側）に置く。
    @Published var showSleepTimerCustom = false
    /// 自動ページ送りの「間隔を指定…」の入力。リーダー下部からもメニューバーからも開くので、
    /// 入力欄の提示は RootView（アプリ側）に置く。
    @Published var showAutoPagerCustom = false
    /// 全書籍共通の読書設定（フォント・配色）。
    @Published var settings = ReadingSettings()
    /// いま開いているリーダー。メニューバーの「表示」からは画面階層をたどれないので、
    /// アプリ側で現在のリーダーを持っておき、メニューの操作先にする
    ///（ReaderModel 側の model 参照は weak なので循環しない）。
    @Published var activeReader: ReaderModel?
    /// 読み上げのスリープタイマー。メニューバー・リーダー下部・満了時の告知が同じ1個を見るので、
    /// 画面ではなくアプリ側で持つ（本を閉じても走り続ける）。
    /// 自身が ObservableObject なので、監視する側は `model.sleepTimer` を直接見ること。
    let sleepTimer = SleepTimer()
    /// 自動ページ送り。送る相手は「いま開いているリーダー」で、書棚へ戻ると自分で止まる。
    /// メニューバー・リーダー下部が同じ1個を見るので、画面ではなくアプリ側で持つ。
    /// 自身が ObservableObject なので、監視する側は `model.autoPager` を直接見ること。
    let autoPager = AutoPager()

    /// 書棚（プロファイル）の一覧。メニューと管理シートが同じ順で出す。
    @Published private(set) var profiles: [ShelfProfile] = []
    /// いま見ている書棚。
    @Published private(set) var currentProfileID = ShelfProfile.primaryID
    /// 書棚の管理シートの表示。書棚・リーダーのどちらからでも、またメニューからも開くので
    /// 画面ではなくアプリ側で持つ。
    @Published var showProfileManager = false

    /// 蔵書の保存先（いま見ている書棚の1ファイル。書き込みはまとめて行う）。
    /// 書棚を切り替えると保存先が変わるので、そのとき作り直す。
    private var store = LibraryStore()
    private let profileStore = ProfileStore()
    private let settingsKey = "library.settings.v1"
    /// 最後に選んでいた棚。**書棚ごとに分ける**（別の書棚に無い分類を指してしまうため）。
    private var scopeKey: String { ProfileDefaults.key(.shelfScope) }

    init() {
        // 蔵書を読む前に「どの書棚を見るか」を決める。LibraryStore も表紙も翻訳キャッシュも
        // ここで決まった場所を見るので、順番を入れ替えてはいけない。
        let index = profileStore.load(primaryName: String(localized: "自分の書棚"))
        ProfileLocation.shared.move(to: index.currentID)
        profiles = index.profiles
        currentProfileID = index.currentID
        store = LibraryStore()
        load()
        loadSettings()
        // 満了時に止める相手は「いま開いているリーダー」。書棚に戻っていれば止める対象はいないが、
        // スリープ／シャットダウンの追加動作はタイマー側でそのまま続く。
        sleepTimer.onExpire = { [weak self] in
            self?.activeReader?.stopSpeaking()
        }
        // 自動ページ送りの相手も「いま開いているリーダー」。本を差し替えても追従させたいので、
        // 参照を渡さず毎回引き直す（相手が居なくなればタイマー側が自分で止まる）。
        autoPager.targetProvider = { [weak self] in self?.activeReader }
    }

    // MARK: 永続化

    private func load() {
        let snapshot = store.load()
        books = snapshot.books.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        collections = snapshot.collections
        if let raw = UserDefaults.standard.string(forKey: scopeKey) {
            shelfScope = ShelfScope(storageString: raw)
        }
        // 保存されていた棚がもう無い（分類を消したあと等）ならすべての本へ戻す。
        if case .collection(let id) = shelfScope,
           !collections.contains(where: { $0.id == id }) {
            shelfScope = .all
        }
        // 蔵書のカバーはセル表示用に縮めて持つが、無制限に溜めると数百冊ぶんで
        // 数百 MB になる。冊数と総量の両方で頭を打たせる。
        coverCache.countLimit = 300
        coverCache.totalCostLimit = 96 * 1024 * 1024   // 96MB（cost はピクセルのバイト数）
    }

    /// 蔵書の保存を予約する（実際の書き出しは 0.7 秒ぶんまとめて1回）。
    ///
    /// 以前の `save()` は呼ぶたびに全冊をエンコードして UserDefaults へ書いていた。
    /// ページ送りと一括登録の両方がこれを1件ごとに呼ぶので、冊数がそのまま体感の重さに
    /// なっていた（実測 1368 冊で 12.5ms/回）。詳しくは `LibraryStore` を参照。
    private func save() {
        libraryRevision &+= 1
        store.scheduleSave(LibrarySnapshot(books: books, collections: collections))
    }

    /// 溜めている変更を書き切る。アプリ終了・バックグラウンド移行・本を閉じたときに呼ぶ。
    func flushPendingSaves() {
        store.flush()
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

    // MARK: お気に入り

    func setFavorite(bookID: UUID, _ on: Bool) {
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[idx].isFavorite = on ? true : nil   // 付けていない本にキーを残さない
        save()
    }

    func toggleFavorite(bookID: UUID) {
        guard let b = books.first(where: { $0.id == bookID }) else { return }
        setFavorite(bookID: bookID, !b.favorite)
    }

    // MARK: 分類（コレクション）
    //
    // 本の側に所属を持たせる（`BookEntry.collectionIDs`）。分類を消しても本のデータは
    // 壊れないし、1冊を複数の分類へ入れられる。

    @discardableResult
    func addCollection(name: String, parent: UUID? = nil) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 親がもう無いなら最上位に作る（消えた分類の下にぶら下げない）。
        let realParent = (parent.flatMap { p in collections.contains { $0.id == p } ? p : nil })
        let c = ShelfCollection(
            name: trimmed, parentID: realParent,
            order: CollectionTree.nextOrder(under: realParent, in: collections))
        collections.append(c)
        save()
        return c.id
    }

    func renameCollection(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[idx].name = trimmed
        save()
    }

    /// 分類を消す。**子の分類は親へ繰り上げる**（階層に穴を空けない）。本は消さない。
    func removeCollection(id: UUID) {
        guard collections.contains(where: { $0.id == id }) else { return }
        collections = CollectionTree.removing(id, from: collections)
        for i in books.indices where books[i].collectionIDs?.contains(id) == true {
            let list = books[i].collectionList.filter { $0 != id }
            books[i].collectionIDs = list.isEmpty ? nil : list
        }
        if case .collection(let selected) = shelfScope, selected == id { setScope(.all) }
        save()
    }

    /// 分類を別の分類の下へ移す。**自分の子孫は親に選べない**（輪になると木がたどれなくなる）。
    func moveCollection(id: UUID, under newParent: UUID?) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        if let p = newParent {
            guard p != id, collections.contains(where: { $0.id == p }),
                  !CollectionTree.isDescendant(p, of: id, in: collections) else { return }
        }
        collections[idx].parentID = newParent
        collections[idx].order = CollectionTree.nextOrder(under: newParent, in: collections)
        save()
    }

    func setMembership(bookID: UUID, collectionID: UUID, member: Bool) {
        setMembership(bookIDs: [bookID], collectionID: collectionID, member: member)
    }

    /// まとめて入れる／外す。1冊ずつ呼ぶと保存の予約もそのぶん立つので、複数はここへ。
    func setMembership(bookIDs: [UUID], collectionID: UUID, member: Bool) {
        guard collections.contains(where: { $0.id == collectionID }) else { return }
        let targets = Set(bookIDs)
        var changed = false
        for i in books.indices where targets.contains(books[i].id) {
            var list = books[i].collectionList
            let has = list.contains(collectionID)
            guard has != member else { continue }
            if member { list.append(collectionID) } else { list.removeAll { $0 == collectionID } }
            books[i].collectionIDs = list.isEmpty ? nil : list
            changed = true
        }
        if changed { save() }
    }

    func setScope(_ scope: ShelfScope) {
        shelfScope = scope
        UserDefaults.standard.set(scope.storageString, forKey: scopeKey)
    }

    /// その棚に出す本。分類は**子孫の分類に入っている本も含む**（階層の上を選べば下も見える）。
    func books(in scope: ShelfScope) -> [BookEntry] {
        switch scope {
        case .all:
            return books
        case .favorites:
            return books.filter(\.favorite)
        case .unfiled:
            return books.filter { $0.collectionList.isEmpty }
        case .collection(let id):
            guard collections.contains(where: { $0.id == id }) else { return [] }
            let ids = CollectionTree.selfAndDescendants(of: id, in: collections)
            return books.filter { !ids.isDisjoint(with: $0.collectionList) }
        }
    }

    /// サイドバーに出す冊数。1冊ずつ棚を数え直すと分類の数だけ全冊を走ることになるので、
    /// **全冊を1回だけ走って**まとめて数える。
    func shelfCounts() -> [ShelfScope: Int] {
        var counts: [ShelfScope: Int] = [.all: books.count, .favorites: 0, .unfiled: 0]
        for c in collections { counts[.collection(c.id)] = 0 }

        // 分類 → 自分と祖先ぜんぶ。親の棚には子の本も出るので、1冊は所属先の祖先すべてで数える。
        let parents = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0.parentID) })
        var chain: [UUID: [UUID]] = [:]
        for c in collections {
            var line: [UUID] = []
            var cur: UUID? = c.id
            var seen: Set<UUID> = []
            while let id = cur, seen.insert(id).inserted {   // 輪になっていても止まる
                line.append(id)
                cur = parents[id] ?? nil
            }
            chain[c.id] = line
        }

        var bucket: Set<UUID> = []
        for b in books {
            if b.favorite { counts[.favorites, default: 0] += 1 }
            let list = b.collectionList
            if list.isEmpty { counts[.unfiled, default: 0] += 1; continue }
            // 「小説」と「小説/SF」の両方に入れてある本を親で二重に数えないよう、一度集める。
            bucket.removeAll(keepingCapacity: true)
            for id in list { bucket.formUnion(chain[id] ?? []) }
            for id in bucket { counts[.collection(id), default: 0] += 1 }
        }
        return counts
    }

    // MARK: メタデータのバックフィル（旧データに作者・出版社が無い場合）

    private var didBackfill = false
    /// 1回の起動で埋め直す上限。
    ///
    /// 1冊ごとに使い捨ての WKWebView を立てるので、数百冊ぶんを起動直後にまとめて走らせると
    /// 書棚が触れなくなる（実データで対象 91 冊）。少しずつ埋めて、残りは次の起動に回す。
    private static let backfillBatchLimit = 25

    /// 作者/出版社が未取得の本について、EPUB を開いて埋める（既存データを壊さず追記）。
    func backfillMetadataIfNeeded() {
        guard !didBackfill else { return }
        didBackfill = true
        // 作者/出版社/読み(authorSort)/表紙のいずれかが未取得の本を対象にする。
        // （表紙は probe が失敗した本で丸ごと欠けるため、メタと同じ経路で埋め直す。）
        let targets = books.filter { b in
            // 一度調べた本は結果が空でも二度と調べない（持っていないのが正しい本があるため）。
            guard b.metaProbed != true, b.fileExists else { return false }
            let missingMeta = b.author == nil && b.publisher == nil
            let missingSort = b.author != nil && b.authorSort == nil
            let missingCover = b.coverFileName == nil
            return missingMeta || missingSort || missingCover
        }.prefix(Self.backfillBatchLimit)
        guard !targets.isEmpty else { return }

        // 取り込みと同じ列に並べる。EpubProbe は使い捨ての WebView を1個ずつ立てる作りなので、
        // フォルダ一括登録と重なって並走すると両方が破綻する。
        enqueueProbeWork { [weak self] in
            guard let self else { return }
            for book in targets {
                if Task.isCancelled { break }
                let meta = await EpubProbe.probe(url: book.fileURL)
                guard let idx = books.firstIndex(where: { $0.id == book.id }) else { continue }
                // 開けた／開けなかったに関わらず「調べた」と記す。開けない本を毎回開き直さない。
                books[idx].metaProbed = true
                guard let meta else { continue }
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

    /// 表紙の置き場所。**書棚ごとに分ける**（表紙は装丁そのもの＝どの本を持っているかが一目で分かる）。
    private var coversDir: URL { ProfileLocation.shared.coversDirectory }

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
        // コストは実際に抱えるピクセルのバイト数。上限（load で設定）を超えたぶんから捨てられる。
        let px = image.size.width * image.scale * image.size.height * image.scale
        coverCache.setObject(image, forKey: key, cost: Int(px) * 4)
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

    // MARK: 本を開く／まとめて取り込む

    func open(url: URL) {
        // 既に書棚にある本は取り込みの列に並ばせず、すぐ開く（メタ抽出が要らないため、
        // フォルダの一括登録が走っている最中でも待たされない）。
        if let existing = books.first(where: { $0.path == url.path }) {
            var e = existing
            e.lastOpenedAt = Date()
            replace(e)
            openedBook = e
            return
        }
        enqueueImport([url], openFirst: true, announces: false)
    }

    /// ドロップやファイルパネルで受け取った URL 群を書棚へ入れる。
    ///
    /// フォルダは呼び出し側（BookDrop / ImportableBook.expand）で中身へ展開済みの前提。
    /// 1冊だけのときは従来どおり開き、複数のときは開かずに書棚へ積む
    ///（何十冊も一度に開きようがないため）。
    func add(urls: [URL], openIfSingle: Bool = true) {
        let files = ImportableBook.expand(urls)
        guard !files.isEmpty else {
            report(String(localized: "登録できるファイルがありませんでした"))
            return
        }
        if files.count == 1, openIfSingle {
            open(url: files[0])
            return
        }
        enqueueImport(files, openFirst: false, announces: true)
    }

    /// 同梱サンプルを初回だけ書棚に登録（開発時にすぐ試せるように）。
    /// 縦書きサンプルに加え、画像位置・余白の測定用メジャー本もシードする。
    func seedSampleIfNeeded() {
        // 増やした書棚は**空のまま**にする。人へ見せるために作った書棚に、頼んでいない本を
        // 入れない（実際、印を付けずに作ると空の書棚がサンプル2冊で始まった）。
        guard currentProfileID == ShelfProfile.primaryID else { return }
        let seededKey = "library.seeded.v2"
        guard books.isEmpty, !UserDefaults.standard.bool(forKey: seededKey) else { return }
        UserDefaults.standard.set(true, forKey: seededKey)
        let names = ["sample-vertical", "ruler-measure"]
        let urls = names.compactMap { Bundle.main.url(forResource: $0, withExtension: "epub") }
        // 初回起動の帯は出さない（利用者が頼んだ取り込みではないため）。
        enqueueImport(urls, openFirst: false, announces: false)
    }

    // MARK: 取り込みの進み具合

    /// まとめて登録しているあいだの進み具合（BookImportBanner が出す）。
    struct ImportProgress: Equatable {
        var done = 0
        var total = 0
        var added = 0
        var skipped = 0
        var failed = 0
        /// いま処理しているファイル名。
        var current = ""

        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    @Published var importProgress: ImportProgress?
    /// 取り込みが終わったときの短い報告（数秒で自動的に消える）。
    @Published var importReport: String?

    /// 取り込みは一列に並べて順に走らせる。EpubProbe が1冊ごとに使い捨ての WebView を立てるので、
    /// フォルダの中身を一斉に走らせるとメモリも CPU も破綻する（probe 自身も直列化を求めている）。
    private var importChain: Task<Void, Never>?
    /// 「中止」の旗。列に並んでいる取り込みまで含めて降ろすため、Task の cancel と別に持つ。
    private var importCancelled = false
    private var reportClearTask: Task<Void, Never>?

    private func enqueueImport(_ urls: [URL], openFirst: Bool, announces: Bool) {
        guard !urls.isEmpty else { return }
        // 新しく頼まれた取り込みは、前の「中止」を引きずらない。
        importCancelled = false
        enqueueProbeWork { [weak self] in
            await self?.runImport(urls, openFirst: openFirst, announces: announces)
        }
    }

    /// EPUB を開いて調べる作業（取り込み・メタの埋め直し）を1本の列に並べる。
    /// `EpubProbe` は1冊ごとに使い捨ての WebView を立てるので、並走させるとメモリも CPU も破綻する。
    private func enqueueProbeWork(_ work: @escaping @MainActor () async -> Void) {
        let previous = importChain
        importChain = Task { @MainActor in
            _ = await previous?.value
            await work()
        }
    }

    /// 取り込みを中断する（フォルダを取り違えたときの逃げ道）。並んでいる分もまとめて降ろす。
    ///
    /// 走っているのは列の**先頭**の Task で、`importChain` が持っているのは**末尾**なので、
    /// Task の cancel だけでは今動いている取り込みは止まらない。合図は旗で回す。
    func cancelImport() {
        importCancelled = true
        importChain?.cancel()
    }

    private func runImport(_ urls: [URL], openFirst: Bool, announces: Bool) async {
        // 待っているあいだに中止されたぶんは、黙って降ろす（報告は止めた本人に既に出ている）。
        guard !importCancelled else { return }
        var p = ImportProgress(total: urls.count)
        // 1冊だけの取り込み（ドロップやメニューから開くとき）は帯を出さない。
        let showsBanner = announces && urls.count > 1
        if showsBanner { importProgress = p }
        defer { if showsBanner { importProgress = nil } }

        var cancelled = false
        for (i, url) in urls.enumerated() {
            if importCancelled || Task.isCancelled { cancelled = true; break }
            p.current = url.lastPathComponent
            if showsBanner { importProgress = p }
            switch await register(url: url, thenOpen: openFirst && i == 0) {
            case .added: p.added += 1
            case .alreadyRegistered: p.skipped += 1
            case .unreadable: p.failed += 1
            }
            p.done += 1
            if showsBanner { importProgress = p }
        }
        // 一括登録は1冊ごとの保存をまとめているので、終わったところで必ず書き切る。
        flushPendingSaves()
        guard announces else { return }
        report(Self.reportText(for: p, cancelled: cancelled))
    }

    /// 取り込み結果の一文。「何冊入ったか」を主に、対処が要る数（登録済み・読めなかった）を添える。
    private static func reportText(for p: ImportProgress, cancelled: Bool) -> String {
        var text = cancelled
            ? String(format: String(localized: "取り込みを中止しました（%lld冊を追加）"), Int64(p.added))
            : String(format: String(localized: "%lld冊を書棚に追加しました"), Int64(p.added))
        var notes: [String] = []
        if p.skipped > 0 {
            notes.append(String(format: String(localized: "%lld冊は登録済み"), Int64(p.skipped)))
        }
        if p.failed > 0 {
            notes.append(String(format: String(localized: "%lld冊は読めませんでした"), Int64(p.failed)))
        }
        if !notes.isEmpty { text += "（" + notes.joined(separator: "・") + "）" }
        return text
    }

    /// 帯に短い報告を出す。次の報告が来るか、一定時間で消える。
    private func report(_ text: String) {
        importReport = text
        reportClearTask?.cancel()
        reportClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.importReport = nil
        }
    }

    /// 1冊分の登録結果。取り込みの報告（追加/登録済み/読めず）に使う。
    enum RegisterResult { case added, alreadyRegistered, unreadable }

    @discardableResult
    private func register(url: URL, thenOpen: Bool) async -> RegisterResult {
        // ドロップ/ピッカー由来のURLは念のためアクセス開始（sandbox無効でも無害）。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // 既存の本ならメタ更新して開くだけ。
        if let existing = books.first(where: { $0.path == url.path }) {
            var e = existing
            e.lastOpenedAt = Date()
            replace(e)
            if thenOpen { openedBook = e }
            return .alreadyRegistered
        }

        // 消えた本・読めない本を書棚へ足さない（フォルダ一括だと気付けないため先に弾く）。
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            dlog("[Import] unreadable \(url.lastPathComponent)")
            return .unreadable
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

        var entry = BookEntry(
            id: id, path: url.path, title: title,
            addedAt: Date(), lastOpenedAt: Date(),
            locatorJSON: nil, coverFileName: coverName,
            author: author, publisher: publisher, authorSort: authorSort
        )
        // 登録時に調べ終えている。起動のたびの埋め直しの対象にしない。
        entry.metaProbed = true
        books.insert(entry, at: 0)
        save()
        if thenOpen { openedBook = entry }
        return .added
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

    // MARK: 書棚（プロファイル）の切り替えと管理

    private var profileIndex: ProfileIndex {
        ProfileIndex(profiles: profiles, currentID: currentProfileID)
    }

    var currentProfile: ShelfProfile? { profiles.first { $0.id == currentProfileID } }

    private func persistProfiles() {
        profileStore.save(profileIndex)
    }

    /// 書棚を切り替える。
    ///
    /// **見落としが漏洩そのものになる作業なので、手放すものをここに一列で並べてある。**
    /// 前の書棚のものが顔を出す経路は蔵書の一覧だけではない——書棚の地（最後に開いた本の表紙）・
    /// 「続きを読む」段・表紙のメモリキャッシュ・読み辞書・共通CSS・対訳の貯め・走っている
    /// 取り込みが、それぞれ別の場所を握っている。
    func switchProfile(to id: UUID) {
        guard id != currentProfileID, profiles.contains(where: { $0.id == id }) else { return }

        // 1. 走っているものを降ろす。取り込みが特に大事で、続けさせると**切り替えた先の書棚へ
        //    前の書棚の本が入る**。
        cancelImport()
        autoPager.stop()
        activeReader?.stopSpeaking()

        // 2. いまの書棚へ書き切ってから離れる（読書位置は溜めてあるので、ここで落とさない）。
        flushPendingSaves()

        // 3. 本を閉じる。リーダーが前の書棚の本を握ったままにしない。
        openedBook = nil
        activeReader = nil

        // 4. 見る先を移す。ここから下の保存先の解決はすべて新しい書棚を指す。
        ProfileLocation.shared.move(to: id)
        currentProfileID = id
        persistProfiles()

        // 5. 前の書棚のものを抱えている入れ物を空にする。
        store = LibraryStore()
        coverCache.removeAllObjects()
        // 開いていた本の「解決済みCSS」は本ごとの指定を含む。次に本を開くまで残さない。
        UserDefaults.standard.removeObject(forKey: EpubOpener.activeCSSKey)
        Task { await TranslationCache.shared.detach() }

        // 6. 新しい書棚を読む。読めなかったときに前の蔵書が残らないよう、先に空にしてから読む。
        books = []
        collections = []
        shelfScope = .all
        didBackfill = false   // 新しい書棚の本もメタの埋め直しの対象にする
        load()
        libraryRevision &+= 1

        // 7. 気付けるようにする。書棚が空になったのを「蔵書が消えた」と誤解しないため。
        let name = currentProfile?.name ?? ""
        report(String(format: String(localized: "書棚「%@」に切り替えました"), name))
    }

    /// 書棚を足す。**中身は空**（同梱サンプルも入れない）。
    @discardableResult
    func addProfile(name: String) -> ShelfProfile? {
        var index = profileIndex
        guard let created = index.add(name: name) else { return nil }
        profiles = index.profiles
        persistProfiles()
        return created
    }

    @discardableResult
    func renameProfile(_ id: UUID, to name: String) -> Bool {
        var index = profileIndex
        guard index.rename(id, to: name) else { return false }
        profiles = index.profiles
        persistProfiles()
        return true
    }

    func canRemoveProfile(_ id: UUID) -> Bool { profileIndex.canRemove(id) }

    /// 書棚を消す。**保存先は消さずに `Profiles/Deleted/` へ寄せる**（`ProfileLocation.retire`）。
    /// 中身は「どの本を登録したか・どこまで読んだか」で、EPUB 本体と違って作り直せない。
    @discardableResult
    func removeProfile(_ id: UUID) -> Bool {
        var index = profileIndex
        guard index.remove(id) else { return false }
        profiles = index.profiles
        persistProfiles()
        ProfileLocation.shared.retire(id)
        ProfileDefaults.removeAll(for: id)
        return true
    }

    // MARK: 書棚操作

    func closeBook() {
        openedBook = nil
        books.sort { $0.lastOpenedAt > $1.lastOpenedAt }
        // 読んでいるあいだに溜めた位置をここで書き切る（次に落ちても読書位置を失わない）。
        flushPendingSaves()
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
