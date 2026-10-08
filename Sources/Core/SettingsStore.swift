import Foundation

public extension Notification.Name {
    /// 任一设置项变化后主线程广播；各触发源/索引/网格自行响应。
    static let launcherzSettingsChanged = Notification.Name("launcherz.settingsChanged")
}

/// 设置持久化（UserDefaults 封装，FR-D3 / SRS §4.8）。
public final class SettingsStore {
    public static let shared = SettingsStore()

    private let defaults: UserDefaults

    private enum Key {
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let hotkeyModifiers = "hotkey.modifiers"   // Carbon 修饰键位掩码
        static let launchAtLogin = "general.launchAtLogin"
        static let hotCornerEnabled = "trigger.hotCornerEnabled"
        static let gridColumns = "appearance.gridColumns" // 5–9
        static let showSystemTools = "apps.showSystemTools"
        static let extraScanDirs = "apps.extraScanDirs"
        static let firstRunDone = "onboarding.firstRunDone"
        static let gestureEnabled = "trigger.gestureEnabled"
        static let gestureThreshold = "trigger.gestureThreshold"          // 0.2–0.6
        // —— 手势调参（设置界面「手势调参」区全量开放；默认值 = 历史定稿值）——
        static let gestureWindow = "gesture.window"
        static let gestureEngineCooldown = "gesture.engineCooldown"
        static let gestureMinBurstTicks = "gesture.minBurstTicks"
        static let gestureSettleTolerance = "gesture.settleTolerance"
        static let gestureMinFingers = "gesture.minFingers"
        static let gestureAnchorDistanceFloor = "gesture.anchorDistanceFloor"
        static let gestureSwipeCommonRatio = "gesture.swipeCommonRatio"
        static let gestureVelocityNoiseFloor = "gesture.velocityNoiseFloor"
        static let gestureSwipeConsecutiveFrames = "gesture.swipeConsecutiveFrames"
        static let gestureSwipeCentroidTravel = "gesture.swipeCentroidTravel"
        static let gestureCloseThreshold = "gesture.closeThreshold"
        static let gesturePinchOutSuppress = "gesture.pinchOutSuppress"
        static let gesturePreviewMinTicks = "gesture.previewMinTicks"
        static let gesturePreviewMinProgress = "gesture.previewMinProgress"
        static let gesturePreviewScaleRange = "gesture.previewScaleRange"
        static let gesturePreviewCommitProgress = "gesture.previewCommitProgress"
        static let triggerCooldown = "trigger.cooldown"
        static let hotCornerDwell = "hotCorner.dwell"
        static let hotCornerRearmDelay = "hotCorner.rearmDelay"
        static let pageCommitProgress = "page.commitProgress"
        static let pageFlickMinProgress = "page.flickMinProgress"
        static let pageFlickVelocity = "page.flickVelocity"
        static let pageDragDeadZone = "page.dragDeadZone"
        static let pageDriveDuration = "page.driveDuration"
        static let pageSettleMinDuration = "page.settleMinDuration"
        static let pageSettleMaxDuration = "page.settleMaxDuration"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 默认值集中注册（首启前读任意键也有兜底）
        defaults.register(defaults: [
            Key.hotkeyKeyCode: 49,               // kVK_Space
            Key.hotkeyModifiers: 0x0800,         // optionKey
            Key.gridColumns: 7,
            Key.showSystemTools: false,
            Key.extraScanDirs: [String](),
            Key.firstRunDone: false,
            Key.gestureEnabled: true,
            Key.gestureThreshold: 0.35,          // FR-T2 默认
            Key.gestureWindow: 0.6,              // SRS §6：600ms 手势窗口期
            Key.gestureEngineCooldown: 0.8,      // FR-T6/X1 引擎内冷却
            Key.gestureMinBurstTicks: 8,
            Key.gestureSettleTolerance: 0.05,
            Key.gestureMinFingers: 4,            // SRS：四指门控
            Key.gestureAnchorDistanceFloor: 0.05,
            Key.gestureSwipeCommonRatio: 0.85,
            Key.gestureVelocityNoiseFloor: 0.0025,
            Key.gestureSwipeConsecutiveFrames: 3,
            Key.gestureSwipeCentroidTravel: 0.2,
            Key.gestureCloseThreshold: 0.30,     // FR-T3 张开关闭阈值
            Key.gesturePinchOutSuppress: 1.5,
            Key.gesturePreviewMinTicks: 4,
            Key.gesturePreviewMinProgress: 0.4,
            Key.gesturePreviewScaleRange: 1.35,
            Key.gesturePreviewCommitProgress: 0.75,
            Key.triggerCooldown: 0.8,            // FR-T6 仲裁层冷却
            Key.hotCornerDwell: 0.22,
            Key.hotCornerRearmDelay: 1.2,
            Key.pageCommitProgress: 0.5,
            Key.pageFlickMinProgress: 0.12,
            Key.pageFlickVelocity: 600,
            Key.pageDragDeadZone: 3,
            Key.pageDriveDuration: 0.22,         // FR-G2 定稿 220ms
            Key.pageSettleMinDuration: 0.15,
            Key.pageSettleMaxDuration: 0.28,
        ])
    }

