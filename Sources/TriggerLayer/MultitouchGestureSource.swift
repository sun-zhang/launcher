import Core
import Foundation
import MultitouchBridge

/// 全局四指捏合手势源（FR-T2/T5/T9，design.md §3.3 的 MultitouchSupport 路线）。
///
/// 2026-10-05 技术决策（真机实证链，详见 spike/MTFrameSpike.swift 与
/// spike/logs/mt-human.log）：Event Tap 可见层（29/30 事件）在 macOS 26 上
/// **不携带全局可靠的方向增量**（type29 纯元数据、type30 依赖前台应用合成），
/// 该路线已退役。现役方案与 MiddleClick / everypinch 等开源一致：
///
/// - 私有 `MultitouchSupport.framework` 的**设备级触点帧流**：
///   `MTDeviceCreateList` → `MTRegisterContactFrameCallback` → `MTDeviceStart(0)`；
/// - 每帧回调给出 `MTTouch[]`（归一化坐标）+ `numTouches`，与前台应用无关；
/// - 方量由 `TouchPinchTracker` 从平均两两指距导出（等效系统 magnification，
///   真机四指捏合簇累计 −0.48…−0.81），**≥4 指门控**天然区分双指/三指捏合；
/// - 引擎（阈值/窗口/冷却/预览）与坐标语义完全复用，`-0.35` 阈值直接适用。
///
/// 只读订阅、零事件拦截（比 tap 透传更彻底地满足 FR-T9「只监听」）；权限
/// 模型与 Event Tap 相同（未授权时行为差异：回调静默无帧——本源无法从
/// 静默区分「未授权」与「没人在碰触控板」，授权入口保留在菜单栏兜底）。
///
/// 生命周期：回调在框架私有线程触发，拷贝坐标数组后跳主线程推进状态机
/// （与旧 Event Tap 源相同的串行化策略）。
@MainActor
public final class MultitouchGestureSource: TriggerSource {

    public let kind: SourceKind = .gesture
    public private(set) var isHealthy = false
    /// 健康/状态变化回调（App 层刷新菜单栏状态灯）。
    public var onStateChanged: (() -> Void)?
    /// 跟手预览进度（0…1，仅捏合方向；App 层在面板未开时转发，FR-T5）。
    public var onProgress: ((Double) -> Void)?
    /// 一簇手势结束且未触发（预览弹回或松手提交，由 App 层判读）。
    public var onGestureEnd: (() -> Void)?
    /// 横扫抑制等硬中止（App 层撤预览；不走松手提交——被抑制的簇不得收尾为打开）。
    public var onGestureAbort: (() -> Void)?

    /// 面板可见性（App 注入）：面板打开期间增量改喂张开关闭累计器而非唤起引擎
    /// （FR-T3——面板非激活，公开 API `magnify(with:)` 收不到手势事件）。
    public var isPanelVisible: () -> Bool = { false }
    /// 已认领的捏合簇在途（App 层喂手势闸门）：本簇自首个非空增量起已被启动器
    /// 占用（稳定 ≥minFingers 指的捏合/张开），至抬手才清——面板提前收起时
    /// 簇余量仍被拦截，不漏给前台应用（GestureEventShield 语义见其文档）。
    public private(set) var isBurstClaimed = false
    /// 面板打开期间四指张开达阈值（+0.30）——App 层调用 closePanel(source: .pinchOut)。
    public var onSpreadClose: (() -> Void)?
    /// 面板打开期间张开进度（0...1，相对关闭阈值）——App 层转发跟手关闭预览。
    public var onCloseProgress: ((Double) -> Void)?
    /// 张开簇结束且未达关闭阈值（含横扫抑制）——App 层撤跟手关闭预览。
    public var onCloseProgressEnd: (() -> Void)?

    public let engine: GestureEngine
    private let tracker = TouchPinchTracker()   // minFingers 等由 applyTuning 下发
    private var closeAccum = PinchCloseAccumulator()

    /// 兼容面：MT 路线方向识别恒可用（无需字段标定）——状态灯判据简化。
    public var isDeltaFieldConfigured: Bool { isHealthy }

