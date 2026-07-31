import Foundation
import SwiftUI

/// 自動ページ送りの相手（＝いま開いているリーダー）。
///
/// タイマー側が ReaderModel を直接掴むと、テストから終端やページ送りを差し替えられない。
/// 必要なのは「読み上げ中か」「本のどこにいるか」「1ページ送る」の3つだけなので、
/// その3つに絞った口を通す。
@MainActor
protocol AutoPagerTarget: AnyObject {
    /// 読み上げ中か。読み上げは自分でページを送るので、その間の自動送りは見送る。
    var isSpeakingNow: Bool { get }
    /// 本全体での現在位置(0...1)。終端の検出に使う。
    var pageProgression: Double { get }
    /// 1ページ進める。手動送りとしては数えない（＝自動送りの間隔を数え直さない）。
    func advancePageAutomatically() async
    /// 状態の告知（下バーの status 欄に出す）。
    func noteAutoPagerStatus(_ text: String)
}

/// 自動ページ送り。指定した秒数ごとに1ページ進める。
///
/// 締め切りの持ち方は `SleepTimer` と同じで、「次に送る時刻」から毎回残りを引き直す
/// （刻みを足し込まない）。0.5 秒刻みの発火が遅れても、送る間隔は指定どおりに保たれる。
///
/// 止める条件は3つ:
///   - 読み手が止めたとき
///   - 本の終わりに着いたとき（送っても位置が動かない ＝ これ以上進めない）
///   - 本を閉じて書棚へ戻ったとき（送る相手がいなくなる）
///
/// 読み上げ中は**止めずに見送る**。読み上げは文の切れ目で自分でページを送るので、
/// ここからも送ると1ページ飛ばしになる。読み上げが終われば自動送りはそのまま続く。
@MainActor
final class AutoPager: ObservableObject {

    /// 選べる間隔（秒）。カスタム入力もできる。
    static let presetSeconds = [10, 15, 20, 30, 45, 60, 90]

    /// 終端と見なす位置。ここより手前で位置が動かなかった場合は、
    /// 描画が間に合っていないだけとみなして止めない。
    static let endThreshold = 0.95

    /// 稼働中なら次に送る時刻。停止中は nil。
    @Published private(set) var deadline: Date?
    /// 次に送るまでの残り秒。停止中は 0。
    @Published private(set) var remaining: TimeInterval = 0
    /// 読み上げ中で送るのを見送っているか（表示を「待機中」にするため）。
    @Published private(set) var isHolding = false

    /// 直前に指定した間隔（秒）。次に開くときの既定値。
    @Published private(set) var seconds: Int

    /// 送る相手を返す（開いている本が変わるので、参照ではなく毎回引き直す）。
    var targetProvider: (() -> AutoPagerTarget?)?

    private var ticker: Timer?
    /// ページ送りの実行中タスク（送り終わる前に次の刻みが来ても重ねない）。
    private var advanceTask: Task<Void, Never>?
    private static let secondsKey = "autoPager.seconds.v1"

    init() {
        let saved = UserDefaults.standard.integer(forKey: Self.secondsKey)
        seconds = saved > 0 ? saved : 30
    }

    /// 稼働中か。
    var isRunning: Bool { deadline != nil }

    /// 残り時間の表示（"12" のような整数秒）。停止中は空文字。
    var remainingText: String {
        guard isRunning else { return "" }
        return String(max(0, Int(remaining.rounded(.up))))
    }

    /// 状態が動いた理由を DEBUG ログに残す（`SleepTimer` と同じ理由）。
    private func trace(_ what: String) {
        #if DEBUG
        NSLog("[AutoPager] %@ interval=%ds deadline=%@ holding=%@",
              what, seconds,
              deadline.map { String(format: "%.1fs", $0.timeIntervalSinceNow) } ?? "-",
              isHolding ? "yes" : "no")
        #endif
    }

    // MARK: 操作

    /// 自動送りを開始する（稼働中なら間隔を差し替えて数え直す）。
    func start(seconds newValue: Int) {
        let s = max(1, newValue)
        seconds = s
        UserDefaults.standard.set(s, forKey: Self.secondsKey)
        restartCountdown()
        startTicker()
        trace("start(\(s)秒)")
        // 下バーの status は前の告知（「本の終わりです」等）が残るので、始めたことを上書きしておく。
        targetProvider?()?.noteAutoPagerStatus(
            String(format: String(localized: "自動ページ送り: %lld秒ごと"), s))
    }

    /// 直前の間隔で開始する（ボタンの単純なトグル用）。
    func start() { start(seconds: seconds) }

    /// 自動送りを止める。
    func stop() {
        guard isRunning else { return }
        trace("stop")
        finish()
        targetProvider?()?.noteAutoPagerStatus(String(localized: "自動ページ送りを停止"))
    }

    /// 開始と停止を往復する。
    func toggle() {
        if isRunning { stop() } else { start() }
    }

    /// 手動でページを送った／位置を飛ばしたときの数え直し。
    ///
    /// 自分で送った直後にすぐ自動送りが来ると2ページ飛ぶので、間隔を頭から数え直す。
    func noteManualTurn() {
        guard isRunning else { return }
        restartCountdown()
    }

    /// いま送る（テスト用。締め切りを現在に引き寄せる）。
    func fireNow() {
        guard isRunning else { return }
        trace("fireNow")
        deadline = Date()
        tick()
    }

    // MARK: 刻み

    private func restartCountdown() {
        deadline = Date().addingTimeInterval(TimeInterval(seconds))
        remaining = TimeInterval(seconds)
        isHolding = false
    }

    private func finish() {
        deadline = nil
        remaining = 0
        isHolding = false
        advanceTask?.cancel()
        advanceTask = nil
        stopTicker()
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // メニューを開いている間も刻ませる（既定モードだと止まる）。
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let end = deadline else { return }
        // 送る相手がいない（書棚へ戻った）なら止める。
        guard let target = targetProvider?() else {
            trace("stop(本を閉じた)")
            finish()
            return
        }
        // 読み上げ中は見送る。締め切りを先送りするので、読み上げが終わったところから
        // まる1間隔ぶん数え直す（読み上げ終了の直後にいきなり送られない）。
        if target.isSpeakingNow {
            isHolding = true
            deadline = Date().addingTimeInterval(TimeInterval(seconds))
            remaining = TimeInterval(seconds)
            return
        }
        isHolding = false
        remaining = max(0, end.timeIntervalSinceNow)
        guard remaining <= 0 else { return }
        restartCountdown()
        advance(target)
    }

    /// 1ページ送り、送れたかを位置で確かめる。
    private func advance(_ target: AutoPagerTarget) {
        guard advanceTask == nil else { return }   // 前の送りがまだ終わっていない
        advanceTask = Task { @MainActor [weak self] in
            let before = target.pageProgression
            await target.advancePageAutomatically()
            // 位置(fraction)は JS から relocate で遅れて届く。送った直後はまだ前の値なので待つ。
            try? await Task.sleep(nanoseconds: 700_000_000)
            // 取り消されたときは finish() が後始末済みなので、ここでは何もしない。
            guard let self, !Task.isCancelled else { return }
            self.advanceTask = nil
            guard self.isRunning else { return }
            // 送っても位置が動かない＝これ以上進めない。終端付近に限って止める
            //（途中で動かないのは描画待ちのことがあるので、そこでは止めない）。
            if target.pageProgression == before, before >= Self.endThreshold {
                self.trace("stop(本の終わり)")
                self.finish()
                target.noteAutoPagerStatus(String(localized: "本の終わりです（自動ページ送りを停止）"))
            }
        }
    }
}