    // MARK: 热键（FR-T1 / US-T1）

    public var hotkeyKeyCode: Int {
        get { defaults.integer(forKey: Key.hotkeyKeyCode) }
        set { defaults.set(newValue, forKey: Key.hotkeyKeyCode); notify() }
    }

    /// Carbon 修饰键掩码（cmdKey/optionKey/controlKey/shiftKey 组合）。
    public var hotkeyModifiers: Int {
        get { defaults.integer(forKey: Key.hotkeyModifiers) }
        set { defaults.set(newValue, forKey: Key.hotkeyModifiers); notify() }
    }

    // MARK: 热角（FR-T8，默认关）

    public var hotCornerEnabled: Bool {
        get { defaults.bool(forKey: Key.hotCornerEnabled) }
        set { defaults.set(newValue, forKey: Key.hotCornerEnabled); notify() }
    }

    // MARK: 手势（FR-T2/T3，M2）

    /// 手势总开关（默认开）。关闭时全局捏合 tap 与面板内张开关闭一并停用（design.md §3.4）。
    public var gestureEnabled: Bool {
        get { defaults.bool(forKey: Key.gestureEnabled) }
        set { defaults.set(newValue, forKey: Key.gestureEnabled); notify() }
    }

    /// 捏合唤起阈值（幅度 0.2–0.6，越界钳制；FR-T2 可调）。
    /// MT 触点流下语义与系统 magnification 一致（真机四指捏合簇累计 −0.48…−0.81）。
    public var gestureThreshold: Double {
        get { min(0.6, max(0.2, defaults.double(forKey: Key.gestureThreshold))) }
        set { defaults.set(min(0.6, max(0.2, newValue)), forKey: Key.gestureThreshold); notify() }
    }

    // MARK: 手势调参（调试全量开放；各 accessor 越界钳制到标定区间）

    /// 手势窗口期（秒）：超过此时长无新事件，簇累计清零（GestureEngine.Params.window）。
    public var gestureWindow: Double {
        get { clamped(Key.gestureWindow, 0.1...2.0) }
        set { defaults.set(min(2.0, max(0.1, newValue)), forKey: Key.gestureWindow); notify() }
    }

    /// 触发后引擎内冷却（秒，FR-T6/X1 连击双保险之一；0 = 关闭）。
    public var gestureEngineCooldown: Double {
        get { clamped(Key.gestureEngineCooldown, 0...3.0) }
        set { defaults.set(min(3.0, max(0, newValue)), forKey: Key.gestureEngineCooldown); notify() }
    }

    /// toggle 降级模式：一个爆发簇至少这么多条事件才算手势（过滤零星噪音）。
    public var gestureMinBurstTicks: Int {
        get { clampedInt(Key.gestureMinBurstTicks, 1...60) }
        set { defaults.set(min(60, max(1, newValue)), forKey: Key.gestureMinBurstTicks); notify() }
    }

    /// 簇结算容差（秒）：源侧定时器在 window + 此容差后静默结算（防帧抖动提前闭簇）。
    public var gestureSettleTolerance: Double {
        get { clamped(Key.gestureSettleTolerance, 0.01...0.5) }
        set { defaults.set(min(0.5, max(0.01, newValue)), forKey: Key.gestureSettleTolerance); notify() }
    }

    /// 稳定在触指数门控：达到该指数才输出增量（SRS 四指；2/3 指捏合不唤起）。
    public var gestureMinFingers: Int {
        get { clampedInt(Key.gestureMinFingers, 2...6) }
        set { defaults.set(min(6, max(2, newValue)), forKey: Key.gestureMinFingers); notify() }
    }

    /// d0 锚距下限（归一化）：两指落点过近时防增量爆炸（真机簇 d0 实测 0.20…1.00）。
    public var gestureAnchorDistanceFloor: Double {
        get { clamped(Key.gestureAnchorDistanceFloor, 0.005...0.3) }
        set { defaults.set(min(0.3, max(0.005, newValue)), forKey: Key.gestureAnchorDistanceFloor); notify() }
    }

    /// 横扫主判据门限：指速度共同分量占比超过此值判平移。收紧会误杀带拖手的
    /// 真捏合（真机占比 0.65~0.75），放宽则漏拦横扫——0.85 为标定值。
    public var gestureSwipeCommonRatio: Double {
        get { clamped(Key.gestureSwipeCommonRatio, 0.5...0.99) }
        set { defaults.set(min(0.99, max(0.5, newValue)), forKey: Key.gestureSwipeCommonRatio); notify() }
    }

