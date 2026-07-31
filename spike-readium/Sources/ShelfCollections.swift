import Foundation

// MARK: - 分類（コレクション）

/// 書棚の分類ひとつ。`parentID` で入れ子にできる（「小説 > SF」のような形）。
///
/// 本の側に「どの分類に入っているか」を持たせる（`BookEntry.collectionIDs`）。分類の側に
/// 本の一覧を持たせない理由は、本を書棚から削除したときに分類側の掃除が要らないこと、
/// そして**1冊が複数の分類に入れる**（作者別と叢書別の両方に置く、など）ようにするため。
struct ShelfCollection: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    /// 親。nil なら最上位。
    var parentID: UUID?
    /// 同じ親の中での並び順。
    var order: Int

    init(id: UUID = UUID(), name: String, parentID: UUID? = nil, order: Int = 0) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.order = order
    }
}

/// 書棚に何を出すか。サイドバーの選択そのもの。
enum ShelfScope: Hashable, Codable {
    /// すべての本。
    case all
    /// お気に入りだけ。
    case favorites
    /// どの分類にも入っていない本。
    case unfiled
    /// ある分類（**その子孫の分類に入っている本も含む**）。
    case collection(UUID)

    /// 状態の保存・テストバス用の文字列表現。
    var storageString: String {
        switch self {
        case .all: return "all"
        case .favorites: return "favorites"
        case .unfiled: return "unfiled"
        case .collection(let id): return "collection:\(id.uuidString)"
        }
    }

    init(storageString raw: String) {
        switch raw {
        case "favorites": self = .favorites
        case "unfiled": self = .unfiled
        default:
            if raw.hasPrefix("collection:"),
               let id = UUID(uuidString: String(raw.dropFirst("collection:".count))) {
                self = .collection(id)
            } else {
                self = .all
            }
        }
    }
}

// MARK: - 木としての操作（純ロジック）

/// 分類の入れ子をたどる操作。SwiftUI にも AppModel にも依らないので単体で検証できる。
///
/// 壊れたデータ（親子が輪になっている等）でも無限に回らないよう、たどる側は必ず
/// 訪問済みを控える。読み込んだ JSON を信用しない。
enum CollectionTree {
    /// 親 → 子の対応表。何度もたどるときはこれを1回作って使い回す。
    static func childMap(_ all: [ShelfCollection]) -> [UUID?: [ShelfCollection]] {
        var map: [UUID?: [ShelfCollection]] = [:]
        for c in all { map[c.parentID, default: []].append(c) }
        for key in map.keys {
            map[key]?.sort {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        return map
    }

    static func children(of parent: UUID?, in all: [ShelfCollection]) -> [ShelfCollection] {
        childMap(all)[parent] ?? []
    }

    /// `id` とその子孫すべての ID。分類を選んだときに「下の階層の本も出す」ために使う。
    static func selfAndDescendants(of id: UUID, in all: [ShelfCollection]) -> Set<UUID> {
        let map = childMap(all)
        var out: Set<UUID> = []
        var stack = [id]
        while let current = stack.popLast() {
            guard out.insert(current).inserted else { continue }   // 輪になっていても止まる
            for child in map[current] ?? [] { stack.append(child.id) }
        }
        return out
    }

    /// `candidate` が `ancestor` の子孫か（自分自身も真とする）。
    /// 分類を別の分類の下へ移すとき、自分の子孫を親に選ばせないために使う。
    static func isDescendant(_ candidate: UUID, of ancestor: UUID, in all: [ShelfCollection]) -> Bool {
        selfAndDescendants(of: ancestor, in: all).contains(candidate)
    }

    /// サイドバーに縦に並べるための平らな列。`expanded` に無い分類の下は畳んで出さない。
    struct Row: Identifiable, Equatable {
        var collection: ShelfCollection
        var depth: Int
        var hasChildren: Bool
        var id: UUID { collection.id }
    }

    static func rows(_ all: [ShelfCollection], expanded: Set<UUID>) -> [Row] {
        let map = childMap(all)
        var out: [Row] = []
        var visited: Set<UUID> = []

        func walk(_ parent: UUID?, depth: Int) {
            for c in map[parent] ?? [] {
                guard visited.insert(c.id).inserted else { continue }
                let kids = map[c.id] ?? []
                out.append(Row(collection: c, depth: depth, hasChildren: !kids.isEmpty))
                if expanded.contains(c.id) { walk(c.id, depth: depth + 1) }
            }
        }
        walk(nil, depth: 0)
        return out
    }

    /// 「小説 / SF / 海外」のような、上からの道筋。メニューで分類を選ばせるときに使う。
    static func pathName(of id: UUID, in all: [ShelfCollection]) -> String {
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var names: [String] = []
        var current: UUID? = id
        var guardCount = 0
        while let cid = current, let c = byID[cid], guardCount < all.count + 1 {
            names.append(c.name)
            current = c.parentID
            guardCount += 1
        }
        return names.reversed().joined(separator: " / ")
    }

    /// 分類を消すときに、子を親へ繰り上げた姿を返す（階層に穴を空けない）。
    static func removing(_ id: UUID, from all: [ShelfCollection]) -> [ShelfCollection] {
        guard let target = all.first(where: { $0.id == id }) else { return all }
        return all.compactMap { c in
            if c.id == id { return nil }
            guard c.parentID == id else { return c }
            var moved = c
            moved.parentID = target.parentID
            return moved
        }
    }

    /// 同じ親の中で次に使う並び順。
    static func nextOrder(under parent: UUID?, in all: [ShelfCollection]) -> Int {
        (all.filter { $0.parentID == parent }.map(\.order).max() ?? -1) + 1
    }
}
