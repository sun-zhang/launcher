import AppKit
import Combine
import Core
import Foundation
import SwiftUI
import TriggerLayer

/// 非激活全屏面板（FR-P1..P5；参数照抄预研 F1 逐项验证值）。
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // borderless 窗口默认不能 key，nonactivatingPanel + canBecomeKey 覆写为 spike 验证组合
}

/// 翻页纸带演出层容器：点击穿透（滑动中的页面不吞图标点击/空白关闭）。
final class PageStripOverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 纸带单页视图：同样点击穿透。
final class PageBandView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 面板控制器：常驻 NSPanel（F2：不销毁，关闭 = 淡出 + orderOut），
/// 开/关动画在内容宿主层做「同层淡入 + 网格 transform」（design.md §4.1，不整窗 alpha）。
@MainActor
public final class PanelController: PanelControlling {

    public static var shared: PanelController!

    public let model: PanelViewModel
    let panel: NonActivatingPanel
    let root: PanelRootView
    let contentHost: NSHostingView<PanelContentView>

    public private(set) var openCount = 0
    public private(set) var openLatenciesMs: [Double] = []
    private var keyMonitor: Any?

    // MARK: 翻页纸带状态（旧版 Launchpad 效果：跟手拖拽 + 惯性收尾 + 触发式推入）
    //
    // 位移全部经 NSView setFrameOrigin 直写（拖拽逐事件、收尾/推入逐帧）——本窗口
    // 实证只有视图级几何变化与结构性增删必定重绘，SwiftUI/CA 动画路径不上屏。

    /// 手势/翻页调参集合：默认值 = 历史定稿值（F1/F2 预研验证口径），
    /// 由 App 层从 SettingsStore 实时下发（设置界面「手势调参」区）。
    public struct GestureTuningConfig {
        /// 预览起始/关闭终态的放大倍率（内容从屏幕边缘外向中间收拢落定，
        /// 张开时反向放大出屏消失——Launchpad 手势的对称感）。
        public var previewScaleRange: Double = 1.35
        /// 松手判定：拖出 ≥ commitProgress 直接翻；不足时甩速 ≥ flickVelocity 且拖出 ≥ flickMinProgress 也翻。
        public var pageCommitProgress: Double = 0.5
        public var pageFlickMinProgress: Double = 0.12
        public var pageFlickVelocity: Double = 600   // px/s
        /// 搭 band 前的横向死区（pt）：过滤垂直滚动/微抖。
        public var pageDragDeadZone: Double = 3
        /// 触发式推入时长（FR-G2 定稿 220ms ease-in-out；Hermite v₀=0 即 smoothstep 同族）。
        public var pageDriveDuration: Double = 0.22
        /// 收尾时长上下限（按剩余距离在区间内取值）。
        public var pageSettleMinDuration: Double = 0.15
        public var pageSettleMaxDuration: Double = 0.28
        /// 面板内张开关闭后的 toggle 再触发抑制窗口（真机实证结算延迟 0.65s）。
        public var pinchOutSuppressWindow: Double = 1.5
        /// 松手提交线：簇结束时预览进度 ≥ 此值直接收尾为打开（不弹回）——
        /// 与不透明度到位点对齐，「看起来完整」与「松手会打开」同步成立。
        public var previewCommitProgress: Double = 0.75
        public init() {}
    }

    public private(set) var tuning = GestureTuningConfig()

    /// 设置界面调参下发（App 层在启动与每次设置变化时调用）。
    public func setTuning(_ config: GestureTuningConfig) {
        tuning = config
    }

    private enum PageStripState { case idle, dragging, settling }
    private var stripState: PageStripState = .idle
    /// 带符号偏移（pt）：o<0 向下一页（内容左移、新页自右入），o>0 向上一页；0=基准页就位。
    /// band 布局：near.x = o，far.x = o − side·屏宽——两页边缘恒相接，天然锁步。
    private var stripOffset: CGFloat = 0
    /// 拖拽原始累计（未钳制，供方向判定与死区）。
    private var dragRaw: CGFloat = 0
    /// 纸带基准页（near band 显示的页；拖拽/推入期间不随 model 变化）。
    private var stripBasePage: Int = 0
    /// 松手速度（px/s，与 o 同号），收尾 Hermite 初速。
    private var stripVelocity: CGFloat = 0
    /// far band 所在侧：-1 = 下一页方向（自右入），+1 = 上一页方向；0 = 无 far。
    private var farSide: Int = 0
    private var nearBand: PageBandView?
    private var farBand: PageBandView?
    /// 纸带演出覆盖层：独立于 contentHost 的层树，挂在其上。
    private let pageStripOverlay = PageStripOverlayView()
    private var pageStripCancellable: AnyCancellable?