    /// 速度噪声底（归一化/帧）：低于此速度的帧不参与平移/收拢分解。
    public var gestureVelocityNoiseFloor: Double {
        get { clamped(Key.gestureVelocityNoiseFloor, 0.0005...0.02) }
        set { defaults.set(min(0.02, max(0.0005, newValue)), forKey: Key.gestureVelocityNoiseFloor); notify() }
    }

    /// 连续多少帧近乎纯平移才判横扫（防单帧抖动误杀真捏合）。
    public var gestureSwipeConsecutiveFrames: Int {
        get { clampedInt(Key.gestureSwipeConsecutiveFrames, 1...10) }
        set { defaults.set(min(10, max(1, newValue)), forKey: Key.gestureSwipeConsecutiveFrames); notify() }
    }

    /// 横扫累计判据（兜底）：质心平移超过此值整簇抑制（真机横扫 ≥0.3；捏合 <0.1）。
    public var gestureSwipeCentroidTravel: Double {
        get { clamped(Key.gestureSwipeCentroidTravel, 0.05...0.6) }
        set { defaults.set(min(0.6, max(0.05, newValue)), forKey: Key.gestureSwipeCentroidTravel); notify() }
    }

    /// 面板打开期间四指张开关闭阈值（FR-T3，累计 ≥ 此值触发关闭）。
    public var gestureCloseThreshold: Double {
        get { clamped(Key.gestureCloseThreshold, 0.1...1.5) }
        set { defaults.set(min(1.5, max(0.1, newValue)), forKey: Key.gestureCloseThreshold); notify() }
    }

    /// 面板内张开关闭后的 toggle 再触发抑制窗口（秒；真机实证结算延迟 0.65s）。
    public var gesturePinchOutSuppress: Double {
        get { clamped(Key.gesturePinchOutSuppress, 0.3...5.0) }
        set { defaults.set(min(5.0, max(0.3, newValue)), forKey: Key.gesturePinchOutSuppress); notify() }
    }

    /// 跟手预览门槛之一：簇存活帧数低于此值不点亮预览（横扫泄漏防护）。
    public var gesturePreviewMinTicks: Int {
        get { clampedInt(Key.gesturePreviewMinTicks, 0...30) }
        set { defaults.set(min(30, max(0, newValue)), forKey: Key.gesturePreviewMinTicks); notify() }
    }

    /// 跟手预览门槛之二：进度低于此值不点亮预览。
    public var gesturePreviewMinProgress: Double {
        get { clamped(Key.gesturePreviewMinProgress, 0...1) }
        set { defaults.set(min(1, max(0, newValue)), forKey: Key.gesturePreviewMinProgress); notify() }
    }

    /// 预览起始/关闭终态放大倍率（1.35 = 内容自屏幕边缘外收拢落定）。
    public var gesturePreviewScaleRange: Double {
        get { clamped(Key.gesturePreviewScaleRange, 1.05...2.0) }
        set { defaults.set(min(2.0, max(1.05, newValue)), forKey: Key.gesturePreviewScaleRange); notify() }
    }

    /// 松手提交线（0.5–0.95）：簇结束时预览进度 ≥ 此值直接收尾为打开，不弹回。
    /// 预览不透明度同此对齐——全不透明 ⇔ 松手即打开。
    public var gesturePreviewCommitProgress: Double {
        get { clamped(Key.gesturePreviewCommitProgress, 0.5...0.95) }
        set { defaults.set(min(0.95, max(0.5, newValue)), forKey: Key.gesturePreviewCommitProgress); notify() }
    }

    /// 触发仲裁冷却（秒，FR-T6；手势/热角类触发共用；0 = 关闭）。
    public var triggerCooldown: Double {
        get { clamped(Key.triggerCooldown, 0...3.0) }
        set { defaults.set(min(3.0, max(0, newValue)), forKey: Key.triggerCooldown); notify() }
    }

    /// 热角鼠标驻留时长（秒）。
    public var hotCornerDwell: Double {
        get { clamped(Key.hotCornerDwell, 0.05...2.0) }
        set { defaults.set(min(2.0, max(0.05, newValue)), forKey: Key.hotCornerDwell); notify() }
    }

    /// 热角触发后再武装冷却（秒，防抖）。
    public var hotCornerRearmDelay: Double {
        get { clamped(Key.hotCornerRearmDelay, 0...5.0) }
        set { defaults.set(min(5.0, max(0, newValue)), forKey: Key.hotCornerRearmDelay); notify() }
    }

    /// 翻页松手判据：拖出进度 ≥ 此值直接翻页（进度 = |偏移| / 页宽）。
    public var pageCommitProgress: Double {
        get { clamped(Key.pageCommitProgress, 0.1...0.95) }
        set { defaults.set(min(0.95, max(0.1, newValue)), forKey: Key.pageCommitProgress); notify() }
    }

