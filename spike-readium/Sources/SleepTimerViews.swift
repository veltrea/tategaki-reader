import SwiftUI

/// スリープタイマーの操作項目（メニューの中身）。
///
/// リーダー下部の月アイコンと、メニューバーの「読み上げ > スリープタイマー」の**両方**が
/// これを使う。Section ではなく Divider で区切っているのは、メニューバー（Commands）側では
/// Section が見出し付きの塊として組まれないため。見え方を片方に合わせてある。
struct SleepTimerMenuItems: View {
    @ObservedObject var model: AppModel
    @ObservedObject var timer: SleepTimer

    var body: some View {
        if timer.isActive {
            // 稼働中の残り。押せない項目として状態だけ見せる（メニューを開けば分かる）。
            Text(String(format: String(localized: "残り %@"), timer.remainingText))
            Button("タイマーを解除") { timer.cancel() }
            Divider()
        }
        ForEach(SleepTimer.presetMinutes, id: \.self) { m in
            Button(String(format: String(localized: "%lld分後に停止"), m)) {
                timer.start(minutes: m)
            }
        }
        Button("時間を指定…") { model.showSleepTimerCustom = true }
        Divider()
        // 入れ子のメニューにしてあるのは、インラインの Picker だとメニューバー側で
        // 見出し（「満了時の動作」）が落ち、3つの選択肢が何の選択肢なのか読めなくなるため（実測）。
        Menu("満了時の動作") {
            Picker("満了時の動作", selection: $timer.action) {
                ForEach(SleepTimerAction.allCases) { a in
                    Label(a.label, systemImage: a.symbolName).tag(a)
                }
            }
            .pickerStyle(.inline)
        }
        #if DEBUG
        Divider()
        // 自動テストがこの Mac を落とさないよう、DEBUG では既定で電源操作を「記録だけ」にしてある。
        // 本物の挙動を確かめるときだけ入れる。
        Toggle("実際に電源を操作する（デバッグ）", isOn: $timer.performsRealPowerAction)
        #endif
    }
}

/// リーダー下部の再生バーに置くスリープタイマーのボタン。
///
/// 稼働中は残り時間を数字で出す（アイコンだけだと「仕掛かっているか」が分からないため）。
struct SleepTimerButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var timer: SleepTimer

    var body: some View {
        Menu {
            SleepTimerMenuItems(model: model, timer: timer)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: timer.isActive ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 30))
                // 残り時間の枠は稼働していなくても確保しておく。出たり消えたりで幅が変わると、
                // 左隣の再生・停止ボタンまで動いてしまう（この行はボタンの位置を固定する設計。
                // status を overlay にしてあるのも同じ理由）。
                Text(timer.remainingText)
                    .font(.callout.monospacedDigit())
                    .frame(width: 60, alignment: .leading)
            }
            .foregroundStyle(timer.isActive ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("スリープタイマー")
        // ラベルを与えないと SF Symbol 名から拾った「うたた寝」が読み上げられる（AX で実測）。
        // 自動テストもこの名前で引くので、意味の通る名前を明示する。
        .accessibilityLabel("スリープタイマー")
        .accessibilityValue(timer.isActive
                            ? String(format: String(localized: "残り %@"), timer.remainingText)
                            : String(localized: "停止中"))
    }
}

/// シャットダウン前の猶予を告げる帯。取り消すか、待たずに実行するかを選べる。
///
/// 画面のどこにいても（書棚に戻っていても）見えるよう RootView に重ねる。
struct SleepTimerShutdownBanner: View {
    @ObservedObject var timer: SleepTimer

    var body: some View {
        if let left = timer.shutdownCountdown {
            VStack(spacing: 12) {
                Label(
                    String(format: String(localized: "%lld秒後に Mac をシャットダウンします"),
                           max(0, Int(left.rounded(.up)))),
                    systemImage: "power")
                    .font(.title3.weight(.semibold))
                Text("スリープタイマーが満了し、読み上げを停止しました。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button("取り消す") { timer.cancelShutdownCountdown() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.borderedProminent)
                    Button("今すぐシャットダウン") { timer.shutdownNow() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16))
            // ShapeStyle の .separator は Catalyst 17 以降。配備先が 16 なので UIColor から作る。
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color(uiColor: .separator)))
            .shadow(radius: 20)
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(Color.black.opacity(0.25).ignoresSafeArea())
            .transition(.opacity)
        }
    }
}
