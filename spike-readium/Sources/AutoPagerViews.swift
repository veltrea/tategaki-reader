import SwiftUI

/// 自動ページ送りの操作項目（メニューの中身）。
///
/// リーダー下部の再生バーと、メニューバーの「移動 > 自動ページ送り」の**両方**が使う。
/// Section ではなく Divider で区切るのは、メニューバー（Commands）側では Section が
/// 見出し付きの塊として組まれないため（スリープタイマーと同じ理由）。
struct AutoPagerMenuItems: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pager: AutoPager
    /// 押せる状態か。本を開いていないときは送る相手がいないので淡色にする。
    /// Group や Menu への .disabled は分岐と Divider が混ざったメニューでは効かないので、
    /// 項目ごとに付ける（ExportCommands で実測済み）。
    var enabled: Bool = true

    var body: some View {
        if pager.isRunning {
            // 稼働中の状態。押せない項目として見せる（メニューを開けば分かる）。
            Text(pager.isHolding
                 ? String(localized: "読み上げ中は送りません")
                 : String(format: String(localized: "あと %@ 秒で次のページ"), pager.remainingText))
            Button("自動ページ送りを止める") { pager.stop() }
            Divider()
        }
        ForEach(AutoPager.presetSeconds, id: \.self) { s in
            Button(String(format: String(localized: "%lld秒ごとに送る"), s)) {
                pager.start(seconds: s)
            }
            .disabled(!enabled)
        }
        Button("間隔を指定…") { model.showAutoPagerCustom = true }
            .disabled(!enabled)
    }
}

/// リーダー下部の再生バーに置く自動ページ送りのボタン。
///
/// 稼働中は次に送るまでの秒数を出す（アイコンだけだと動いているのか分からないため）。
struct AutoPagerButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pager: AutoPager

    var body: some View {
        Menu {
            AutoPagerMenuItems(model: model, pager: pager)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: pager.isRunning ? "forward.circle.fill" : "forward.circle")
                    .font(.system(size: 30))
                // 残り秒の枠は停止中も確保しておく。出たり消えたりで幅が変わると、
                // 左隣のボタンまで動いてしまう（スリープタイマーのボタンと同じ理由）。
                Text(pager.isRunning && pager.isHolding ? "—" : pager.remainingText)
                    .font(.callout.monospacedDigit())
                    // 3桁（カスタムで長い間隔を入れたとき）まで欠けない幅。
                    .frame(width: 34, alignment: .leading)
            }
            .foregroundStyle(pager.isRunning ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("自動ページ送り")
        // ラベルを与えないと SF Symbol 名から読み上げられる。自動テストもこの名前で引く。
        .accessibilityLabel("自動ページ送り")
        .accessibilityValue(pager.isRunning
                            ? (pager.isHolding
                               ? String(localized: "読み上げ中は送りません")
                               : String(format: String(localized: "あと %@ 秒"), pager.remainingText))
                            : String(localized: "停止中"))
    }
}