    /// 翻页甩动判据：拖出进度 ≥ 此值且甩速达标也翻页。
    public var pageFlickMinProgress: Double {
        get { clamped(Key.pageFlickMinProgress, 0.01...0.5) }
        set { defaults.set(min(0.5, max(0.01, newValue)), forKey: Key.pageFlickMinProgress); notify() }
    }

    /// 翻页甩动速度门（px/s，与拖拽方向同号才计）。
    public var pageFlickVelocity: Double {
        get { clamped(Key.pageFlickVelocity, 50...5000) }
        set { defaults.set(min(5000, max(50, newValue)), forKey: Key.pageFlickVelocity); notify() }
    }

    /// 搭 band 前的横向死区（pt）：过滤垂直滚动/微抖。
    public var pageDragDeadZone: Double {
        get { clamped(Key.pageDragDeadZone, 0...30) }
        set { defaults.set(min(30, max(0, newValue)), forKey: Key.pageDragDeadZone); notify() }
    }

    /// 触发式推入时长（秒，FR-G2 定稿 220ms ease-in-out）。
    public var pageDriveDuration: Double {
        get { clamped(Key.pageDriveDuration, 0.05...1.0) }
        set { defaults.set(min(1.0, max(0.05, newValue)), forKey: Key.pageDriveDuration); notify() }
    }

    /// 收尾时长下限（秒，按剩余距离在区间内取值）。
    public var pageSettleMinDuration: Double {
        get { clamped(Key.pageSettleMinDuration, 0.02...1.0) }
        set { defaults.set(min(1.0, max(0.02, newValue)), forKey: Key.pageSettleMinDuration); notify() }
    }

    /// 收尾时长上限（秒）。
    public var pageSettleMaxDuration: Double {
        get { clamped(Key.pageSettleMaxDuration, 0.05...1.5) }
        set { defaults.set(min(1.5, max(0.05, newValue)), forKey: Key.pageSettleMaxDuration); notify() }
    }

    /// 手势调参恢复默认（调试界面「恢复默认」）：删除持久化值，注册默认接管。
    public func resetGestureTuning() {
        [Key.gestureThreshold, Key.gestureWindow, Key.gestureEngineCooldown,
         Key.gestureMinBurstTicks, Key.gestureSettleTolerance, Key.gestureMinFingers,
         Key.gestureAnchorDistanceFloor, Key.gestureSwipeCommonRatio, Key.gestureVelocityNoiseFloor,
         Key.gestureSwipeConsecutiveFrames, Key.gestureSwipeCentroidTravel, Key.gestureCloseThreshold,
         Key.gesturePinchOutSuppress, Key.gesturePreviewMinTicks, Key.gesturePreviewMinProgress,
         Key.gesturePreviewScaleRange, Key.gesturePreviewCommitProgress, Key.triggerCooldown, Key.hotCornerDwell,
         Key.hotCornerRearmDelay, Key.pageCommitProgress, Key.pageFlickMinProgress,
         Key.pageFlickVelocity, Key.pageDragDeadZone, Key.pageDriveDuration,
         Key.pageSettleMinDuration, Key.pageSettleMaxDuration]
            .forEach { defaults.removeObject(forKey: $0) }
        notify()
    }

    private func clamped(_ key: String, _ range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, defaults.double(forKey: key)))
    }

    private func clampedInt(_ key: String, _ range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, defaults.integer(forKey: key)))
    }

    // MARK: 通用（FR-X2）

    public var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin); notify() }
    }

    // MARK: 应用（FR-X4）

    public var showSystemTools: Bool {
        get { defaults.bool(forKey: Key.showSystemTools) }
        set { defaults.set(newValue, forKey: Key.showSystemTools); notify() }
    }

    public var extraScanDirs: [String] {
        get { defaults.stringArray(forKey: Key.extraScanDirs) ?? [] }
        set { defaults.set(newValue, forKey: Key.extraScanDirs); notify() }
    }

    // MARK: 外观（FR-X3，P2）

    /// 网格列数 5–9，越界钳制（FR-G1）。
    public var gridColumns: Int {
        get { min(9, max(5, defaults.integer(forKey: Key.gridColumns))) }
        set { defaults.set(min(9, max(5, newValue)), forKey: Key.gridColumns); notify() }
    }

    // MARK: 首启（FR-O1，M2 完整引导）

    public var firstRunDone: Bool {
        get { defaults.bool(forKey: Key.firstRunDone) }
        set { defaults.set(newValue, forKey: Key.firstRunDone) }
    }

    private func notify() {
        NotificationCenter.default.post(name: .launcherzSettingsChanged, object: nil)
    }
}
