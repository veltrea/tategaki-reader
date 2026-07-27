import SwiftUI
import UniformTypeIdentifiers

/// Kindle 風の書棚。カバーをグリッド表示し、タップで開く。ソート・フィルタ対応。
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
    @State private var field: FilterField = .all
    @State private var displayMode: DisplayMode = .grid
    @State private var yomiEditBook: BookEntry?
    @State private var yomiDraft = ""
    /// 設定シート（書棚からも開ける。本を開いていないので表示反映は次に本を開いたとき）。
    @State private var showSettings = false

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 24)]

    /// フィルタのみ適用（ソートなし）。
    private var filteredBooks: [BookEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return model.books }
        func hit(_ s: String) -> Bool { s.lowercased().contains(q) }
        return model.books.filter { b in
            switch field {
            case .all: return hit(b.title) || hit(b.authorText) || hit(b.publisherText)
            case .title: return hit(b.title)
            case .author: return hit(b.authorText)
            case .publisher: return hit(b.publisherText)
            }
        }
    }

    /// フィルタ→ソートを適用した表示用リスト（グリッド用）。
    private var displayed: [BookEntry] {
        var list = filteredBooks
        switch sort {
        case .recent: break // model.books は lastOpenedAt 降順で保持済み
        case .title: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author: list.sort { $0.authorText.localizedStandardCompare($1.authorText) == .orderedAscending }
        case .publisher: list.sort { $0.publisherText.localizedStandardCompare($1.publisherText) == .orderedAscending }
        }
        return list
    }

    // MARK: 作者別 五十音インデックス

    /// セクション見出しの並び順: あ〜わ → A〜Z → # → 他（漢字で読み無し）→ —（作者なし）。
    private static let sectionOrder: [String] =
        ["あ","か","さ","た","な","は","ま","や","ら","わ"]
        + (65...90).map { String(UnicodeScalar($0)!) }
        + ["#", "他", "—"]

    /// かな1文字→行の頭文字（あ/か/…/わ）。かなでなければ nil。
    private static func kanaRow(_ ch: Character) -> String? {
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
    private static func sectionKey(_ book: BookEntry) -> String {
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

    /// フィルタ後の本を見出しでグループ化し、順序どおりに並べたセクション配列。
    private var authorSections: [(key: String, books: [BookEntry])] {
        let groups = Dictionary(grouping: filteredBooks) { Self.sectionKey($0) }
        return groups.map { (key: $0.key, books: $0.value.sorted { a, b in
            let c = a.authorSortKey.localizedStandardCompare(b.authorSortKey)
            if c != .orderedSame { return c == .orderedAscending }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }) }
        .sorted {
            (Self.sectionOrder.firstIndex(of: $0.key) ?? 999)
                < (Self.sectionOrder.firstIndex(of: $1.key) ?? 999)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.books.isEmpty {
                emptyState
            } else if filteredBooks.isEmpty {
                noMatchState
            } else if displayMode == .grid {
                gridView
            } else {
                authorIndexView
            }
        }
        // 書棚全体の地。最後に読んだ本のカバーを弱くぼかして敷く（スクロールしても動かない）。
        .background { ShelfBackdrop(image: backdropBook.flatMap { model.coverImage(for: $0) }) }
        .task { model.backfillMetadataIfNeeded() }
        #if DEBUG
        .task {
            // DEBUG 限定: テストバスから実アラート（作者の読み）を開けるようフックを登録。
            TestBus.shared.openYomiEditor = { book in
                yomiDraft = book.resolvedAuthorReading ?? ""
                yomiEditBook = book
            }
        }
        #endif
        .sheet(isPresented: $showSettings) {
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
    }

    /// 最後に読んだ（＝最後に開いた）1冊。段の主役であり、書棚の地に敷くカバーの持ち主。
    /// 絞り込みに左右されない（地が検索のたびに入れ替わると落ち着かないため）。
    private var backdropBook: BookEntry? {
        model.books.max(by: { $0.lastOpenedAt < $1.lastOpenedAt })
    }

    /// 「続きを読む」段に出す本。
    /// 絞り込み中は、その結果に含まれるときだけ出す（無関係な本が段に残らないように）。
    private var continueBook: BookEntry? {
        guard let latest = backdropBook,
              filteredBooks.contains(where: { $0.id == latest.id })
        else { return nil }
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
                    ForEach(displayed) { book in cell(book) }
                }
                .padding(24)
            }
        }
    }

    /// 作者別の五十音インデックス表示（見出しをピン留め）。
    private var authorIndexView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                ForEach(authorSections, id: \.key) { section in
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

    /// カバー1枚（タップで開く・右クリックで削除）。グリッド/インデックス共用。
    @ViewBuilder
    private func cell(_ book: BookEntry) -> some View {
        BookCell(book: book, image: model.coverImage(for: book))
            .onTapGesture { model.open(url: book.fileURL) }
            .contextMenu {
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
                Text("書棚")
                    .font(.title2.bold())
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .help("設定")
                Button {
                    model.requestOpenPanel = true
                } label: {
                    Label("本を追加", systemImage: "plus")
                }
                .keyboardShortcut("o")
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

    private var noMatchState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("該当する本がありません")
                .font(.headline)
            Text("フィルタ条件を変えてください")
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
            Text("「本を追加」または EPUB をウィンドウにドラッグ＆ドロップ")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
