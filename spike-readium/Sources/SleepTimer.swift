import Darwin
import Foundation
import SwiftUI

/// スリープタイマー満了時の動作。
///
/// 「読み上げを停止」だけは必ず行う（タイマーの本体）。スリープ／シャットダウンは
/// その後に続けて実行する追加動作という位置付けなので、列挙は排他の3択にしてある。
enum SleepTimerAction: String, CaseIterable, Identifiable, Codable {
    /// 読み上げを止めるだけ。アプリはそのまま。
    case stopOnly
    /// 読み上げを止めて Mac をスリープさせる。
    case sleepSystem
    /// 読み上げを止めて Mac をシャットダウンする（実行前に猶予のカウントダウンを出す）。
    case shutdown

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .stopOnly: return "読み上げを停止"
        case .sleepSystem: return "Mac をスリープ"
        case .shutdown: return "Mac をシャットダウン"
        }
    }

    var symbolName: String {
        switch self {
        case .stopOnly: return "stop.circle"
        case .sleepSystem: return "moon.zzz"
        case .shutdown: return "power"
        }
    }
}

// MARK: - 電源操作

/// 電源操作の口。テストで実際に Mac を落とさないよう、実装を差し替えられるようにしてある。
protocol SystemPowerControlling: AnyObject {
    /// Mac をスリープさせる。
    func sleepNow() -> Bool
    /// Mac をシャットダウンする。
    func shutdown() -> Bool
}

/// 実際に電源を操作する実装。
///
/// このアプリは App Sandbox を切った ad-hoc 署名の Mac Catalyst アプリなので、
/// 子プロセスを起こせる。ただし Foundation の `Process` は iOS 由来の API 面には無く
/// Catalyst ではコンパイルできないので、libc の `posix_spawn` を直接使う。
///
/// - スリープ: `pmset sleepnow`。管理者権限も追加の許可も要らない。
/// - シャットダウン: `osascript` から System Events に依頼する。`shutdown -h now` は root が要るが、
///   こちらはログイン中のユーザー権限で正規の終了処理（各アプリへの終了問い合わせ）が走る。
///   代わりに**初回だけ「"System Events" を操作する許可」の OS ダイアログ**が出る。
///   ad-hoc 署名はビルドのたびに cdHash が変わるため、開発中はリビルドごとに再許可が要る
///   （配布物は署名が固定なので一度許可すれば持続する）。
final class SystemPower: SystemPowerControlling {

    func sleepNow() -> Bool {
        Self.spawn("/usr/bin/pmset", ["sleepnow"])
    }

    func shutdown() -> Bool {
        Self.spawn("/usr/bin/osascript",
                   ["-e", "tell application \"System Events\" to shut down"])
    }

    /// 子プロセスを起動する（起動できたかだけを返す。終了は待たない）。
    @discardableResult
    static func spawn(_ path: String, _ arguments: [String]) -> Bool {
        var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, nil, nil, &argv, environ)
        if rc != 0 {
            NSLog("[SleepTimer] posix_spawn(%@) failed: %d", path, rc)
            return false
        }
        return true
    }
}

/// 電源操作を実行せず、要求だけを記録する実装（テスト・デバッグ用）。
final class RecordingSystemPower: SystemPowerControlling {
    /// 最後に要求された操作（"sleep" / "shutdown"）。未要求なら nil。
    private(set) var lastRequest: String?

    func sleepNow() -> Bool { lastRequest = "sleep"; return true }
    func shutdown() -> Bool { lastRequest = "shutdown"; return true }
    func reset() { lastRequest = nil }
}

// MARK: - タイマー本体

/// 読み上げのスリープタイマー。
///
/// 「あと何分で止める」という経過時間で指定する（就寝前に使うものなので、時刻を数えさせない）。
/// 満了したら `onExpire`（＝読み上げの停止）を必ず呼び、続けて `action` の追加動作を行う。
///
/// シャットダウンだけは**猶予のカウントダウン**を挟む。寝落ちしていなければ取り消せる。
/// 残り時間は「締め切りの時刻」から毎回引き直す（タイマーの刻みを足し込まない）ので、
/// 発火が遅れたりウィンドウ操作で刻みが飛んでも、止まる時刻はずれない。
@MainActor
final class SleepTimer: ObservableObject {

    /// 選べる時間（分）。カスタム入力もできる。
    static let presetMinutes = [15, 30, 45, 60, 90, 120]

    /// シャットダウン実行前の猶予（秒）。
    static let shutdownGrace: TimeInterval = 30

    /// 稼働中なら締め切り。停止中は nil。
    @Published private(set) var deadline: Date?
    /// 締め切りまでの残り秒。停止中は 0。
    @Published private(set) var remaining: TimeInterval = 0
    /// シャットダウンの猶予カウントダウン中なら、その残り秒。それ以外は nil。
    @Published private(set) var shutdownCountdown: TimeInterval?

    /// 満了時の動作（前回の選択を覚える）。
    @Published var action: SleepTimerAction {
        didSet {
            guard action != oldValue else { return }
            UserDefaults.standard.set(action.rawValue, forKey: Self.actionKey)
        }
    }

    /// 直前に指定した時間（分）。次に開くときの既定値。
    @Published private(set) var lastMinutes: Int

    /// DEBUG ビルドで、実際に電源を操作するか。
    ///
    /// 既定は false＝記録だけ。自動テストが誤ってこの Mac を落とすのを防ぐため。
    /// 本物の挙動を確かめたいときだけメニューの「実際に電源を操作する（デバッグ）」を入れる。
    /// リリースビルドではこのフラグ自体が無く、常に実操作。
    #if DEBUG
    @Published var performsRealPowerAction: Bool = UserDefaults.standard.bool(
        forKey: "sleepTimer.debug.realPower") {
        didSet { UserDefaults.standard.set(performsRealPowerAction, forKey: "sleepTimer.debug.realPower") }
    }
    #endif

