import SwiftUI

// MARK: - メニューバーの「書棚」

/// メニューバーから書棚を切り替える／管理する。
///
/// 書棚の名前を画面（サイドバーやヘッダー）に出さないのは意図的。人へ見せるための書棚に
/// 切り替えているときに「スクリーンショット用」といった名前が写ると、隠したいことをかえって
/// 説明してしまう。いま何を見ているかはこのメニューのチェックで確かめる。
struct ShelfProfileCommands: View {
    @ObservedObject var model: AppModel

    // 宣言と逆の順でメニューに並ぶ（同じ挿入位置へ後から入ったものが上へ来る。実測）。
    // 画面に出る並びを「書棚を切り替える → 書棚を管理…」にしたいので、ここでは逆に書く。
    var body: some View {
        Button("書棚を管理…") { model.showProfileManager = true }
        Menu("書棚を切り替える") {
            ForEach(model.profiles) { profile in
                // Button + チェックの自作ではなく Toggle にする（メニュー項目の左に正規の
                // チェックマークが付き、いま見ている書棚が一目で分かる）。
                Toggle(isOn: Binding(
                    get: { profile.id == model.currentProfileID },
                    set: { if $0 { model.switchProfile(to: profile.id) } }
                )) {
                    // 利用者が付けた名前なので、ローカライズキーとして解釈させない。
                    Text(verbatim: profile.name)
                }
            }
        }
    }
}

// MARK: - 書棚の管理シート

/// 書棚（プロファイル）を作る・名前を変える・切り替える・消す。
///
/// 設定シートに間借りしないのは、あちらが「保存で確定・閉じるで破棄」の作りで、こちらは
/// 切り替えが即時（押した瞬間に蔵書が入れ替わる）だから。同じ枠に混ぜると、どの操作が
/// いつ効くのか分からなくなる。
struct ShelfProfileSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    /// 名前を変える対象（アラートで受ける）。
    @State private var renaming: ShelfProfile?
    @State private var renameDraft = ""
    /// 消す対象（確認してから消す）。
    @State private var deleting: ShelfProfile?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(model.profiles) { profile in
                        row(profile)
                    }
                } header: {
                    Text("書棚")
                } footer: {
                    Text("蔵書の一覧・分類・お気に入り・読書位置・しおり・表紙・読み辞書・全書籍共通CSSは書棚ごとに分かれます。読み上げエンジンの接続先や表示の既定値は共通です。EPUBファイル自体は書棚を消しても消えません。")
                }

                Section("新しい書棚") {
                    HStack {
                        TextField("名前", text: $newName)
                            .onSubmit(addProfile)
                        Button("追加", action: addProfile)
                            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("中身は空で始まります（同梱サンプルも入りません）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("書棚の管理")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        // 書棚が数個なら余白が余るだけなので、内容に近い高さにしておく（増えれば Form が巻く）。
        .modifier(FittedSheetSizing(displaySize: CGSize(width: 560, height: 400)))
        .alert("書棚の名前", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("名前", text: $renameDraft)
            Button("保存") {
                if let target = renaming { model.renameProfile(target.id, to: renameDraft) }
                renaming = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("キャンセル", role: .cancel) { renaming = nil }
        }
        .alert("この書棚を消しますか？", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        )) {
            Button("消す", role: .destructive) {
                if let target = deleting { model.removeProfile(target.id) }
                deleting = nil
            }
            Button("キャンセル", role: .cancel) { deleting = nil }
        } message: {
            Text("登録した本の一覧・分類・読書位置が見えなくなります（EPUBファイルは消えません）。取り違えたときに戻せるよう、データ自体は消さずに残します。")
        }
    }

    @ViewBuilder
    private func row(_ profile: ShelfProfile) -> some View {
        let isCurrent = profile.id == model.currentProfileID
        HStack(spacing: 10) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: profile.name)
                if isCurrent {
                    Text("表示中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isCurrent {
                Button("切り替える") { model.switchProfile(to: profile.id) }
                    .buttonStyle(.borderless)
            }
            Menu {
                Button("名前を変える…") {
                    renameDraft = profile.name
                    renaming = profile
                }
                if model.canRemoveProfile(profile.id) {
                    Button("消す…", role: .destructive) { deleting = profile }
                } else {
                    // 「なぜ消せないのか」が分かるように、淡色の項目として残す。
                    Button(profile.isPrimary ? "最初からある書棚は消せません" : "表示中の書棚は消せません") { }
                        .disabled(true)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func addProfile() {
        guard let created = model.addProfile(name: newName) else { return }
        newName = ""
        // 作ってすぐ移らない。移るかどうかは利用者が決める（作業中の書棚から勝手に離れない）。
        _ = created
    }
}