    // 收尾/推入步进（60Hz Timer 驱动；步进按墙上钟，驱动源可一政替换）
    private var settleStart: CFTimeInterval = 0
    private var settleFrom: CGFloat = 0
    private var settleTarget: CGFloat = 0
    private var settleV0: CGFloat = 0
    private var settleDuration: Double = 0
    /// 收尾到位后需提交的页（nil = 无需提交：弹回，或推入路径 model 已在换页）。
    private var settleCommitPage: Int?
    /// 收尾已到位，下一帧移除 band（提交换页后隔帧拆除，防同帧竞态闪烁）。
    private var teardownNextFrame = false
    /// 步进定时器（60Hz，RunLoop .common）。选型：CADisplayLink 在 macOS 须经
    /// NSView.displayLink(target:) 创建且预调度语义无承诺；Timer+setFrameOrigin
    /// 是本窗口真机实证过的可靠驱动（Launchpad 口径亦为 60Hz 时代效果）。
    private var stepTimer: Timer?

    // 手势跟手预览（FR-T5）
    private var isGesturePreviewActive = false
    private var gesturePreviewProgress: Double = 0
    // 手势张开关闭预览（FR-T3 跟手版）：面板打开期间随张开进度放大淡出
    private var isGestureClosePreviewActive = false
    /// 最近一次「面板内张开关闭」时刻（toggle 降级模式防重开竞争）。
    private var lastPinchOutCloseAt: Date?

    /// toggle 降级模式的触发抑制：面板可见，或刚被面板内张开关闭（pinchOutSuppressWindow 内）。
    /// 真机日志实证（2026-10-05）：pinchOut 关闭后 0.65s 簇结算才到达，届时
    /// isPanelVisible 已复位——只看可见性会让面板被反复重开。
    public var isToggleFireSuppressed: Bool {
        if panel.isVisible { return true }
        if let lastPinchOutCloseAt,
           Date().timeIntervalSince(lastPinchOutCloseAt) < tuning.pinchOutSuppressWindow { return true }
        return false
    }

    // MARK: autofill 建议窗闪现抑制（闪黑框/白框根治，2026-10-08 真机定案）

    /// 闪现的黑/白框（随系统明暗主题变色）是 SafariPlatformSupport.framework
    /// 的 SPRoundedWindow（macOS autofill 建议共享 UI）：进程内首次「真实点击
    /// 聚焦」文本框时惰性初始化，建窗即收（~50ms）。所有公开的文本辅助标志都
    /// 拦不住它的创建（建窗发生在资格判定之前），故掐可见性：聚焦后 0.8s 内以
    /// 5ms 轮询本进程窗口，该类窗口一出现立即透明+收起——首帧合成前生效，用户
    /// 不可见。搜索框永远不会收到 autofill 建议，隐藏无副作用。仅真实硬件事件
    /// 触发该初始化（CGEventPost 合成点击不触发），回归验证须真机复现。
    func suppressAutofillSuggestionBurst() {
        let deadline = Date().addingTimeInterval(0.8)
        Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { timer in
            for w in NSApp.windows where NSStringFromClass(type(of: w)) == "SPRoundedWindow" {
                w.alphaValue = 0
                w.orderOut(nil)
            }
            if Date() > deadline { timer.invalidate() }
        }
    }

    public init(model: PanelViewModel) {
        self.model = model
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        root = PanelRootView(frame: NSRect(origin: .zero, size: screenFrame.size))
        // 根视图也 layer-backed：否则窗口层树不接 WindowServer 实时合成——
        // 子层只有结构性增删才重绘，CA 动画与属性直写全部不上屏（真机实证）
        root.wantsLayer = true
        panel = NonActivatingPanel(contentRect: screenFrame,
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        // —— F1 验证参数（改动需附等效证据）——
        panel.level = NSWindow.Level(rawValue: 21)                     // 覆盖菜单栏，低于系统浮层
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = root

        contentHost = NSHostingView(rootView: PanelContentView(model: model))
        contentHost.wantsLayer = true
        contentHost.layer?.backgroundColor = NSColor.clear.cgColor
        root.embed(content: contentHost)

        // 纸带演出层：独立层树挂在实时内容之上，点击穿透（真机实证：演出层若
        // 吞点击会废掉空白关闭与图标启动）
        pageStripOverlay.wantsLayer = true
        pageStripOverlay.frame = root.bounds
        pageStripOverlay.autoresizingMask = [.width, .height]
        root.addSubview(pageStripOverlay, positioned: .above, relativeTo: contentHost)

        centerContentAnchor()   // 缩放锚点定屏幕中心（每次屏幕参数变化后重申）

        root.loadWallpaper()   // FR-P2 壁纸快照（异步；失败保持毛玻璃兜底）

        root.onPinchOutClose = { [weak self] in self?.closePanel(source: .pinchOut) }
        root.onPageDrag = { [weak self] event in self?.handlePageDrag(event) }

        // 翻页仲裁：currentPage 为 willSet 发布——sink 先于 SwiftUI 提交新页，
        // model.currentPage 仍是旧值，新旧两页数据此刻都拿得到。源于纸带收尾
        // 提交的变更被吸收；键盘/页码点来路则进入触发式推入。
        pageStripCancellable = model.$currentPage
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] newValue in self?.handlePageModelChange(newValue) }