    private let settings: SettingsStore
    private let coordinator: () -> TriggerCoordinator

    // MultitouchSupport 运行时句柄（stop() 逆序释放）
    private var frameworkHandle: UnsafeMutableRawPointer?
    private var devices: [MTDeviceRef] = []
    private var createListFn: (@convention(c) () -> UnsafeMutableRawPointer?)?
    private var registerFn: MTRegisterContactFrameCallbackFn?
    private var startFn: MTDeviceStartFn?
    private var stopFn: MTDeviceStopFn?
    private var releaseFn: MTDeviceReleaseFn?

    private var settleWork: DispatchWorkItem?
    private var framesLogged = 0
    /// 回调层诊断汇总定时器（区分「无回调」/「有帧未达 4 指」）。
    private var diagTimer: Timer?
    private var lastDiagFrames = 0

    public init(settings: SettingsStore, coordinator: @escaping () -> TriggerCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
        let engine = GestureEngine()
        self.engine = engine
        applyTuning()

        engine.onProgress = { [weak self] progress in self?.onProgress?(progress) }
        engine.onEnd = { [weak self] in self?.onGestureEnd?() }
        engine.onFire = { [weak self] in
            guard let self else { return }
            _ = self.coordinator().handleTrigger(source: .gesture, action: .open)
        }
        // 横扫确认（尤其慢速斜扫由累计门兜底时）：立即清引擎累计并撤双向预览，
        /// 把泄漏闪现压到最短。硬中止走 onGestureAbort——不参与松手提交。
        tracker.onSwipeConfirmed = { [weak self] in
            guard let self else { return }
            self.engine.abort()
            self.onGestureAbort?()
            self.onCloseProgressEnd?()
            Log.trigger.info("横扫抑制确认——清引擎累计并撤预览")
        }
    }

    // MARK: - 生命周期

    @discardableResult
    public func start() -> Bool {
        stop()
        applyTuning()

        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            Log.trigger.error("MultitouchSupport dlopen 失败（\(String(cString: dlerror()), privacy: .public)）")
            return fail()
        }
        frameworkHandle = handle
        guard let pCreate = dlsym(handle, "MTDeviceCreateList"),
              let pRegister = dlsym(handle, "MTRegisterContactFrameCallback"),
              let pStart = dlsym(handle, "MTDeviceStart"),
              let pStop = dlsym(handle, "MTDeviceStop"),
              let pRelease = dlsym(handle, "MTDeviceRelease") else {
            Log.trigger.error("MultitouchSupport 现役符号缺失（系统版本异常）")
            return fail()
        }
        createListFn = unsafeBitCast(pCreate, to: (@convention(c) () -> UnsafeMutableRawPointer?).self)
        registerFn = unsafeBitCast(pRegister, to: MTRegisterContactFrameCallbackFn.self)
        startFn = unsafeBitCast(pStart, to: MTDeviceStartFn.self)
        stopFn = unsafeBitCast(pStop, to: MTDeviceStopFn.self)
        releaseFn = unsafeBitCast(pRelease, to: MTDeviceReleaseFn.self)

