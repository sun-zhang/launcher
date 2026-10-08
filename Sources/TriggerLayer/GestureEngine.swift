import Foundation

/// 手势状态机（design.md §3.4，FR-T2/T5/T6）。
/// 纯逻辑、无系统依赖（时钟可注入）：输入缩放增量序列，输出三路回调——
/// `onProgress`（跟手预览）、`onFire`（到达阈值唤起）、`onEnd`（簇结束未触发，预览弹回）。
///
/// 增量语义与 NSEvent.magnification 一致：负 = 捏合收缩，正 = 张开。
/// 关闭方向不经此引擎：面板打开时由面板自身 `magnify(with:)` 公开 API 处理（FR-T3）。
public final class GestureEngine {

    public struct Params {
        /// 捏合唤起阈值（幅度，正数；判定条件 累计 <= -阈值）。
        /// 默认 0.35，可调 0.2–0.6（FR-T2 / SRS §6）。
        public var openThreshold: Double = 0.35
        /// 手势窗口期：超过此时长无新事件，累计清零（SRS §6：600ms）。
        public var window: TimeInterval = 0.6
        /// 触发后引擎内冷却（FR-T6/X1，与 TriggerCoordinator 的 800ms 双保险）。
        public var cooldown: TimeInterval = 0.8
        /// toggle 降级模式：一个爆发簇至少这么多条事件才算手势（过滤零星噪音）。
        public var minBurstTicks = 8
        public init() {}
    }

    /// delta = 增量可解码（阈值判定）；toggle = 不可解码降级（任一爆发簇唤起，不辨方向，A1）。
    public enum Mode: Equatable { case delta, toggle }

    public enum State: Equatable { case idle, gesturing, cooldown }

    public private(set) var params = Params()
    public private(set) var mode: Mode = .delta
    public private(set) var state: State = .idle

    /// 当前爆发簇事件计数（源的结算诊断日志用）。
    public var burstTickCount: Int { burstTicks }

    /// 当前累计缩放量（结算日志调参用；负 = 捏合方向）。
    public var currentAccum: Double { accum }

    /// 设置界面判读用：是否已具备方向识别（delta 模式）。
    public var modeIsDelta: Bool { mode == .delta }

    public var onProgress: ((Double) -> Void)?   // 0...1（相对阈值），仅 delta 模式
    public var onFire: (() -> Void)?
    public var onEnd: (() -> Void)?

    private let now: () -> Date
    private var accum = 0.0
    private var lastEvent: Date?
    private var firedAt: Date?
    private var burstTicks = 0

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func updateParams(_ mutate: (inout Params) -> Void) {
        mutate(&params)
    }

    /// 切换模式（增量可解码性探测结论落地时调用），并清零状态。
    public func setMode(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        reset()
    }

    /// 清零（源启停时调用；不发回调——此时不应存在活动预览）。
    public func reset() {
        accum = 0
        burstTicks = 0
        lastEvent = nil
        firedAt = nil
        state = .idle
    }

    // MARK: - 输入

    /// 新手势事件到达。delta = nil 表示该事件增量不可解码（delta 模式忽略其量值，
    /// 但仍参与簇计数与窗口计时）。
    public func feed(delta: Double?) {
        let t = now()
        advanceWindowIfNeeded(t)

        lastEvent = t
        guard !inCooldown(t) else { return }   // 冷却期：只刷新窗口时间，不累计不计数（X1）

        burstTicks += 1
        guard let delta else {
            state = .gesturing
            return
        }

        switch mode {
        case .toggle:
            state = .gesturing
        case .delta:
            accum += delta
            if accum >= params.openThreshold {
                // 反向（张开）超阈值：漂移保护，清零（面板关闭时张开本就无动作）
                reset()
                onEnd?()
                return
            }
            if accum <= -params.openThreshold {
                reset()
                firedAt = t
                state = .cooldown
                onFire?()
                return
            }
            state = .gesturing
            onProgress?(min(1, max(0, -accum / params.openThreshold)))
        }
    }

    /// 静默期结算：由源的定时器在 window+ε 后调用（也供测试直接驱动）。
    /// - delta 模式：一簇结束未达阈值 → 清零 + onEnd（US-T2 AC：-0.20 松手不触发）；
    /// - toggle 模式：簇闭合，事件数达标 → onFire（面板可见性由源侧守卫）。
    public func settle() {
        let t = now()
        advanceWindowIfNeeded(t)

        if state == .cooldown, !inCooldown(t) {
            state = .idle
        }
    }

    /// 抬手帧（n=0 确定性事件）立即闭簇，不等窗口期：delta 模式未达阈值 →
    /// onEnd 即刻发出（App 层据此做松手提交/弹回判定，无 0.6s 延迟）；
    /// toggle 模式按簇计数判定。与 settle() 的区别：无条件闭簇。
    public func forceSettle() {
        if state == .cooldown, !inCooldown(now()) { state = .idle }
        guard state == .gesturing else { return }

        let shouldFire = (mode == .toggle && burstTicks >= params.minBurstTicks)
        reset()
        if shouldFire {
            firedAt = now()
            state = .cooldown
            onFire?()
        } else {
            onEnd?()
        }
    }

    /// 中止当前簇累计（横扫确认等场景）：清累计与簇计数，不动冷却——
    /// 此前若有真实触发，X1 冷却连击保护照常生效。
    public func abort() {
        accum = 0
        burstTicks = 0
        lastEvent = nil
        if state == .gesturing { state = .idle }
    }

    // MARK: - 内部

    /// 窗口期已过：上一簇收尾（清零 + onEnd），回落 idle。
    private func advanceWindowIfNeeded(_ t: Date) {
        if state == .cooldown, !inCooldown(t) { state = .idle }
        guard state == .gesturing, let lastEvent,
              t.timeIntervalSince(lastEvent) > params.window else { return }

        let shouldFire = (mode == .toggle && burstTicks >= params.minBurstTicks)
        reset()
        if shouldFire {
            firedAt = t
            state = .cooldown
            onFire?()
        } else {
            onEnd?()
        }
    }

    private func inCooldown(_ t: Date) -> Bool {
        guard let firedAt else { return false }
        return t.timeIntervalSince(firedAt) < params.cooldown
    }
}