        // X3/X6：屏幕参数变化时贴回主屏（MVP 口径：仅主屏）
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screenParametersChanged() {
        guard let frame = NSScreen.main?.frame else { return }
        teardownStrip()   // 尺寸变化令 band 几何失效，直接清场回 idle
        panel.setFrame(frame, display: false)
        if panel.isVisible { panel.orderFrontRegardless() }
        centerContentAnchor()   // 尺寸变化后重申锚点（AppKit 布局可能重置层几何）
        root.loadWallpaper()   // 尺寸/缩放变化 → 重渲染快照
    }

    /// 缩放锚点 = 内容中心。NSView 宿主层默认 anchorPoint(0,0)（视觉上从
    /// 角上扩/缩——真机实证先后出现左下/右上偏移，NSHostingView 的层几何
    /// 还受 SwiftUI 布局影响）——显式设锚并补偿 position 保持 frame 不变，
    /// 此后纯 scale 变换/动画天然绕中心。
    private func centerContentAnchor() {
        guard let layer = contentHost.layer else { return }
        let target = CGPoint(x: 0.5, y: 0.5)
        let old = layer.anchorPoint
        guard old != target else { return }
        layer.anchorPoint = target
        layer.position = CGPoint(
            x: layer.position.x + (target.x - old.x) * layer.bounds.width,
            y: layer.position.y + (target.y - old.y) * layer.bounds.height)
    }

    // MARK: - PanelControlling

    public var isPanelVisible: Bool { panel.isVisible }

    /// 取证日志用：当前背景是否为壁纸快照（false = behindWindow 毛玻璃兜底）。
    public var usesWallpaperSnapshot: Bool { root.usesWallpaperSnapshot }

    /// selftest 断言用：整窗透明度（手势预览弹回后应复位为 1）。
    public var windowAlphaValue: CGFloat { panel.alphaValue }

    public func togglePanel(source: SourceKind) {
        // 逻辑开关：退场动画期间（窗口仍可见、逻辑已关）按 toggle 应重新打开
        model.isPanelVisible ? closePanel(source: source) : openPanel(source: source)
    }

    public func openPanel(source: SourceKind) {
        if isGesturePreviewActive {
            finalizeGesturePreviewAsOpen(source: source)
            return
        }
        // 逻辑开关（而非 panel.isVisible）：退场动画期间窗口仍可见，但逻辑已关闭——
        // 此时的唤起应立即重新打开（完成回调有 model 守卫不会误 orderOut）
        guard !model.isPanelVisible else { return }
        let t0 = CFAbsoluteTimeGetCurrent()

        // 每次唤起恒显第一页：此刻面板尚不可见，currentPage 订阅被
        // stripInteractionEnabled 拦截——直切换页，不触发纸带推入演出
        model.goToPage(0)
        model.markOpenSource(source)   // 先于 isPanelVisible（视图 onChange 据此决定是否聚焦搜索）
        panel.orderFrontRegardless()
        panel.makeKey()   // 非激活面板：成为 key 但不激活本应用（FR-P3）
        model.isPanelVisible = true
        installKeyMonitor()

        animateOpen()

        openCount += 1
        let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        openLatenciesMs.append(dt)
        Log.panel.info("OPEN #\(self.openCount) src=\(source.rawValue, privacy: .public) 可交互耗时=\(String(format: "%.1f", dt), privacy: .public)ms isKeyWindow=\(self.panel.isKeyWindow)")
        // 计量窗口之外：指纹未变命中缓存近零开销，换壁纸则后台重渲染（期间保留旧快照）
        root.loadWallpaper()
    }