        guard let rawArr = createListFn?(),
              let arr = unsafeBitCast(rawArr, to: CFArray.self) as CFArray?,
              CFArrayGetCount(arr) > 0 else {
            Log.trigger.error("MTDeviceCreateList 未返回触控设备")
            return fail()
        }
        var registered = 0
        for i in 0..<CFArrayGetCount(arr) {
            guard let v = CFArrayGetValueAtIndex(arr, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: v)
            guard registerFn?(dev, mtFrameCallback) == true else { continue }
            devices.append(dev)
            startFn?(dev, 0)
            registered += 1
        }
        guard registered > 0 else {
            Log.trigger.error("帧回调注册失败（所有设备）——可能需要「输入监控」授权")
            return fail()
        }
        CallbackRouter.shared.target = self
        isHealthy = true
        startDiagnostics()
        Log.trigger.info("手势源就绪（MultitouchSupport 触点流，设备 \(registered, privacy: .public) 台，阈值=\(self.settings.gestureThreshold, privacy: .public)）")
        onStateChanged?()
        return true
    }

    /// 每 5s 汇总一次回调计数（有新帧才输出；info 级）。
    private func startDiagnostics() {
        diagTimer?.invalidate()
        lastDiagFrames = 0
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isHealthy else { return }
                let s = CallbackRouter.shared.stats
                guard s.frames > self.lastDiagFrames else { return }
                self.lastDiagFrames = s.frames
                Log.trigger.info("触点帧诊断: 总 \(s.frames, privacy: .public) / 有触点 \(s.touchFrames, privacy: .public) / 峰值指数 \(s.maxFingers, privacy: .public)")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        diagTimer = timer
    }

    private func fail() -> Bool {
        releaseRuntime()
        isHealthy = false
        onStateChanged?()
        return false
    }

    public func stop() {
        settleWork?.cancel()
        settleWork = nil
        diagTimer?.invalidate()
        diagTimer = nil
        releaseRuntime()
        engine.reset()
        isBurstClaimed = false
        if isHealthy {
            isHealthy = false
            onStateChanged?()
        }
    }

    /// 设置变化（调参滑杆）时同步引擎/触点识别/张开关闭参数——源运行中热更新，不重启。
    public func applySettings() {
        applyTuning()
    }

    /// 调参全量下发（启动与设置变化时；键位与钳制见 SettingsStore 手势调参区）。
    private func applyTuning() {
        engine.updateParams {
            $0.openThreshold = settings.gestureThreshold
            $0.window = settings.gestureWindow
            $0.cooldown = settings.gestureEngineCooldown
            $0.minBurstTicks = settings.gestureMinBurstTicks
        }
        tracker.minFingers = settings.gestureMinFingers
        tracker.anchorDistanceFloor = Float(settings.gestureAnchorDistanceFloor)
        tracker.swipeCommonRatio = Float(settings.gestureSwipeCommonRatio)
        tracker.swipeVelocityNoiseFloor = Float(settings.gestureVelocityNoiseFloor)
        tracker.swipeConsecutiveFrames = settings.gestureSwipeConsecutiveFrames
        tracker.swipeCentroidTravel = Float(settings.gestureSwipeCentroidTravel)
        closeAccum.threshold = settings.gestureCloseThreshold
    }

    private func releaseRuntime() {
        CallbackRouter.shared.target = nil
        for dev in devices {
            stopFn?(dev)
            releaseFn?(dev)
        }
        devices = []
        createListFn = nil
        registerFn = nil
        startFn = nil
        stopFn = nil
        releaseFn = nil
        frameworkHandle = nil   // 不 dlclose：常驻进程生命周期内保持框架状态
        tracker.closeBurst()
    }

    // MARK: - 帧摄入（回调线程拷贝坐标后跳主线程；包内可见供路由转发）

    func ingest(points: [TouchPinchTracker.TouchSample]) {
        let deltas = tracker.onFrame(points)
        if points.count < 2 {
            // onFrame 内部已闭簇；确有簇结束才立即结算（冷却即刻起算）
            closeAccum.reset()   // 抬手即清（下一簇重新累计）
            isBurstClaimed = false   // 抬手放行手势闸门（面板占用期由 App 层另行判定）
            onCloseProgressEnd?()   // 撤跟手关闭预览（内部有活跃守卫）
            if points.isEmpty {
                // 确定抬手（n=0）：立即闭簇，松手提交/弹回即刻判定（不等窗口期）
                engine.forceSettle()
            }
            if let summary = tracker.takeLastBurstSummary() {
                logSettle(summary: summary)
            }
            return
        }
        guard !deltas.isEmpty else { return }
        // 认领沿：首个非空增量即本簇归属启动器（早于预览门槛——把预览门槛前
        // 几帧的泄漏也一并挡住），横扫抑制也自认领簇内发生，无额外整定
        isBurstClaimed = true
        if framesLogged == 0 {
            framesLogged = 1
            Log.trigger.info("增量解码成功（触点指距流，示例=\(String(format: "%.4f", deltas.last ?? 0), privacy: .public)）——delta 模式生效")
            onStateChanged?()
        }
        if isPanelVisible() {
            // 面板打开：张开方向驱动跟手关闭预览与关闭（FR-T3），不喂唤起引擎
            var closed = false
            for d in deltas {
                if closeAccum.feed(d) {
                    Log.trigger.info("张开关闭触发（累计 ≥ +\(self.closeAccum.threshold, format: .fixed(precision: 2), privacy: .public)）")
                    onSpreadClose?()
                    closed = true
                    break
                }
            }
            if !closed {
                onCloseProgress?(min(1, max(0, closeAccum.accum / closeAccum.threshold)))
            }
            return
        }
        closeAccum.reset()
        for d in deltas {
            engine.feed(delta: d)
        }
        scheduleSettle()
    }

    /// 每次喂入后（重）启动窗口期结算（容差防帧抖动，可调；与旧源一致）。
    private func scheduleSettle() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleWork = nil
            self.logSettle(summary: self.tracker.takeLastBurstSummary())
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + engine.params.window + settings.gestureSettleTolerance,
                                      execute: work)
    }

    private func logSettle(summary: String?) {
        Log.trigger.info("簇结算: ticks=\(self.engine.burstTickCount, privacy: .public) 累计=\(String(format: "%.3f", self.engine.currentAccum), privacy: .public) [\((summary ?? "无簇"), privacy: .public)]")
        engine.settle()
        tracker.closeBurst()
    }
}

