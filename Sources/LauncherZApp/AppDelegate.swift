import AppKit
import Combine
import Core
import PanelLayer
import SwiftUI
import TriggerLayer

/// 装配层：Core 数据层 + PanelLayer 展示层 + TriggerLayer 触发层（design.md §2）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let selftestRequested: Bool
    private let selftestRounds: Int
    private let selftestLogPath: String
    private let openAfterLaunch: Bool
    private let proofDelay: Double
    private let proofPath: String

    // Core
    private let settings = SettingsStore.shared
    private let layoutStore = LayoutStore()
    private let appIndex = AppIndex()
    private let launcher = AppLauncher()

    // Panel / Trigger
    private var panelController: PanelController!
    private var coordinator: TriggerCoordinator!
    private var hotkeySource: HotkeySource!
    private var gestureSource: MultitouchGestureSource!
    private var toastSource: ToastSource!
    private var hotCornerSource: HotCornerSource?
    private var settingsWindowController: SettingsWindowController?
    /// 手势闸门：面板占用期拦截系统手势事件不下放前台应用（误操作修复）。
    private let gestureShield = GestureEventShield()

    private var indexObserver: AnyCancellable?
    /// 设置通知的重扫去抖（调参滑杆连续触发时合并为一次重扫）。
    private var rescanDebounce: DispatchWorkItem?

    init(selftest: Bool, selftestRounds: Int, selftestLogPath: String, openAfterLaunch: Bool,
         proofDelay: Double = 0, proofPath: String = "logs/panel_proof.png") {
        self.selftestRequested = selftest
        self.selftestRounds = selftestRounds
        self.selftestLogPath = selftestLogPath
        self.openAfterLaunch = openAfterLaunch
        self.proofDelay = proofDelay
        self.proofPath = proofPath
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        layoutStore.load()

        // —— 面板（常驻，F1/F2 参数已内建）——
        let model = PanelViewModel()
        panelController = PanelController(model: model)
        PanelController.shared = panelController
        applyPanelTuning()
        wirePanel(model)

        // —— 触发层 ——
        coordinator = TriggerCoordinator()
        coordinator.panel = panelController
        coordinator.cooldown = settings.triggerCooldown   // FR-T6 调参可调（手势调参区）

        hotkeySource = HotkeySource(settings: settings) { [unowned self] in self.coordinator }
        hotkeySource.start()

        // 气泡提示（启动失败 / 授权引导）：菜单栏图标已移除，仅保留 Toast 能力
        toastSource = ToastSource()

        // —— 手势源（FR-T2：MultitouchSupport 触点流；失败 = 框架/符号不可用 → 黄灯降级，热键形态不受影响）——
        gestureSource = MultitouchGestureSource(settings: settings) { [unowned self] in self.coordinator }
        wireGesture()
        if selftestRequested {
            // selftest：真机触控板的环境手势会与合成断言竞争（实测用户在旁测试即触发）——
            // 冒烟走引擎直喂，不需要真实源；面板内张开关闭开关仍按设置同步
            panelController.setPinchCloseEnabled(settings.gestureEnabled)
        } else {
            applyGestureSetting()
        }

        applyHotCornerSetting()

        // —— 索引 → 布局 → 网格 ——
        indexObserver = appIndex.$records
            .receive(on: RunLoop.main)
            .sink { [weak self] records in
                guard let self else { return }
                let doc = self.layoutStore.rebuild(records: records, columns: self.settings.gridColumns)
                self.panelController.model.install(records: records, layout: doc)
            }
        appIndex.start()

        observeSettings()

        Log.app.info("LauncherZ 启动完成（pid=\(ProcessInfo.processInfo.processIdentifier), build=\(Self.buildStamp, privacy: .public)）")

        if selftestRequested {
            SelfTest.run(controller: panelController, hotkey: hotkeySource,
                         gesture: gestureSource,
                         rounds: selftestRounds, logPath: selftestLogPath)
        } else if openAfterLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.panelController.openPanel(source: .selftest)
            }
        }
        if proofDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + proofDelay) { [weak self] in
                guard let self else { return }
                if !self.panelController.isPanelVisible {
                    self.panelController.openPanel(source: .selftest)
                }
                self.panelController.captureProof(to: self.proofPath)
                Log.selftest.info("取证完成: \(self.proofPath, privacy: .public)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        layoutStore.save()
    }

    /// 构建标识（排障用：确认用户运行的是哪一版演出逻辑）
    static let buildStamp = "20261008-02-移除菜单栏图标+面板左下退出"

    // MARK: - 面板接线

    private func wirePanel(_ model: PanelViewModel) {
        model.onLaunch = { [weak self] record in
            guard let self else { return }
            // FR-L1：退场动画与启动调用并行
            self.panelController.closePanel(source: .launch)
            self.launcher.launch(record)
        }
        model.onOpenSettings = { [weak self] in self?.openSettings() }
        model.onShouldClose = { [weak self] in self?.panelController.closePanel(source: .blankClick) }
        model.onRescan = { [weak self] in self?.appIndex.rescan() }
        // 面板左下角退出角标（菜单栏移除后的唯一退出入口）
        model.onQuit = { NSApp.terminate(nil) }

        launcher.onFailure = { [weak self] name, error in
            self?.toastSource.showToast("启动「\(name)」失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 手势接线（FR-T2/T5）

    private func wireGesture() {
        gestureSource.onProgress = { [unowned self] progress in
            // 双门槛（可调）：簇存活帧数与深度都不足时不转发预览——横扫泄漏增量
            // （累计门兜底前的一段）不足以点亮预览,真捏合自设定深度起跟手
            guard !self.panelController.model.isPanelVisible,
                  self.gestureSource.engine.burstTickCount >= self.settings.gesturePreviewMinTicks,
                  progress > self.settings.gesturePreviewMinProgress else { return }
            self.panelController.updateGesturePreview(progress)
        }
        gestureSource.onGestureEnd = { [unowned self] in
            // 松手/簇结束判定：预览进度已达提交线 → 经仲裁器收尾为打开
            // （openPanel 的预览分支，受 FR-T6 冷却约束——被抑制时同样弹回，
            // 避免预览悬空）；未达提交线 → 弹回。观感与判定在提交线对齐。
            if self.panelController.isGesturePreviewCommitReady,
               self.coordinator.handleTrigger(source: .gesture, action: .open) == .executed { return }
            self.panelController.cancelGesturePreview()
        }
        // 横扫抑制等硬中止：直接撤预览，不参与松手提交
        gestureSource.onGestureAbort = { [unowned self] in
            self.panelController.cancelGesturePreview()
        }
        // FR-T3：面板非激活（不抢焦点），公开 API magnify 收不到手势事件——
        // 张开关闭改由全局触点流驱动（与唤起同源）。
        // 用逻辑开关而非窗口可见性：退场动画期间窗口仍 isVisible（实测 ~0.2s），
        // 窗口级开关会把「关闭后立即再捏合」的前半段增量错路由进张开累计器
        // （真机日志：整簇 -0.626 仅 5 ticks/-0.012 到达引擎 → 漏触发）
        gestureSource.isPanelVisible = { [unowned self] in
            self.panelController.model.isPanelVisible
        }
        gestureSource.onSpreadClose = { [unowned self] in
            self.panelController.closePanel(source: .pinchOut)
        }
        // 张开跟手预览（FR-T3/T5 对称）：面板打开期间随张开进度放大淡出，
        // 停则停、中断弹回、完成关闭
        gestureSource.onCloseProgress = { [unowned self] progress in
            guard self.panelController.model.isPanelVisible else { return }
            self.panelController.updateGestureClosePreview(progress)
        }
        gestureSource.onCloseProgressEnd = { [unowned self] in
            self.panelController.cancelGestureClosePreview()
        }

        // 手势闸门（面板期误操作修复）：面板窗口可见（含跟手预览与退场动画）
        // 或已认领捏合簇仍在途时，吞掉系统手势事件（type29/30/33/34），前台
        // 应用不再收到捏合/张开增量；抬手且面板不可见即恢复放行。拦截窗口
        // 有界，触点识别不受影响（GestureEventShield 文档详述原理与降级）。
        gestureShield.shouldBlock = { [unowned self] in
            self.panelController.isPanelVisible || self.gestureSource.isBurstClaimed
        }
        gestureShield.start()   // 未授权时静默降级：唤起/关闭功能不受影响
    }

    /// 手势开关/调参变化（FR-T2）：关闭即停源（零常驻开销），面板内张开关闭同步停用。
    /// 运行中的参数热更新不重启源（MT 设备重注册会丢手势帧，调参滑杆需要连续跟手）。
    private func applyGestureSetting() {
        panelController.setPinchCloseEnabled(settings.gestureEnabled)
        guard settings.gestureEnabled else {
            gestureSource.stop()
            return
        }
        gestureSource.applySettings()
        if !gestureSource.isHealthy {
            gestureSource.start()
        }
    }

    /// 手势/翻页调参下发到面板（启动与设置变化时）。
    private func applyPanelTuning() {
        var t = panelController.tuning
        t.previewScaleRange = settings.gesturePreviewScaleRange
        t.pageCommitProgress = settings.pageCommitProgress
        t.pageFlickMinProgress = settings.pageFlickMinProgress
        t.pageFlickVelocity = settings.pageFlickVelocity
        t.pageDragDeadZone = settings.pageDragDeadZone
        t.pageDriveDuration = settings.pageDriveDuration
        t.pageSettleMinDuration = settings.pageSettleMinDuration
        t.pageSettleMaxDuration = settings.pageSettleMaxDuration
        t.pinchOutSuppressWindow = settings.gesturePinchOutSuppress
        t.previewCommitProgress = settings.gesturePreviewCommitProgress
        panelController.setTuning(t)
    }

    /// 深链「输入监控」授权页（预研 F6：anchor 可用；TCC 与签名绑定，添加后需重启应用）。
    private func openPermissionSettings() {
        let deeplink = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        if let url = URL(string: deeplink) {
            NSWorkspace.shared.open(url)
        }
        toastSource.showToast("请在「输入监控」中允许 LauncherZ，然后重启应用")
    }

    // MARK: - 设置变化响应

    private func observeSettings() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: .launcherzSettingsChanged, object: nil)
    }

    @objc private func settingsChanged() {
        coordinator.cooldown = settings.triggerCooldown
        applyPanelTuning()
        applyHotCornerSetting()
        applyGestureSetting()
        // 列数变化 → 全量重排（既有位置语义失效，保留墓碑）
        if layoutStore.document.grid.columns != settings.gridColumns {
            layoutStore.rebuild(records: appIndex.records, columns: settings.gridColumns)
            panelController.model.install(records: appIndex.records, layout: layoutStore.document)
        }
        // 显示系统工具 / 扫描目录变化 → 重扫。调参滑杆连续触发通知，
        // 尾随去抖 0.25s 避免每 tick 一次全量重扫
        rescanDebounce?.cancel()
        let rescan = DispatchWorkItem { [weak self] in self?.appIndex.rescan() }
        rescanDebounce = rescan
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: rescan)
    }

    /// 热角开关（FR-T8，默认关）：开启时才创建轮询源，关闭即停用（零常驻开销）。
    /// 驻留/再武装参数实时下发；运行中不重启轮询（避免清掉进行中的驻留计时）。
    private func applyHotCornerSetting() {
        guard settings.hotCornerEnabled else {
            hotCornerSource?.stop()
            return
        }
        if hotCornerSource == nil {
            hotCornerSource = HotCornerSource(settings: settings) { [unowned self] in self.coordinator }
        }
        hotCornerSource?.dwell = settings.hotCornerDwell
        hotCornerSource?.rearmDelay = settings.hotCornerRearmDelay
        if !(hotCornerSource?.isHealthy ?? false) {
            hotCornerSource?.start()
        }
    }

    // MARK: - 设置窗口

    private func openSettings() {
        // 设置窗口是 level 0 普通窗口，面板是 level 21 全屏窗——面板不关会把它完全
        // 盖住；且设置窗口 makeKey 后与面板存在 key 竞态，用户点面板的首击会被
        // 焦点转移吞掉（面板关不掉，真机复现 2026-10-08）。先让面板退场（与启动
        // 应用同一模式：退场动画与设置弹窗并行）。
        if panelController.isPanelVisible {
            panelController.closePanel(source: .settings)
        }
        if let controller = settingsWindowController {
            controller.show()
        } else {
            let controller = SettingsWindowController(hotkeySource: hotkeySource,
                                                      gestureSource: gestureSource,
                                                      appIndex: appIndex,
                                                      settings: settings)
            controller.onRescan = { [weak self] in
                self?.appIndex.rescan()
            }
            settingsWindowController = controller
            controller.show()
        }
    }
}