    public func closePanel(source: SourceKind) {
        // 逻辑开关（而非 panel.isVisible）：真机实证的「死锁态」——model=true 而
        // 窗口已不在（关闭动画期竞态），窗口级守卫令 closePanel 永远空转、
        // 手势增量全被路由吞掉、面板再也无法响应。model 守卫使任何路径都能自愈。
        guard model.isPanelVisible else { return }
        if source == .pinchOut {
            lastPinchOutCloseAt = Date()   // toggle 降级模式抑制窗口用（见 isToggleFireSuppressed）
        }
        removeKeyMonitor()
        model.isPanelVisible = false
        isGestureClosePreviewActive = false
        // info 级：debug 在 macOS 26 不落盘（log show 不可见），闭环判读需要它
        Log.panel.info("CLOSE src=\(source.rawValue, privacy: .public)")

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            // 退场动画期间被重新打开/新手势预览已复用窗口：放弃 orderOut
            // （预览期 model 仍为 false,须一并守卫——真机实证死锁态成因之一）
            guard !self.model.isPanelVisible, !self.isGesturePreviewActive else { return }
            self.panel.orderOut(nil)
            // 复位窗口 alpha（张开跟手预览可能停在 <1）与网格缩放、清残留动画
            self.panel.alphaValue = 1
            self.setGridScale(1)
            self.contentHost.layer?.removeAllAnimations()
            self.teardownStrip()
            self.model.resetTransient()
            Log.panel.debug("CLOSED（orderOut 完成，焦点交还原应用——面板为 nonactivating）")
        }
        animateClose()
        CATransaction.commit()
    }

    // MARK: - 手势跟手预览（FR-T5：内容自屏幕边缘外随捏合进度向中间收拢落定；
    // 停则停、中断弹回、完成收尾为全开。张开关闭为对称反向。）
    //
    // 预览期整窗 alpha 渐入（含毛玻璃/壁纸背景）。§4.1「不整窗 alpha」针对开合动画的
    // 常规路径；预览必然在同帧率下过渡到全开或弹回，时长 ≤ 手势窗口期，取舍记录于此。

    /// 开向预览缩放：进度 0 → 1.35（超屏，自边缘外来）… 1 → 1.0（落定）。
    private func openPreviewScale(_ progress: Double) -> Double {
        let p = min(1, max(0, progress))
        return tuning.previewScaleRange - (tuning.previewScaleRange - 1) * p
    }

    /// 捏合进行中：进度 0...1（App 层仅在面板未开时转发）。
    /// 不透明度与松手提交线对齐：进度到 previewCommitProgress 即全不透明——
    /// 半透明 = 「还没到提交线，松手会弹回」；全不透明 = 「松手即打开」，
    /// 观感与判定同步（若 1:1 跟进度，中途停顿会悬在半透明与桌面重叠成重影）。
    public func updateGesturePreview(_ progress: Double) {
        guard !model.isPanelVisible || isGesturePreviewActive else { return }
        if !isGesturePreviewActive { beginGesturePreview() }

        gesturePreviewProgress = min(1, max(0, progress))
        let commit = max(0.05, tuning.previewCommitProgress)
        panel.alphaValue = min(1, max(0.02, gesturePreviewProgress / commit))
        setGridScale(openPreviewScale(gesturePreviewProgress))
    }

    /// 松手提交判读（App 层 onGestureEnd 用）：预览进行中且进度已达提交线。
    public var isGesturePreviewCommitReady: Bool {
        isGesturePreviewActive && gesturePreviewProgress >= tuning.previewCommitProgress
    }

    /// 面板打开期间张开进行中：进度 0...1（放大 + 淡出，跟手可停可逆）。
    public func updateGestureClosePreview(_ progress: Double) {
        guard model.isPanelVisible, !isGesturePreviewActive else { return }
        isGestureClosePreviewActive = true
        let p = min(1, max(0, progress))
        setGridScale(1 + (tuning.previewScaleRange - 1) * p)
        panel.alphaValue = 1 - 0.75 * p   // 最低 0.25：完成前保持可辨
    }

    /// 张开簇中断（未达关闭阈值 / 横扫抑制）：弹回全开态。
    public func cancelGestureClosePreview() {
        guard isGestureClosePreviewActive else { return }
        isGestureClosePreviewActive = false
        contentHost.layer?.removeAllAnimations()
        setGridScale(1)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        })
    }

    /// 一簇手势结束且未达阈值：弹回消失（120ms ease-in，预算 <150ms）。
    /// 退场用固定时序而非动画 completion（窗口 alpha 动画的完成回调时序不保证）。
    public func cancelGesturePreview() {
        guard isGesturePreviewActive else { return }
        isGesturePreviewActive = false
        panel.ignoresMouseEvents = false

        // 内容沿来向继续外扩淡出（自边缘外来的，回边缘外去）
        if let layer = contentHost.layer {
            layer.removeAllAnimations()
            let zoom = CABasicAnimation(keyPath: "transform.scale")
            zoom.fromValue = layer.presentation()?.transform.m11 ?? layer.transform.m11
            zoom.toValue = tuning.previewScaleRange + 0.15
            zoom.duration = 0.12
            zoom.timingFunction = CAMediaTimingFunction(name: .easeIn)
            zoom.fillMode = .forwards
            zoom.isRemovedOnCompletion = false
            layer.add(zoom, forKey: "lz.preview.cancel")
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.isGesturePreviewActive else { return }   // 期间新手势已重新开始预览
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.setGridScale(1)
            self.contentHost.layer?.removeAllAnimations()
            Log.panel.debug("手势预览弹回（未达阈值）")
        }
    }

    private func beginGesturePreview() {
        isGesturePreviewActive = true
        gesturePreviewProgress = 0
        // 预览即显第一页（否则捏合途中露出上次的页，收尾瞬间跳页）。
        // model 仍不可见：直切不演出
        model.goToPage(0)
        // 清残留开合动画：animateClose 的 fade/scale 以 fillMode=.forwards 钉住
        // presentation（网格 opacity=0），不清则预览只见毛玻璃不见内容
        // （真机实证：关闭后的下一次捏合预览「仅显示模糊背景」）
        contentHost.layer?.removeAllAnimations()
        centerContentAnchor()   // 保险：AppKit 布局可能重置锚点
        panel.alphaValue = 0.02
        setGridScale(openPreviewScale(0))   // 1.35：内容自屏幕边缘外来
        panel.ignoresMouseEvents = true   // 手势可能不成立：预览期点击穿透，不吞底层应用交互
        panel.orderFrontRegardless()      // 不 makeKey——预览不成不抢焦点
        root.loadWallpaper()              // 预览也要跟手当前壁纸（指纹缓存，近零开销）
        Log.panel.debug("手势预览开始")
    }

    /// 捏合到达阈值触发唤起：从当前预览呈现收尾到全开（openPanel 的预览分支）。
    private func finalizeGesturePreviewAsOpen(source: SourceKind) {
        isGesturePreviewActive = false
        panel.ignoresMouseEvents = false

        let t0 = CFAbsoluteTimeGetCurrent()
        model.goToPage(0)   // 双保险：预览开始已归零，防绕过 beginGesturePreview 的来路
        model.markOpenSource(source)   // 先于 isPanelVisible（同 openPanel 直开路径）
        panel.makeKey()
        model.isPanelVisible = true
        installKeyMonitor()

        let fromScale = openPreviewScale(gesturePreviewProgress)
        panel.alphaValue = 1   // 预览收尾直接定全量（弹簧缩放承担过渡感）
        animateOpen(scaleFrom: fromScale, fade: false)

        openCount += 1
        let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        openLatenciesMs.append(dt)
        Log.panel.info("OPEN #\(self.openCount) src=\(source.rawValue, privacy: .public) 手势预览收尾 可交互耗时=\(String(format: "%.1f", dt), privacy: .public)ms")
    }

    /// 缩放（锚点已由 centerContentAnchor 定在内容中心——纯 scale 即绕中心）。
    private func setGridScale(_ scale: Double) {
        guard let layer = contentHost.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // 跟手逐帧更新，禁用隐式动画
        layer.transform = CATransform3DMakeScale(CGFloat(scale), CGFloat(scale), 1)
        CATransaction.commit()
    }

    // MARK: - 翻页纸带（旧版 Launchpad 效果）
    //
    // 统一带符号偏移 o 的纸带模型：near band = 基准页（x = o），far band = 相邻页
    // （x = o − side·W），两页边缘恒相接、锁步移动、全程不透明——底层实时 SwiftUI
    // 在推入路径瞬间换页 / 拖拽路径收尾提交时换页，band 移除后无缝衔接。
    // 拖拽跨 0 反向时 far band 换侧重建（结构性增删，合法路径）。
    // 无相邻页一侧硬钳制在 o=0：band 若移开会展出底层实时网格造成重影
    // （边缘露缝无 band 覆盖），故放弃橡皮筋位移。

    private var stripInteractionEnabled: Bool {
        model.isPanelVisible && !model.isSearching && model.pageCount > 1
    }

    private func handlePageDrag(_ event: PageDragEvent) {
        switch event {
        case .began: pageDragBegan()
        case .changed(let deltaX): pageDragChanged(deltaX: deltaX)
        case .ended(let velocityX): pageDragEnded(velocityX: velocityX)
        case .cancelled: pageDragCancelled()
        }
    }

    private func pageDragBegan() {
        guard stripInteractionEnabled else { return }
        // 收尾进行中且尚未进入拆除帧：抓住冻结——保留当前视觉就地转拖拽
        if stripState == .settling, !teardownNextFrame {
            stopStepper()
            settleCommitPage = nil
            stripState = .dragging
            dragRaw = stripOffset   // 以当前视觉位置为拖拽起点（近似，连续无跳变）
            stripVelocity = 0
            return
        }
        if stripState != .idle { teardownStrip() }
        stripState = .dragging
        stripOffset = 0
        dragRaw = 0
        stripVelocity = 0
        stripBasePage = model.currentPage
        nearBand = nil   // band 延迟到越过死区再搭
        farBand = nil
        farSide = 0
    }

    private func pageDragChanged(deltaX: CGFloat) {
        guard stripState == .dragging else { return }
        dragRaw += deltaX   // 与自然滚动同向：deltaX<0 = 内容左移 = 下一页方向
        let width = contentHost.bounds.width
        guard width > 0 else { return }

        if nearBand == nil {
            guard abs(dragRaw) > CGFloat(tuning.pageDragDeadZone) else { return }
            let side = dragRaw < 0 ? -1 : 1
            buildBands(farPage: stripBasePage - side)   // side=-1 → 基准页+1
            guard nearBand != nil else { return }       // 该侧无相邻页：不搭 band，o 恒 0
        }

        let newOffset = clampedOffset(raw: dragRaw, width: width)
        let newSide = newOffset < 0 ? -1 : (newOffset > 0 ? 1 : farSide)
        if newSide != farSide {
            rebuildFarBand(farPage: stripBasePage - newSide)
        }
        stripOffset = newOffset
        layoutBands(width: width)
    }

    private func pageDragEnded(velocityX: CGFloat) {
        guard stripState == .dragging else { return }
        guard nearBand != nil else { stripState = .idle; return }   // 死区内松手
        stripVelocity = velocityX
        let width = contentHost.bounds.width
        let side = stripOffset < 0 ? -1 : (stripOffset > 0 ? 1 : 0)

        var commit = false
        if side != 0 {
            let progress = Double(abs(stripOffset) / width)
            let flick = Double(side) * Double(velocityX) > tuning.pageFlickVelocity
            commit = progress >= tuning.pageCommitProgress
                || (progress >= tuning.pageFlickMinProgress && flick)
        }

        if commit {
            let targetPage = stripBasePage - side
            let progress = Double(abs(stripOffset) / width)
            Log.panel.info("PAGESTRIP 松手提交 page=\(targetPage, privacy: .public) 进度=\(String(format: "%.2f", progress), privacy: .public) 速度=\(Int(velocityX), privacy: .public)px/s")
            startSettle(to: CGFloat(side) * width, commitPage: targetPage)
        } else {
            startSettle(to: 0, commitPage: nil)
        }
    }

    private func pageDragCancelled() {
        guard stripState == .dragging, nearBand != nil else { stripState = .idle; return }
        startSettle(to: 0, commitPage: nil)   // 系统取消手势：弹回基准页
    }

    /// 钳制映射：无相邻页一侧钉在 0；有相邻页单手势最多一页（|o| ≤ W）。
    private func clampedOffset(raw: CGFloat, width: CGFloat) -> CGFloat {
        let side: CGFloat = raw < 0 ? -1 : (raw > 0 ? 1 : 0)
        guard side != 0, neighborExists(forSide: side) else { return 0 }
        return side * min(abs(raw), width)
    }

    private func neighborExists(forSide side: CGFloat) -> Bool {
        let target = stripBasePage + (side < 0 ? 1 : -1)
        return target >= 0 && target < model.pages.count
    }

    // MARK: 翻页仲裁（$currentPage 订阅）

    private func handlePageModelChange(_ newPage: Int) {
        guard stripInteractionEnabled else { return }
        switch stripState {
        case .idle:
            startDrive(to: newPage)
        case .dragging:
            // 拖拽进行中外部改页（键盘/页码点）：立即终结算子直切（罕见路径）
            teardownStrip()
        case .settling:
            if settleCommitPage == newPage {
                settleCommitPage = nil   // 本状态机收尾的提交：吸收
            } else {
                retargetSettle(to: newPage)
            }
        }
    }

    /// 触发式推入（←→ 越界 / PgUp-PgDn / 页码点）：220ms ease-in-out 双页锁步。
    /// 页码点跨页跳转同样按一次推入演出（far band = 目标页）。
    private func startDrive(to newPage: Int) {
        let oldPage = model.currentPage   // willSet 时机：仍为旧值
        guard newPage != oldPage, newPage >= 0, newPage < model.pages.count else { return }
        let width = contentHost.bounds.width
        guard width > 100 else { return }

        stripBasePage = oldPage
        stripOffset = 0
        stripVelocity = 0
        buildBands(farPage: newPage)
        guard nearBand != nil else { return }
        settleFrom = 0
        settleTarget = CGFloat(newPage > oldPage ? -1 : 1) * width
        settleV0 = 0
        settleDuration = tuning.pageDriveDuration
        settleCommitPage = nil   // model 已在换页，收尾无需再提交
        settleStart = CACurrentMediaTime()
        teardownNextFrame = false
        stripState = .settling
        startStepper()
        Log.panel.info("PAGESTRIP 推入 \(oldPage, privacy: .public)→\(newPage, privacy: .public)")
    }

    /// 收尾中被打断（新键盘/页码点目标）：相邻目标（基准页或当前 far 页）从当前
    /// 偏移连续重定向；非相邻目标拆场后自当前 model 页重起一次推入（willSet 时机
    /// model.currentPage 仍是旧值，near band 即当前视觉页，衔接无跳变）。
    private func retargetSettle(to newPage: Int) {
        guard nearBand != nil else { teardownStrip(); return }
        if newPage == stripBasePage {
            stripVelocity = 0
            startSettle(to: 0, commitPage: nil)
        } else if farSide != 0, newPage == stripBasePage - farSide {
            stripVelocity = 0
            let width = contentHost.bounds.width
            startSettle(to: CGFloat(farSide) * width, commitPage: nil)
        } else {
            teardownStrip()
            startDrive(to: newPage)
        }
    }

    // MARK: 收尾步进（Hermite：位置+初速连续，末速 0）

    private func startSettle(to target: CGFloat, commitPage: Int?) {
        let width = contentHost.bounds.width
        guard width > 0, nearBand != nil else { teardownStrip(); return }
        let distance = abs(target - stripOffset)
        let duration = min(tuning.pageSettleMaxDuration,
                           max(tuning.pageSettleMinDuration,
                               tuning.pageSettleMaxDuration * Double(distance / width)))
        settleFrom = stripOffset
        settleTarget = target
        settleV0 = stripVelocity
        settleDuration = max(0.001, duration)
        settleCommitPage = commitPage
        settleStart = CACurrentMediaTime()
        teardownNextFrame = false   // 重定向可能发生在上一场收尾的拆除帧窗口内
        stripState = .settling
        startStepper()
    }

    private func stepStrip() {
        if teardownNextFrame { teardownStrip(); return }
        let elapsed = CACurrentMediaTime() - settleStart
        let t = min(1, elapsed / settleDuration)
        // 钳到 {0, from, target} 的凸包：Hermite 的初速项可能瞬时越 0 换侧
        // （far band 错侧露缝重影）或冲过 ±W（边缘露缝），一律夹回。
        let lower = min(0, min(settleFrom, settleTarget))
        let upper = max(0, max(settleFrom, settleTarget))
        stripOffset = min(upper, max(lower,
            hermiteValue(t: t, from: settleFrom, to: settleTarget,
                         v0: settleV0, duration: settleDuration)))
        layoutBands(width: contentHost.bounds.width)
        if t >= 1 { finishSettle() }
    }

    private func finishSettle() {
        stripOffset = settleTarget
        layoutBands(width: contentHost.bounds.width)
        if let page = settleCommitPage {
            settleCommitPage = nil
            model.goToPage(page)   // sink 吸收；底层 SwiftUI 瞬间换页
            Log.panel.info("PAGESTRIP 提交 page=\(page, privacy: .public)")
        }
        teardownNextFrame = true   // 隔帧拆除 band：确认底层已渲染新页再移除
    }

    /// 三次 Hermite 插值：位置 p₀→p₁、初速 v₀、末速 0。
    /// v₀=0 时退化为 smoothstep（≈ easeInOut），与 FR-G2 定稿曲线同族。
    private func hermiteValue(t: Double, from p0: CGFloat, to p1: CGFloat,
                              v0: CGFloat, duration: Double) -> CGFloat {
        let s = CGFloat(t)
        let s2 = s * s, s3 = s2 * s
        let h00 = 2 * s3 - 3 * s2 + 1
        let h10 = s3 - 2 * s2 + s
        let h01 = -2 * s3 + 3 * s2
        return h00 * p0 + h01 * p1 + h10 * CGFloat(duration) * v0
    }

    // MARK: band 构建与布局

    /// 构建一对 band：near = 基准页，far = farPage（pageIndex 需合法）。
    private func buildBands(farPage: Int) {
        guard nearBand == nil,
              farPage >= 0, farPage < model.pages.count,
              stripBasePage >= 0, stripBasePage < model.pages.count,
              let near = makeBand(pageIndex: stripBasePage),
              let far = makeBand(pageIndex: farPage) else { return }
        let width = contentHost.bounds.width
        let side = CGFloat(farPage > stripBasePage ? -1 : 1)
        near.setFrameOrigin(NSPoint(x: stripOffset, y: 0))
        far.setFrameOrigin(NSPoint(x: stripOffset - side * width, y: 0))
        pageStripOverlay.addSubview(near)
        pageStripOverlay.addSubview(far)
        nearBand = near
        farBand = far
        farSide = Int(side)
        // 实时网格让位（同拍结构性变更，必上屏）：页面视觉此后由演出层唯一提供
        model.setPageStripActive(true)
    }

    /// 拖拽跨 0 反向：far band 换侧重建（新侧无相邻页则移除）。
    private func rebuildFarBand(farPage: Int) {
        farBand?.removeFromSuperview()
        farBand = nil
        farSide = 0
        guard farPage >= 0, farPage < model.pages.count,
              let far = makeBand(pageIndex: farPage) else { return }
        let width = contentHost.bounds.width
        let side = CGFloat(farPage > stripBasePage ? -1 : 1)
        far.setFrameOrigin(NSPoint(x: stripOffset - side * width, y: 0))
        pageStripOverlay.addSubview(far)
        farBand = far
        farSide = Int(side)
    }

    /// 单页 band = 点击穿透容器包 NSHostingView(PageBandContent)——复刻实时面板
    /// 的 VStack 骨架（等尺寸占位），网格纵向逐像素同位：基准页 band 完全盖住
    /// 底层实时网格，拖拽时视觉上只剩一条纸带（若用裸 PageGridView，网格在宿主
    /// 内自行居中，与实时位置错开 → 两套图标重影，真机回归实证）。
    /// 图标取当前快照（未加载格显示占位，加载完成后由底层实时视图接棒）。
    private func makeBand(pageIndex: Int) -> PageBandView? {
        let bounds = contentHost.bounds
        guard bounds.width > 0 else { return nil }
        let icons = model.iconImages
        let columns = model.columns
        let iconProvider: (GridEntry) -> NSImage? = { entry in
            guard case .app(let record) = entry else { return nil }
            return icons[record.bundleId]
        }
        let host = NSHostingView(rootView: PageBandContent(
            items: model.pages[pageIndex], columns: columns,
            width: bounds.width, height: bounds.height,
            iconProvider: iconProvider))
        host.frame = bounds
        let band = PageBandView(frame: bounds)
        band.addSubview(host)
        return band
    }

    private func layoutBands(width: CGFloat) {
        nearBand?.setFrameOrigin(NSPoint(x: stripOffset, y: 0))
        farBand?.setFrameOrigin(NSPoint(x: stripOffset - CGFloat(farSide) * width, y: 0))
    }

    private func teardownStrip() {
        nearBand?.removeFromSuperview()
        nearBand = nil
        farBand?.removeFromSuperview()
        farBand = nil
        farSide = 0
        stripOffset = 0
        dragRaw = 0
        stripVelocity = 0
        settleCommitPage = nil
        teardownNextFrame = false
        stripState = .idle
        // 与 band 移除同拍：实时网格复现（此刻 model 已在目标页），交接无缝
        model.setPageStripActive(false)
        stopStepper()
    }

    // MARK: 步进驱动（60Hz Timer；步进逻辑按墙上钟，驱动源可一政替换）

    private func startStepper() {
        guard stepTimer == nil else { return }
        // Timer 挂主线程 RunLoop，回调必在主线程——assumeIsolated 显式声明隔离
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepStrip() }
        }
        RunLoop.main.add(timer, forMode: .common)
        stepTimer = timer
    }

    private func stopStepper() {
        stepTimer?.invalidate()
        stepTimer = nil
    }

    /// 手势总开关关闭时，面板内张开关闭一并停用（design.md §3.4）。
    public func setPinchCloseEnabled(_ enabled: Bool) {
        root.isPinchCloseEnabled = enabled
    }

    // MARK: - 动画（SRS §6：唤起 180ms spring(300,26)；关闭 120ms ease-in）

    private func animateOpen(scaleFrom: Double = 0.96, fade: Bool = true) {
        guard let layer = contentHost.layer else { return }
        layer.removeAllAnimations()
        panel.displayIfNeeded()

        if fade {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: "lz.open.fade")
        }

        let scale = CASpringAnimation(keyPath: "transform.scale")
        scale.fromValue = scaleFrom
        scale.toValue = 1.0
        scale.stiffness = 300
        scale.damping = 26
        scale.mass = 1
        scale.duration = 0.18
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        layer.add(scale, forKey: "lz.open.scale")
    }

    private func animateClose() {
        guard let layer = contentHost.layer else { return }
        layer.removeAllAnimations()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1.0
        fade.toValue = 0.0
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "lz.close.fade")

        // 关闭 = 张开方向的延续：自当前呈现（可能处于张开跟手预览中途）
        // 放大出屏淡出，与手势关闭预览同一视觉语言
        let zoom = CABasicAnimation(keyPath: "transform.scale")
        zoom.fromValue = layer.presentation()?.transform.m11 ?? 1.0
        zoom.toValue = tuning.previewScaleRange
        zoom.duration = 0.12
        zoom.timingFunction = CAMediaTimingFunction(name: .easeIn)
        zoom.fillMode = .forwards
        zoom.isRemovedOnCompletion = false
        layer.add(zoom, forKey: "lz.close.zoom")
    }

    // MARK: - 键盘（FR-S4 / US-T4：Esc 链与方向键在事件分发层拦截，输入法组字期放行）

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }

            // IME 组字期：事件交给输入法（Esc 取消组字 / Enter 上屏 / 方向键选词）
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() {
                return event
            }

            switch Int(event.keyCode) {
            case 53: // Esc
                if self.model.escAction() { return nil }
                self.closePanel(source: .esc)
                return nil
            case 36, 76: // Return / 小回车
                self.model.activateSelected()
                return nil
            case 123: self.model.handleArrow(.left); return nil
            case 124: self.model.handleArrow(.right); return nil
            case 125: self.model.handleArrow(.down); return nil
            case 126: self.model.handleArrow(.up); return nil
            case 116: self.model.pageDelta(1); return nil   // PgDn
            case 121: self.model.pageDelta(-1); return nil  // PgUp
            default:
                // 搜索框未聚焦（捏合唤起）时的裸键入：并入搜索并请求聚焦——
                // 「随时可输入」不打折；后续按键走正常文本链（IME 自然衔接）
                if self.isBareSearchText(event) {
                    self.model.injectSearchText(event.characters ?? "")
                    return nil
                }
                return event
            }
        }
    }

    /// 可入搜索框的裸文本键入：当前第一响应者不是文本编辑器（搜索框未聚焦，
    /// 组字期在其上方已放行）、无命令类修饰键、且字符非控制/功能键。
    private func isBareSearchText(_ event: NSEvent) -> Bool {
        guard !(panel.firstResponder is NSTextView) else { return false }
        guard event.modifierFlags.intersection([.command, .control, .function]).isEmpty,
              let chars = event.characters, !chars.isEmpty else { return false }
        return chars.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
            && !(scalar.value >= 0xF700 && scalar.value <= 0xF8FF)   // 方向/功能键字符区
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - selftest 取证（T2.7：cacheDisplay 走普通视图子树，F9 限制）

    public func captureProof(to path: String) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(root.bounds.width),
                                   pixelsHigh: Int(root.bounds.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        root.cacheDisplay(in: root.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// on-screen 窗口列表断言（US-P1 AC4）。
    public func isOnScreenListed() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }
    }
}