/// C 回调 → Swift 实例的路由：`MTFrameCallbackFunction` 不携带用户上下文，
/// 只能经进程级单例转发（weak：源销毁后自动失效；回调线程仅读指针+跳队列）。
/// 同时承担回调层诊断计数（指数直方图——区分「无回调」与「有帧未达 4 指」；
/// 不记坐标，NFR-PRIV P-2）。
private final class CallbackRouter {
    static let shared = CallbackRouter()
    private let lock = NSLock()
    private weak var _target: AnyObject?
    private var _frameCount = 0
    private var _touchFrames = 0
    private var _maxFingers = 0
    private var _loggedFirst = false

    var target: AnyObject? {
        get { lock.lock(); defer { lock.unlock() }; return _target }
        set { lock.lock(); defer { lock.unlock() }; _target = newValue }
    }

    /// 回调线程调用：记帧。返回 true = 需要打首帧日志（0→1 边沿）。
    func noteFrame(fingers: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _frameCount += 1
        if fingers > 0 { _touchFrames += 1 }
        _maxFingers = max(_maxFingers, fingers)
        if !_loggedFirst {
            _loggedFirst = true
            return true
        }
        return false
    }

    var stats: (frames: Int, touchFrames: Int, maxFingers: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_frameCount, _touchFrames, _maxFingers)
    }
}

/// 全局 C 回调（框架私有线程）：拷贝指 ID + 归一化坐标 → 主线程 ingest。
/// n=0 的抬手帧同样转发（闭簇信号）；只读 touches 内存，不做任何拦截（FR-T9）。
private let mtFrameCallback: MTFrameCallbackFunction = { _, touches, numTouches, _, _ in
    let n = Int(numTouches)
    if CallbackRouter.shared.noteFrame(fingers: n) {
        Log.trigger.info("MT 首帧到达（指数 \(n, privacy: .public)）——帧回调链路通")
    }
    var points: [TouchPinchTracker.TouchSample] = []
    if n > 0, let touches {
        points.reserveCapacity(n)
        for i in 0..<n {
            let t = touches[i]
            points.append(TouchPinchTracker.TouchSample(id: t.fingerID,
                                                        x: t.normalizedVector.position.x,
                                                        y: t.normalizedVector.position.y))
        }
    }
    guard let target = CallbackRouter.shared.target else { return }
    DispatchQueue.main.async {
        // 路由持有的是 AnyObject，回主线程后再按 MainActor 消化
        MainActor.assumeIsolated {
            (target as? MultitouchGestureSource)?.ingest(points: points)
        }
    }
}
