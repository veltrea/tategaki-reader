import SwiftUI
import UniformTypeIdentifiers

/// Kindle 風の書棚。カバーをグリッド表示し、タップで開く。
/// 左のサイドバーで「すべて／お気に入り／未分類／分類（入れ子）」を選び、
/// 右で絞り込み・並び替え・表示モードを切り替える。
struct ShelfView: View {
    @ObservedObject var model: AppModel

    /// 並び替えキー。
    enum SortKey: String, CaseIterable, Identifiable {
        case recent, title, author, publisher
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recent: return "最近開いた"
            case .title: return "タイトル"
            case .author: return "作者"
            case .publisher: return "出版社"
            }
        }
    }
    /// フィルタ対象の項目。
    enum FilterField: String, CaseIterable, Identifiable {
        case all, title, author, publisher
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "すべて"
            case .title: return "タイトル"
            case .author: return "作者"
            case .publisher: return "出版社"
            }
        }
    }

    /// 表示モード。グリッド or 作者別の五十音インデックス。
    enum DisplayMode: String, CaseIterable, Identifiable {
        case grid, authorIndex
        var id: String { rawValue }
        var label: String { self == .grid ? "グリッド" : "作者別" }
        var icon: String { self == .grid ? "square.grid.2x2" : "list.bullet.indent" }
    }

    @State private var sort: SortKey = .recent
    @State private var query = ""
    /// 実際に絞り込みへ使う語。入力から少し遅らせる（1文字ごとに全冊を走らせないため）。
    @State private var appliedQuery = ""
    @State private var field: FilterField = .all
    @State private var displayMode: DisplayMode = .grid
    @State private var showSidebar = true
    @State private var yomiEditBook: BookEntry?
    @State private var yomiDraft = ""
    /// 新しい分類の名前を尋ねる。`newCollectionParent` の下に作る。
    @State private var showNewCollection = false
    @State private var newCollectionName = ""
    @State private var newCollectionParent: UUID?
    /// 作った分類へすぐ入れる本（「新しい分類に入れる…」から来たとき）。
    @State private var newCollectionBook: UUID?
    @State private var renameCollectionID: UUID?
    @State private var renameDraft = ""

    /// 絞り込み・並び替えを済ませた表示用データ。
    ///
    /// 冊数に比例して重い（実測 1368 冊でソート 20ms・絞り込み 6ms）ので、SwiftUI の
    /// body 評価のたびにやり直さない。棚・絞り込み・並びのどれかが変わったときだけ作り直す。
    @State private var contents = ShelfContents()

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 24)]

    /// 表示用データを作り直す合図。ここが変わったときだけ計算し直す。
    private struct RecomputeKey: Equatable {
        var revision: Int
        var scope: ShelfScope
        var sort: SortKey
        var query: String
        var field: FilterField
        var mode: DisplayMode
    }

    private var recomputeKey: RecomputeKey {
        RecomputeKey(revision: model.libraryRevision, scope: model.shelfScope,
                     sort: sort, query: appliedQuery, field: field, mode: displayMode)
    }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                CollectionSidebar(
                    model: model,
                    counts: contents.counts,
                    onNewCollection: { parent in
                        newCollectionParent = parent
                        newCollectionBook = nil
                        newCollectionName = ""
                        showNewCollection = true
                    },
                    onRename: { id in
                        renameDraft = model.collections.first { $0.id == id }?.name ?? ""
                        renameCollectionID = id
                    })
                .frame(width: 240)
                Divider()
            }
            shelfPane
        }
        // 書棚全体の地。最後に読んだ本のカバーを弱くぼかして敷く（スクロールしても動かない）。
        .background { ShelfBackdrop(image: backdropBook.flatMap { model.coverImage(for: $0) }) }
        .task { model.backfillMetadataIfNeeded() }
        // 入力から少し遅らせて絞り込む。1文字ごとに全冊を走らせない。
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            appliedQuery = query
        }
        // 表示用データの作り直し。取り込み中は蔵書が次々変わるが、`.task(id:)` は合図が
        // 変わるたびに前の計算を取り消すので、落ち着くまで作り直しは走らない。
        .task(id: recomputeKey) {
            let key = recomputeKey
            if !contents.isEmpty || !model.books.isEmpty {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            guard !Task.isCancelled else { return }
            contents = ShelfContents.make(model: model, scope: key.scope, query: key.query,
                                          field: key.field, sort: key.sort, mode: key.mode)
        }
        #if DEBUG
        .task {
            // DEBUG 限定: テストバスから実アラート（作者の読み）を開けるようフックを登録。
            TestBus.shared.openYomiEditor = { book in
                yomiDraft = book.resolvedAuthorReading ?? ""
                yomiEditBook = book
            }
            // 書棚に「いま実際に出ている本」を読めるようにする（棚の切り替えの検証用）。
            TestBus.shared.shelfSnapshot = { contents.all.map { ($0.id, $0.title) } }
        }
        #endif
        .sheet(isPresented: $model.showSettings) {
            SettingsView(model: model, reader: nil)
        }
        .alert("作者の読み", isPresented: Binding(
            get: { yomiEditBook != nil },
            set: { if !$0 { yomiEditBook = nil } }
        )) {
            TextField("かなで入力（例: やまだ たろう）", text: $yomiDraft)
                .autocorrectionDisabled()
            Button("保存") {
                if let b = yomiEditBook { model.setAuthorYomi(bookID: b.id, yomi: yomiDraft) }
                yomiEditBook = nil
            }
            .keyboardShortcut(.defaultAction)   // Return で確定
            Button("クリア", role: .destructive) {
                if let b = yomiEditBook { model.setAuthorYomi(bookID: b.id, yomi: "") }
                yomiEditBook = nil
            }
            Button("キャンセル", role: .cancel) { yomiEditBook = nil }
        } message: {
            Text("五十音インデックスの分類・並びに使います。空欄でEPUBの情報に戻します。")
        }
        .alert("新しい分類", isPresented: $showNewCollection) {
            TextField("分類の名前", text: $newCollectionName)
            Button("作成") {
                guard let id = model.addCollection(name: newCollectionName,
                                                   parent: newCollectionParent) else { return }
                if let book = newCollectionBook {
                    model.setMembership(bookID: book, collectionID: id, member: true)
                }
                newCollectionBook = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("キャンセル", role: .cancel) { newCollectionBook = nil }
        } message: {
            Text(newCollectionParent.map {
                "「\(CollectionTree.pathName(of: $0, in: model.collections))」の下に作ります。"
            } ?? "本を分けてしまうための棚です。あとから入れ子にもできます。")
        }
        .alert("分類の名前を変更", isPresented: Binding(
            get: { renameCollectionID != nil },
            set: { if !$0 { renameCollectionID = nil } }
        )) {
            TextField("分類の名前", text: $renameDraft)
            Button("保存") {
                if let id = renameCollectionID { model.renameCollection(id: id, to: renameDraft) }
                renameCollectionID = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("キャンセル", role: .cancel) { renameCollectionID = nil }
        }
    }

    // MARK: 書棚側（ヘッダ + 本）

    private var shelfPane: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.books.isEmpty {
                emptyState
            } else if contents.isEmpty {
                noMatchState
            } else if displayMode == .grid {
                gridView
            } else {
                authorIndexView
            }
        }
    }

    /// 最後に読んだ（＝最後に開いた）1冊。段の主役であり、書棚の地に敷くカバーの持ち主。
    /// 絞り込みや棚の選択に左右されない（地が操作のたびに入れ替わると落ち着かないため）。
    private var backdropBook: BookEntry? {
        model.books.max(by: { $0.lastOpenedAt < $1.lastOpenedAt })
    }

    /// 「続きを読む」段に出す本。
    /// 絞り込み中は、その結果に含まれるときだけ出す（無関係な本が段に残らないように）。
    private var continueBook: BookEntry? {
        guard let latest = backdropBook, contents.containsID(latest.id) else { return nil }
        return latest
    }

    private var gridView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let book = continueBook {
                    ContinueReadingBanner(book: book, image: model.coverImage(for: book)) {
                        model.open(url: book.fileURL)
                    }
                    Divider()
                }
                LazyVGrid(columns: columns, spacing: 28) {
                    ForEach(contents.all) { book in cell(book) }
                }
                .padding(24)
            }
        }
    }

    /// 作者別の五十音インデックス表示（見出しをピン留め）。
    private var authorIndexView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                ForEach(contents.sections, id: \.key) { section in
                    Section {
                        LazyVGrid(columns: columns, spacing: 28) {
                            ForEach(section.books) { book in cell(book) }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                    } header: {
                        Text(section.key)
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 6)
                            .background(.bar)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    /// カバー1枚（タップで開く・右クリックでお気に入り／分類／削除）。グリッド/インデックス共用。
    @ViewBuilder
    private func cell(_ book: BookEntry) -> some View {
        BookCell(book: book, image: model.coverImage(for: book))
            .onTapGesture { model.open(url: book.fileURL) }
            // サイドバーの分類へ放り込めるようにする（本の ID を文字列で渡すだけ）。
            .onDrag { NSItemProvider(object: book.id.uuidString as NSString) }
            .contextMenu {
                Button {
                    model.toggleFavorite(bookID: book.id)
                } label: {
                    Label(book.favorite ? "お気に入りから外す" : "お気に入りに追加",
                          systemImage: book.favorite ? "star.slash" : "star")
                }
                Menu {
                    if model.collections.isEmpty {
                        Text("分類がありません")
                    }
                    ForEach(CollectionTree.rows(model.collections,
                                                expanded: Set(model.collections.map(\.id)))) { row in
                        let inside = book.collectionList.contains(row.id)
                        Button {
                            model.setMembership(bookID: book.id, collectionID: row.id,
                                                member: !inside)
                        } label: {
                            Label(String(repeating: "　", count: row.depth) + row.collection.name,
                                  systemImage: inside ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    Divider()
                    Button {
                        newCollectionParent = nil
                        newCollectionBook = book.id
                        newCollectionName = ""
                        showNewCollection = true
                    } label: { Label("新しい分類に入れる…", systemImage: "folder.badge.plus") }
                } label: { Label("分類", systemImage: "folder") }
                Divider()
                Button {
                    yomiDraft = book.resolvedAuthorReading ?? ""
                    yomiEditBook = book
                } label: { Label("作者の読みを設定…", systemImage: "character.book.closed") }
                Divider()
                Button(role: .destructive) {
                    model.remove(book)
                } label: { Label("書棚から削除", systemImage: "trash") }
            }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showSidebar.toggle() }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("サイドバーの表示")
                Text(scopeTitle)
                    .font(.title2.bold())
                // 桁区切りはサイドバーの冊数（SwiftUI の既定書式）と揃える。
                Text(String(format: String(localized: "%@冊"), contents.all.count.formatted()))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { model.showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .help("設定")
                // ファイルとフォルダでパネルを分ける（1枚では混ぜて選べない。BookOpenPanel を参照）。
                // キー割り当て（⌘O／⇧⌘O）はメニューバー側が持つので、ここでは付けない。
                Menu {
                    Button("ファイルを選ぶ…") { model.requestOpenPanel = true }
                    Button("フォルダを選ぶ…") { model.requestFolderPanel = true }
                } label: {
                    Label("本を追加", systemImage: "plus")
                }
                .fixedSize()
            }
            HStack(spacing: 10) {
                // フィルタ（絞り込み検索）＋ 対象項目
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                    TextField("フィルタ", text: $query)
                        .textFieldStyle(.plain)
                        .frame(maxWidth: 240)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Menu(field.label) {
                        Picker("対象", selection: $field) {
                            ForEach(FilterField.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))

                Spacer()

                // 表示モード（グリッド / 作者別インデックス）
                Picker("表示", selection: $displayMode) {
                    ForEach(DisplayMode.allCases) { Image(systemName: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                // 並び替え（グリッドのみ。作者別は五十音順で並ぶ）
                if displayMode == .grid {
                    Menu {
                        Picker("並び替え", selection: $sort) {
                            ForEach(SortKey.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Label("並び替え: \(sort.label)", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        // 地のカバーがそのまま透けるとツールバーが書棚と溶けて境目が消える。かといって
        // 完全な不透明も浮くので、地色をほぼ塗り潰す濃さで敷き、カバーをわずかに透かす。
        // マテリアルではなく実数の不透明度なのは、透け具合をここで確実に決めたいため。
        .background(Color(uiColor: .systemBackground).opacity(0.74))
    }

    /// ヘッダに出す、いま見ている棚の名前。
    private var scopeTitle: String {
        switch model.shelfScope {
        case .all: return String(localized: "書棚")
        case .favorites: return String(localized: "お気に入り")
        case .unfiled: return String(localized: "未分類")
        case .collection(let id):
            return model.collections.first { $0.id == id }?.name ?? String(localized: "書棚")
        }
    }

    private var noMatchState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("該当する本がありません")
                .font(.headline)
            Text(appliedQuery.isEmpty ? "この分類にはまだ本が入っていません" : "フィルタ条件を変えてください")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("本がありません")
                .font(.headline)
            Text("「本を追加」または EPUB やフォルダをウィンドウにドラッグ＆ドロップ")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("フォルダは中の EPUB をまとめて登録します（サブフォルダも探します）")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 表示用データ（絞り込み・並び替えの結果）

/// 書棚に出す本を、絞り込み・並び替えまで済ませた形で持つ。
///
/// 作るのが重い（1368 冊で数十 ms）ので、`ShelfView` は @State に控えて使い回す。
/// SwiftUI の body から毎回作らないことが要点で、中身の作り方は従来と同じ。
struct ShelfContents {
    var all: [BookEntry] = []
    var sections: [(key: String, books: [BookEntry])] = []
    var counts: [ShelfScope: Int] = [:]
    private var ids: Set<UUID> = []

    var isEmpty: Bool { all.isEmpty }
    func containsID(_ id: UUID) -> Bool { ids.contains(id) }

    @MainActor
    static func make(model: AppModel, scope: ShelfScope, query: String,
                     field: ShelfView.FilterField, sort: ShelfView.SortKey,
                     mode: ShelfView.DisplayMode) -> ShelfContents {
        var out = ShelfContents()
        out.counts = model.shelfCounts()

        var list = model.books(in: scope)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            func hit(_ s: String) -> Bool { s.lowercased().contains(q) }
            list = list.filter { b in
                switch field {
                case .all: return hit(b.title) || hit(b.authorText) || hit(b.publisherText)
                case .title: return hit(b.title)
                case .author: return hit(b.authorText)
                case .publisher: return hit(b.publisherText)
                }
            }
        }

        switch sort {
        case .recent: break // model.books は lastOpenedAt 降順で保持済み
        case .title: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author: list.sort { $0.authorText.localizedStandardCompare($1.authorText) == .orderedAscending }
        case .publisher: list.sort { $0.publisherText.localizedStandardCompare($1.publisherText) == .orderedAscending }
        }
        out.all = list
        out.ids = Set(list.map(\.id))
        if mode == .authorIndex { out.sections = AuthorIndex.sections(of: list) }
        return out
    }
}

// MARK: - 作者別 五十音インデックス

/// 作者の読みから見出しを決めてグループ分けする。純ロジックなので単体で確かめられる。
enum AuthorIndex {
    /// セクション見出しの並び順: あ〜わ → A〜Z → # → 他（漢字で読み無し）→ —（作者なし）。
    static let sectionOrder: [String] =
        ["あ","か","さ","た","な","は","ま","や","ら","わ"]
        + (65...90).map { String(UnicodeScalar($0)!) }
        + ["#", "他", "—"]

    /// かな1文字→行の頭文字（あ/か/…/わ）。かなでなければ nil。
    static func kanaRow(_ ch: Character) -> String? {
        guard var v = ch.unicodeScalars.first?.value else { return nil }
        if (0x30A1...0x30FA).contains(v) { v -= 0x60 }      // カタカナ→ひらがな
        guard (0x3041...0x3096).contains(v) else { return nil }
        let rows: [(UInt32, String)] = [
            (0x3042,"あ"),(0x304B,"か"),(0x3055,"さ"),(0x305F,"た"),(0x306A,"な"),
            (0x306F,"は"),(0x307E,"ま"),(0x3084,"や"),(0x3089,"ら"),(0x308F,"わ"),
        ]
        var row = "あ"                                       // ぁ等の小書きは あ 行に寄せる
        for (start, name) in rows where v >= start { row = name }
        return row
    }

    /// 本の作者読みから見出しキーを決める。
    static func sectionKey(_ book: BookEntry) -> String {
        let key = book.authorSortKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ch = key.first else { return "—" }         // 作者なし
        if let row = kanaRow(ch) { return row }
        if ch.isNumber { return "#" }
        if ch.isLetter {
            let up = String(ch).uppercased()
            if let f = up.unicodeScalars.first, f.isASCII { return String(up.prefix(1)) }
            return "他"                                       // 漢字など（読み未取得）
        }
        return "#"
    }

    /// 見出しでグループ化し、順序どおりに並べたセクション配列。
    static func sections(of books: [BookEntry]) -> [(key: String, books: [BookEntry])] {
        let groups = Dictionary(grouping: books) { sectionKey($0) }
        return groups.map { (key: $0.key, books: $0.value.sorted { a, b in
            let c = a.authorSortKey.localizedStandardCompare(b.authorSortKey)
            if c != .orderedSame { return c == .orderedAscending }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }) }
        .sorted {
            (sectionOrder.firstIndex(of: $0.key) ?? 999) < (sectionOrder.firstIndex(of: $1.key) ?? 999)
        }
    }
}

// MARK: - サイドバー（分類の階層）

/// 左のサイドバー。固定の棚（すべて／お気に入り／未分類）と、入れ子にできる分類を並べる。
///
/// 分類は再帰的な `DisclosureGroup` ではなく、**平らな列に均してから**出す
///（`CollectionTree.rows`）。行の深さも開閉も自分で持つので、どの行が出ているかを
/// そのまま数え上げられる＝ふるまいを機械で確かめられる。
private struct CollectionSidebar: View {
    @ObservedObject var model: AppModel
    let counts: [ShelfScope: Int]
    let onNewCollection: (UUID?) -> Void
    let onRename: (UUID) -> Void

    @State private var expanded: Set<UUID> = []

    var body: some View {
        List {
            Section("書棚") {
                row(.all, title: String(localized: "すべての本"), symbol: "books.vertical")
                row(.favorites, title: String(localized: "お気に入り"), symbol: "star.fill")
                row(.unfiled, title: String(localized: "未分類"), symbol: "tray")
            }
            Section {
                ForEach(CollectionTree.rows(model.collections, expanded: expanded)) { r in
                    collectionRow(r)
                }
                Button {
                    onNewCollection(nil)
                } label: {
                    Label("新しい分類…", systemImage: "folder.badge.plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } header: {
                HStack {
                    Text("分類")
                    Spacer()
                    // 分類が1つも無いうちは「新しい分類…」行だけでは気付きにくいので見出しにも出す。
                    Button { onNewCollection(nil) } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .help("最上位に分類を作る")
                }
            }
        }
        .listStyle(.sidebar)
        .background(Color(uiColor: .systemBackground).opacity(0.74))
    }

    @ViewBuilder
    private func row(_ scope: ShelfScope, title: String, symbol: String) -> some View {
        Button {
            model.setScope(scope)
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text("\(counts[scope] ?? 0)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selectionBackground(scope))
    }

    @ViewBuilder
    private func collectionRow(_ r: CollectionTree.Row) -> some View {
        let scope = ShelfScope.collection(r.id)
        HStack(spacing: 4) {
            // 深さぶんの字下げ。子を持つ行だけ開閉の山形を出す。
            Spacer().frame(width: CGFloat(r.depth) * 14)
            Button {
                if expanded.contains(r.id) { expanded.remove(r.id) } else { expanded.insert(r.id) }
            } label: {
                Image(systemName: expanded.contains(r.id) ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .opacity(r.hasChildren ? 1 : 0)
            }
            .buttonStyle(.plain)
            .disabled(!r.hasChildren)

            Button {
                model.setScope(scope)
            } label: {
                HStack {
                    Label(r.collection.name, systemImage: "folder")
                        .lineLimit(1)
                    Spacer()
                    Text("\(counts[scope] ?? 0)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(selectionBackground(scope))
        // 本のカバーをここへ落とすと、その分類に入る。
        .onDrop(of: [.text], isTargeted: nil) { providers in
            receiveBooks(providers, into: r.id)
        }
        .contextMenu {
            Button { onRename(r.id) } label: { Label("名前を変更…", systemImage: "pencil") }
            Button { onNewCollection(r.id) } label: {
                Label("この中に分類を作る…", systemImage: "folder.badge.plus")
            }
            if r.collection.parentID != nil {
                Button { model.moveCollection(id: r.id, under: nil) } label: {
                    Label("最上位へ移動", systemImage: "arrow.up.to.line")
                }
            }
            Divider()
            Button(role: .destructive) { model.removeCollection(id: r.id) } label: {
                Label("分類を削除", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func selectionBackground(_ scope: ShelfScope) -> some View {
        if model.shelfScope == scope {
            Color.accentColor.opacity(0.18)
        } else {
            Color.clear
        }
    }

    /// カバーから落ちてきた本の ID を受け取って分類へ入れる。
    private func receiveBooks(_ providers: [NSItemProvider], into collectionID: UUID) -> Bool {
        var ids: [UUID] = []
        let group = DispatchGroup()
        for p in providers where p.canLoadObject(ofClass: NSString.self) {
            group.enter()
            _ = p.loadObject(ofClass: NSString.self) { value, _ in
                if let s = value as? String, let id = UUID(uuidString: s) { ids.append(id) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !ids.isEmpty else { return }
            model.setMembership(bookIDs: ids, collectionID: collectionID, member: true)
        }
        return true
    }
}

/// 書棚全体の地。最後に読んだ本のカバーを敷き、弱くぼかす（Kindle のトップと同じ狙い）。
/// 「何の本か分かる程度」に留めたいので、ぼかしは弱め・上に地色を薄く重ねて文字を読めるようにする。
private struct ShelfBackdrop: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // opaque: true でにじみの縁が透けないようにする。
                    .blur(radius: 20, opaque: true)
                    .opacity(0.55)
                // カバーの明暗に関わらずラベル色が読めるよう、地色を薄く被せる。
                Color(uiColor: .systemBackground).opacity(0.3)
            }
        }
        // aspectRatio(.fill) で枠より大きく広がるので、書棚の枠で切る。
        .clipped()
        .ignoresSafeArea()
    }
}

/// 書棚の最上段。最後に読んだ1冊だけを大きく扱い、そこから読書へ復帰できるようにする。
/// 地は書棚全体の背景（ShelfBackdrop）に任せ、この段は自前の背景を持たない。
private struct ContinueReadingBanner: View {
    let book: BookEntry
    let image: UIImage?
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            cover
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.title2.bold())
                    .lineLimit(2)
                if !book.authorText.isEmpty {
                    Text(book.authorText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let pct = book.progressPercent {
                    Text("\(pct)% 読了")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button(book.hasStartedReading ? "続きを読む" : "読み始める", action: open)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                    .disabled(!book.fileExists)
                if !book.fileExists {
                    Text("ファイルが見つかりません")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cover: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                DefaultCover()
                Text(book.title)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 18)
            }
        }
        .frame(width: 130, height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 5)
        .contentShape(Rectangle())
        .onTapGesture { if book.fileExists { open() } }
    }

}

/// 書棚の1セル（カバー + タイトル）。
private struct BookCell: View {
    let book: BookEntry
    let image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
            .frame(width: 150, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.black.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 3)
            .overlay(alignment: .topLeading) {
                // お気に入りは左上（右上はファイル欠落の警告が使う）。
                if book.favorite {
                    // 表紙の絵柄に紛れないよう、進捗バッジと同じ暗い地を敷く
                    //（星だけだと明るい表紙・黄色い装丁の上で見えなくなる）。
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(5)
                        .background(Circle().fill(.black.opacity(0.65)))
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !book.fileExists {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let pct = book.progressPercent {
                    Text("\(pct)%")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.65)))
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.footnote)
                    // 常に2行分の高さを確保（短いタイトルでも空行を予約）＝全セル同一高になり
                    // カバーが上で揃う。長いタイトルは2行で末尾を … に切り詰め。
                    .lineLimit(2, reservesSpace: true)
                    .truncationMode(.tail)
                Text(book.authorText.isEmpty ? " " : book.authorText)  // 空でも1行分確保
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .multilineTextAlignment(.leading)
            .frame(width: 150, alignment: .topLeading)
        }
        // セル内容を上揃えにして、万一行高がばらついてもカバー位置を固定する。
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var placeholder: some View {
        ZStack {
            DefaultCover()
            Text(book.title)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(10)
                // 装丁の罫の内側に収める（罫にかかると読みにくい）。
                .padding(.horizontal, 8)
        }
    }
}

/// 表紙を持たない本のための、アプリ同梱の代替表紙。
///
/// EPUB には表紙が「無いのが正しい」本がある——青空文庫由来の短編や、変換で表紙を落とした本、
/// そもそも本文が文字だけで画像を1枚も含まない本。そういう本を無地の矩形で並べると
/// 書棚が抜け落ちて見えるので、装丁を模した絵を敷いてタイトルを乗せる。
///
/// 画像は Assets の "DefaultCover"（800x1200 @2x）。読めなかったときのために、
/// 同じ配色のグラデーションへ落ちる（アセットの取りこぼしで書棚が真っ白にならないよう）。
struct DefaultCover: View {
    var body: some View {
        if let image = UIImage(named: "DefaultCover") {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(
                colors: [Color(red: 0.145, green: 0.184, blue: 0.251),
                         Color(red: 0.071, green: 0.094, blue: 0.133)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }
}