    /// 満了時に呼ぶ停止処理（読み上げの停止）。App 側から注入する。
    var onExpire: (() -> Void)?

    /// 電源操作の実装（テストから差し替え可能）。
    let realPower: SystemPowerControlling = SystemPower()
    /// 実操作しないときの記録先（テストの検証用）。
    let recordingPower = RecordingSystemPower()

    private var ticker: Timer?
    private static let actionKey = "sleepTimer.action.v1"
    private static let minutesKey = "sleepTimer.minutes.v1"

    /// 状態が動いた理由を DEBUG ログに残す。タイマーは「誰がいつ触ったか」が
    /// 画面から見えないので、想定外の締め切り変更を後から辿れるようにしておく。
    private func trace(_ what: String) {
        #if DEBUG
        NSLog("[SleepTimer] %@ deadline=%@ shutdownDeadline=%@",
              what,
              deadline.map { String(format: "%.1fs", $0.timeIntervalSinceNow) } ?? "-",
              shutdownDeadline.map { String(format: "%.1fs", $0.timeIntervalSinceNow) } ?? "-")
        #endif
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.actionKey) ?? ""
        action = SleepTimerAction(rawValue: raw) ?? .stopOnly
        let saved = UserDefaults.standard.integer(forKey: Self.minutesKey)
        lastMinutes = saved > 0 ? saved : 30
    }

    /// 稼働中（締め切り待ち、またはシャットダウン猶予中）か。
    var isActive: Bool { deadline != nil || shutdownCountdown != nil }

    /// 残り時間の表示（"m:ss" / 1時間以上なら "h:mm:ss"）。停止中は空文字。
    var remainingText: String {
        guard deadline != nil else { return "" }
        return Self.format(remaining)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    // MARK: 操作

    /// タイマーを開始する（稼働中なら締め切りを引き直す）。
    func start(minutes: Int) {
        let m = max(1, minutes)
        lastMinutes = m
        UserDefaults.standard.set(m, forKey: Self.minutesKey)
        cancelShutdownCountdown()
        deadline = Date().addingTimeInterval(TimeInterval(m * 60))
        remaining = TimeInterval(m * 60)
        startTicker()
        trace("start(\(m)分)")
    }

    /// 締め切りを延長する（稼働していなければ何もしない）。
    func extend(minutes: Int) {
        guard let current = deadline else { return }
        deadline = current.addingTimeInterval(TimeInterval(minutes * 60))
        trace("extend(\(minutes)分)")
        tick()
    }

    /// タイマーを解除する（猶予カウントダウン中ならそれも取り消す）。
    func cancel() {
        trace("cancel")
        deadline = nil
        remaining = 0
        cancelShutdownCountdown()
        stopTicker()
    }

    /// シャットダウンの猶予を取り消す（電源操作は行わない）。
    func cancelShutdownCountdown() {
        guard shutdownCountdown != nil else { return }
        trace("cancelShutdownCountdown")
        shutdownCountdown = nil
        shutdownDeadline = nil
        stopTickerIfIdle()
    }

    /// 猶予を待たずにシャットダウンする。
    func shutdownNow() {
        trace("shutdownNow")
        shutdownCountdown = nil
        shutdownDeadline = nil
        stopTickerIfIdle()
        _ = power.shutdown()
    }

    /// 秒単位で締め切りを引き直す（テスト用。分より短い時間で満了まで通したいとき）。
    func startForTest(seconds: TimeInterval) {
        cancelShutdownCountdown()
        deadline = Date().addingTimeInterval(seconds)
        remaining = seconds
        startTicker()
        trace("startForTest(\(seconds)秒)")
    }

    /// いま満了させる（テスト用。締め切りを現在に引き寄せる）。
    func fireNow() {
        guard deadline != nil else { return }
        trace("fireNow")
        deadline = Date()
        tick()
    }

    // MARK: 刻み

    private var shutdownDeadline: Date?

    private func startTicker() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // メニューを開いている間・スライダーをつまんでいる間も刻ませる（既定モードだと止まる）。
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func stopTickerIfIdle() {
        if deadline == nil && shutdownDeadline == nil { stopTicker() }
    }

    private func tick() {
        let now = Date()
        if let end = deadline {
            remaining = max(0, end.timeIntervalSince(now))
            if remaining <= 0 {
                deadline = nil
                remaining = 0
                expire()
            }
        }
        if let end = shutdownDeadline {
            let left = end.timeIntervalSince(now)
            shutdownCountdown = max(0, left)
            if left <= 0 { shutdownNow() }
        }
        stopTickerIfIdle()
    }

    /// 満了。停止処理を必ず行い、続けて追加動作へ進む。
    private func expire() {
        trace("expire(\(action.rawValue))")
        onExpire?()
        switch action {
        case .stopOnly:
            break
        case .sleepSystem:
            _ = power.sleepNow()
        case .shutdown:
            // 寝落ちしていなければ取り消せるよう、猶予を挟む。
            shutdownDeadline = Date().addingTimeInterval(Self.shutdownGrace)
            shutdownCountdown = Self.shutdownGrace
            startTicker()
            trace("猶予開始")
        }
    }

    /// 実際に呼ぶ電源操作の実装。
    private var power: SystemPowerControlling {
        #if DEBUG
        return performsRealPowerAction ? realPower : recordingPower
        #else
        return realPower
        #endif
    }
}
