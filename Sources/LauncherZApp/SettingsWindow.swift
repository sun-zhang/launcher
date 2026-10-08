import AppKit
import Carbon.HIToolbox
import Core
import ServiceManagement
import SwiftUI
import TriggerLayer

/// 设置窗口（FR-X1/X2/X4 + P2 外观项 + 手势开关/阈值 FR-X1/FR-T2）。
final class SettingsWindowController: NSWindowController {

    private let hotkeySource: HotkeySource
    private let gestureSource: MultitouchGestureSource
    private let appIndex: AppIndex
    private let settings: SettingsStore
    var onRescan: (() -> Void)?

    init(hotkeySource: HotkeySource, gestureSource: MultitouchGestureSource,
         appIndex: AppIndex, settings: SettingsStore) {
        self.hotkeySource = hotkeySource
        self.gestureSource = gestureSource
        self.appIndex = appIndex
        self.settings = settings
        let model = SettingsViewModel(hotkeySource: hotkeySource, gestureSource: gestureSource,
                                      appIndex: appIndex, settings: settings)
        let hosting = NSHostingView(rootView: SettingsView(model: model))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "LauncherZ 设置"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    func show() {
        // 先激活再置前：activate 会重申应用的 key window——若放在 makeKeyAndOrderFront
        // 之后，可能把 key 抢回面板（真机复现 2026-10-08，两窗 key 竞态吞点击）
        NSApp.activate(ignoringOtherApps: true)   // 设置窗口是普通窗口，需要激活才能交互
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - ViewModel

@MainActor
final class SettingsViewModel: ObservableObject {

    let hotkeySource: HotkeySource
    let gestureSource: MultitouchGestureSource
    let appIndex: AppIndex
    let settings: SettingsStore

    @Published var hotkeyDescription: String
    @Published var hotkeyError: String?
    @Published var launchAtLogin: Bool
    @Published var loginError: String?
    @Published var columns: Int
    @Published var showSystemTools: Bool
    @Published var extraDirs: [String]
    @Published var indexStatus: String
    @Published var gestureThreshold: Double

    init(hotkeySource: HotkeySource, gestureSource: MultitouchGestureSource,
         appIndex: AppIndex, settings: SettingsStore) {
        self.hotkeySource = hotkeySource
        self.gestureSource = gestureSource
        self.appIndex = appIndex
        self.settings = settings
        hotkeyDescription = HotkeySource.describe(keyCode: settings.hotkeyKeyCode,
                                                  modifiers: settings.hotkeyModifiers)
        launchAtLogin = settings.launchAtLogin
        columns = settings.gridColumns
        showSystemTools = settings.showSystemTools
        extraDirs = settings.extraScanDirs
        indexStatus = "…"
        gestureThreshold = settings.gestureThreshold
        for group in Self.tuningGroups {
            for param in group.params {
                tuningValues[param.id] = param.read(settings)
            }
        }
    }

    func refreshIndexStatus() {
        switch appIndex.state {
        case .ready(let count, let channel):
            indexStatus = "\(count) 个应用 · \(channel == .spotlight ? "Spotlight" : "目录扫描")"
        case .scanning(let channel):
            indexStatus = "扫描中（\(channel == .spotlight ? "Spotlight" : "目录")）…"
        case .idle:
            indexStatus = "未开始"
        }
    }

    // MARK: 热键（US-X1）

    func applyHotkey(keyCode: Int, modifiers: Int) {
        // 至少一个非 Shift 修饰键（防误吞全局单键，US-X1 AC2）
        let required: Int = Int(cmdKey) | Int(optionKey) | Int(controlKey)
        guard modifiers & required != 0 else {
            hotkeyError = "需要至少一个 ⌘/⌥/⌃ 修饰键"
            return
        }
        if let conflict = hotkeySource.updateHotkey(keyCode: keyCode, modifiers: modifiers) {
            hotkeyError = conflict
        } else {
            settings.hotkeyKeyCode = keyCode
            settings.hotkeyModifiers = modifiers
            hotkeyDescription = HotkeySource.describe(keyCode: keyCode, modifiers: modifiers)
            hotkeyError = nil
        }
    }

    // MARK: 开机启动（US-X3）

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = on
            launchAtLogin = on
            loginError = nil
        } catch {
            // 裸二进制（非 .app 包）无法注册——提示而不崩溃
            loginError = "无法\(on ? "注册" : "取消")开机启动：\(error.localizedDescription)"
            launchAtLogin = !on
        }
    }

    // MARK: 手势（FR-T2 / FR-X1）

    func setGestureThreshold(_ value: Double) {
        settings.gestureThreshold = value
        gestureThreshold = settings.gestureThreshold   // 回读钳制值
    }

    var gestureStatusText: String {
        guard settings.gestureEnabled else { return "手势已关闭（热键与热角不受影响）" }
        if !gestureSource.isHealthy {
            return "手势源不可用（系统 MultitouchSupport 框架异常）——捏合唤起暂不可用"
        }
        return "运行中（四指捏合唤起 · 面板内张开关闭）"
    }

    var gestureNeedsPermission: Bool {
        settings.gestureEnabled && !gestureSource.isHealthy
    }

    func openGesturePermissionSettings() {
        let deeplink = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        if let url = URL(string: deeplink) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 手势调参（调试全量开放）

    /// 一行调参：滑杆范围/步长 + 读写闭包（写入即经设置广播热更新到各层）。
    struct TuningParam: Identifiable {
        let id: String
        let label: String
        let range: ClosedRange<Double>
        let step: Double
        let unit: String
        let defaultValue: Double
        let read: (SettingsStore) -> Double
        let write: (SettingsStore, Double) -> Void
    }

    struct TuningGroup: Identifiable {
        var id: String { title }
        let title: String
        let caption: String
        let params: [TuningParam]
    }

    /// 调参分区表（设置界面渲染与「恢复默认」共用）。
    static let tuningGroups: [TuningGroup] = [
        TuningGroup(title: "手势调参 · 捏合唤起", caption: "窗口期 = 无新事件多久后簇结算清零；引擎冷却与仲裁冷却是连击双保险；簇最小事件数仅 toggle 降级模式生效。", params: [
            TuningParam(id: "gestureThreshold", label: "触发阈值", range: 0.2...0.6, step: 0.01, unit: "",
                        defaultValue: 0.35,
                        read: { $0.gestureThreshold }, write: { $0.gestureThreshold = $1 }),
            TuningParam(id: "gestureWindow", label: "手势窗口期", range: 0.1...2.0, step: 0.05, unit: "s",
                        defaultValue: 0.6,
                        read: { $0.gestureWindow }, write: { $0.gestureWindow = $1 }),
            TuningParam(id: "gestureSettleTolerance", label: "结算容差", range: 0.01...0.5, step: 0.01, unit: "s",
                        defaultValue: 0.05,
                        read: { $0.gestureSettleTolerance }, write: { $0.gestureSettleTolerance = $1 }),
            TuningParam(id: "gestureEngineCooldown", label: "引擎冷却", range: 0...3.0, step: 0.05, unit: "s",
                        defaultValue: 0.8,
                        read: { $0.gestureEngineCooldown }, write: { $0.gestureEngineCooldown = $1 }),
            TuningParam(id: "triggerCooldown", label: "仲裁冷却", range: 0...3.0, step: 0.05, unit: "s",
                        defaultValue: 0.8,
                        read: { $0.triggerCooldown }, write: { $0.triggerCooldown = $1 }),
            TuningParam(id: "gestureMinBurstTicks", label: "簇最小事件数", range: 1...60, step: 1, unit: "",
                        defaultValue: 8,
                        read: { Double($0.gestureMinBurstTicks) }, write: { $0.gestureMinBurstTicks = Int($1) }),
        ]),
        TuningGroup(title: "手势调参 · 触点识别", caption: "锚距下限防两指落点过近时增量爆炸（归一化指距的增量分母下限）。", params: [
            TuningParam(id: "gestureMinFingers", label: "最少指数", range: 2...6, step: 1, unit: "指",
                        defaultValue: 4,
                        read: { Double($0.gestureMinFingers) }, write: { $0.gestureMinFingers = Int($1) }),
            TuningParam(id: "gestureAnchorDistanceFloor", label: "锚距下限", range: 0.005...0.3, step: 0.005, unit: "",
                        defaultValue: 0.05,
                        read: { $0.gestureAnchorDistanceFloor }, write: { $0.gestureAnchorDistanceFloor = $1 }),
        ]),
        TuningGroup(title: "手势调参 · 横扫抑制", caption: "占比门限收紧会误杀带拖手的真捏合（真机 0.65~0.75），放宽则漏拦横扫；质心累计位移门兜底慢速斜扫。", params: [
            TuningParam(id: "gestureSwipeCommonRatio", label: "平移占比门限", range: 0.5...0.99, step: 0.01, unit: "",
                        defaultValue: 0.85,
                        read: { $0.gestureSwipeCommonRatio }, write: { $0.gestureSwipeCommonRatio = $1 }),
            TuningParam(id: "gestureVelocityNoiseFloor", label: "速度噪声底", range: 0.0005...0.02, step: 0.0005, unit: "",
                        defaultValue: 0.0025,
                        read: { $0.gestureVelocityNoiseFloor }, write: { $0.gestureVelocityNoiseFloor = $1 }),
            TuningParam(id: "gestureSwipeConsecutiveFrames", label: "连续平移帧数", range: 1...10, step: 1, unit: "帧",
                        defaultValue: 3,
                        read: { Double($0.gestureSwipeConsecutiveFrames) }, write: { $0.gestureSwipeConsecutiveFrames = Int($1) }),
            TuningParam(id: "gestureSwipeCentroidTravel", label: "质心累计位移门", range: 0.05...0.6, step: 0.01, unit: "",
                        defaultValue: 0.2,
                        read: { $0.gestureSwipeCentroidTravel }, write: { $0.gestureSwipeCentroidTravel = $1 }),
        ]),
        TuningGroup(title: "手势调参 · 张开关闭", caption: "面板打开期间四指张开的累计阈值；关闭后再触发抑制防 toggle 降级模式反复重开。", params: [
            TuningParam(id: "gestureCloseThreshold", label: "关闭阈值", range: 0.1...1.5, step: 0.01, unit: "",
                        defaultValue: 0.30,
                        read: { $0.gestureCloseThreshold }, write: { $0.gestureCloseThreshold = $1 }),
            TuningParam(id: "gesturePinchOutSuppress", label: "关闭后再触发抑制", range: 0.3...5.0, step: 0.1, unit: "s",
                        defaultValue: 1.5,
                        read: { $0.gesturePinchOutSuppress }, write: { $0.gesturePinchOutSuppress = $1 }),
        ]),
        TuningGroup(title: "手势调参 · 跟手预览", caption: "预览双门槛：簇存活帧数与捏合深度都不足时不点亮预览（横扫泄漏防护）。缩放范围 = 预览起始的放大倍率。松手提交线：抬手时进度 ≥ 此值直接打开（不透明度到位点与它对齐——全不透明 ⇔ 松手即开）。", params: [
            TuningParam(id: "gesturePreviewMinTicks", label: "预览最小帧数", range: 0...30, step: 1, unit: "帧",
                        defaultValue: 4,
                        read: { Double($0.gesturePreviewMinTicks) }, write: { $0.gesturePreviewMinTicks = Int($1) }),
            TuningParam(id: "gesturePreviewMinProgress", label: "预览最小进度", range: 0...1, step: 0.05, unit: "",
                        defaultValue: 0.4,
                        read: { $0.gesturePreviewMinProgress }, write: { $0.gesturePreviewMinProgress = $1 }),
            TuningParam(id: "gesturePreviewCommitProgress", label: "松手提交线", range: 0.5...0.95, step: 0.05, unit: "",
                        defaultValue: 0.75,
                        read: { $0.gesturePreviewCommitProgress }, write: { $0.gesturePreviewCommitProgress = $1 }),
            TuningParam(id: "gesturePreviewScaleRange", label: "预览缩放范围", range: 1.05...2.0, step: 0.01, unit: "×",
                        defaultValue: 1.35,
                        read: { $0.gesturePreviewScaleRange }, write: { $0.gesturePreviewScaleRange = $1 }),
        ]),
        TuningGroup(title: "手势调参 · 面板翻页", caption: "松手判据与纸带收尾时长（触发式推入 / 惯性收尾）。进度 = |偏移| / 页宽。", params: [
            TuningParam(id: "pageCommitProgress", label: "提交进度", range: 0.1...0.95, step: 0.05, unit: "",
                        defaultValue: 0.5,
                        read: { $0.pageCommitProgress }, write: { $0.pageCommitProgress = $1 }),
            TuningParam(id: "pageFlickMinProgress", label: "甩动最小进度", range: 0.01...0.5, step: 0.01, unit: "",
                        defaultValue: 0.12,
                        read: { $0.pageFlickMinProgress }, write: { $0.pageFlickMinProgress = $1 }),
            TuningParam(id: "pageFlickVelocity", label: "甩动速度门", range: 50...5000, step: 50, unit: "px/s",
                        defaultValue: 600,
                        read: { $0.pageFlickVelocity }, write: { $0.pageFlickVelocity = $1 }),
            TuningParam(id: "pageDragDeadZone", label: "拖拽死区", range: 0...30, step: 1, unit: "pt",
                        defaultValue: 3,
                        read: { $0.pageDragDeadZone }, write: { $0.pageDragDeadZone = $1 }),
            TuningParam(id: "pageDriveDuration", label: "推入时长", range: 0.05...1.0, step: 0.01, unit: "s",
                        defaultValue: 0.22,
                        read: { $0.pageDriveDuration }, write: { $0.pageDriveDuration = $1 }),
            TuningParam(id: "pageSettleMinDuration", label: "收尾最短", range: 0.02...1.0, step: 0.01, unit: "s",
                        defaultValue: 0.15,
                        read: { $0.pageSettleMinDuration }, write: { $0.pageSettleMinDuration = $1 }),
            TuningParam(id: "pageSettleMaxDuration", label: "收尾最长", range: 0.05...1.5, step: 0.01, unit: "s",
                        defaultValue: 0.28,
                        read: { $0.pageSettleMaxDuration }, write: { $0.pageSettleMaxDuration = $1 }),
        ]),
        TuningGroup(title: "手势调参 · 热角", caption: "鼠标角落驻留判定（热角开启时生效）。", params: [
            TuningParam(id: "hotCornerDwell", label: "驻留时长", range: 0.05...2.0, step: 0.01, unit: "s",
                        defaultValue: 0.22,
                        read: { $0.hotCornerDwell }, write: { $0.hotCornerDwell = $1 }),
            TuningParam(id: "hotCornerRearmDelay", label: "再武装延时", range: 0...5.0, step: 0.1, unit: "s",
                        defaultValue: 1.2,
                        read: { $0.hotCornerRearmDelay }, write: { $0.hotCornerRearmDelay = $1 }),
        ]),
    ]

    @Published var tuningValues: [String: Double] = [:]

    func tuningValue(_ param: TuningParam) -> Double {
        tuningValues[param.id] ?? param.defaultValue
    }

    /// 写入（经 SettingsStore 钳制并广播热更新），回读钳制值刷新显示。
    func setTuning(_ param: TuningParam, _ value: Double) {
        param.write(settings, value)
        tuningValues[param.id] = param.read(settings)
        gestureThreshold = settings.gestureThreshold   // 阈值在两处滑杆出现，保持同步
    }

    func resetTuning() {
        for group in Self.tuningGroups {
            for param in group.params {
                param.write(settings, param.defaultValue)
                tuningValues[param.id] = param.read(settings)
            }
        }
        gestureThreshold = settings.gestureThreshold
    }

    /// 数值文本：小数位随步长收窄。
    func tuningText(_ param: TuningParam) -> String {
        let v = tuningValue(param)
        let decimals = param.step >= 1 ? 0 : (param.step >= 0.01 ? 2 : (param.step >= 0.001 ? 3 : 4))
        let number = String(format: "%.\(decimals)f", v)
        return param.unit.isEmpty ? number : "\(number) \(param.unit)"
    }

    // MARK: 外观 / 应用项

    func setColumns(_ value: Int) {
        let clamped = min(9, max(5, value))
        columns = clamped
        settings.gridColumns = clamped
    }

    func setShowSystemTools(_ on: Bool) {
        showSystemTools = on
        settings.showSystemTools = on
    }

    func addDir(_ url: URL) {
        let path = url.path
        guard !extraDirs.contains(path) else { return }
        extraDirs.append(path)
        settings.extraScanDirs = extraDirs
    }

    func removeDir(_ path: String) {
        extraDirs.removeAll { $0 == path }
        settings.extraScanDirs = extraDirs
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Form {
            // 触发
            Section("触发") {
                HStack {
                    Text("全局热键")
                    Spacer()
                    HotkeyRecorderView(model: model)
                }
                Toggle("鼠标移到屏幕右上角唤起", isOn:
                        Binding(get: { model.settings.hotCornerEnabled },
                                set: { model.settings.hotCornerEnabled = $0 }))
                if let err = model.hotkeyError {
                    Text(err).font(.caption).foregroundColor(.red)
                }
                Text("点按右侧框后按下新组合键；热键随时可开关面板。")
                    .font(.caption).foregroundColor(.secondary)
            }

            // 手势（FR-T2/FR-X1）
            Section("手势") {
                Toggle("四指捏合唤起面板", isOn:
                        Binding(get: { model.settings.gestureEnabled },
                                set: { model.settings.gestureEnabled = $0 }))
                HStack {
                    Text(String(format: "触发阈值：%.2f", model.gestureThreshold))
                        .font(.callout)
                    Slider(value: Binding(get: { model.gestureThreshold },
                                          set: { model.setGestureThreshold($0) }),
                           in: 0.2...0.6)
                        .frame(width: 200)
                }
                Text(model.gestureStatusText)
                    .font(.caption).foregroundColor(.secondary)
                if model.gestureNeedsPermission {
                    Button("授权手势监听…") { model.openGesturePermissionSettings() }
                    Text("授权添加 LauncherZ 后需重启应用生效。")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("阈值越大需要捏合得越深才会唤起；面板打开时四指张开即可关闭。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            // 手势调参（调试全量开放）
            Section("手势调参（调试）") {
                HStack {
                    Button("恢复默认参数") { model.resetTuning() }
                    Spacer()
                }
                Text("全部手势链路参数即时生效（热更新，不重启手势源）；持久化于 UserDefaults，也可用 defaults write 逐项调试。")
                    .font(.caption).foregroundColor(.secondary)
            }
            ForEach(SettingsViewModel.tuningGroups) { group in
                Section(group.title) {
                    ForEach(group.params) { param in
                        tuningRow(param)
                    }
                    Text(group.caption)
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            // 应用
            Section("应用") {
                Toggle("显示系统工具（CoreServices 内置工具类）", isOn:
                        Binding(get: { model.showSystemTools },
                                set: { model.setShowSystemTools($0) }))
                HStack {
                    Text("额外扫描目录")
                    Spacer()
                    Button("添加…") { chooseDir() }
                }
                ForEach(model.extraDirs, id: \.self) { dir in
                    HStack {
                        Text(dir).font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { model.removeDir(dir) } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    Text("索引状态：\(model.indexStatus)")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("重扫") {
                        model.settings.showSystemTools = model.showSystemTools  // 触发通知
                        model.refreshIndexStatus()
                    }
                }
            }

            // 外观（P2）
            Section("外观") {
                Stepper("每页列数：\(model.columns)", value:
                        Binding(get: { model.columns }, set: { model.setColumns($0) }),
                        in: 5...9)
                Text("列数变化会按默认排序（系统应用在前）重排网格（墓碑位置保留）。")
                    .font(.caption).foregroundColor(.secondary)
            }

            // 通用
            Section("通用") {
                Toggle("登录时自动启动", isOn:
                        Binding(get: { model.launchAtLogin },
                                set: { model.setLaunchAtLogin($0) }))
                if let err = model.loginError {
                    Text(err).font(.caption).foregroundColor(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        .onAppear { model.refreshIndexStatus() }
    }

    /// 一行调参滑杆：标签 + 滑杆 + 数值（写入即广播热更新）。
    private func tuningRow(_ param: SettingsViewModel.TuningParam) -> some View {
        HStack {
            Text(param.label).font(.callout)
            Spacer()
            Slider(value: Binding(get: { model.tuningValue(param) },
                                  set: { model.setTuning(param, $0) }),
                   in: param.range, step: param.step)
                .frame(width: 170)
            Text(model.tuningText(param))
                .font(.callout).monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
    }

    private func chooseDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择需要额外扫描 .app 的目录"
        if panel.runModal() == .OK, let url = panel.url {
            model.addDir(url)
        }
    }
}

// MARK: - 热键捕获控件（NSViewRepresentable：捕获 keyDown + 修饰键）

struct HotkeyRecorderView: NSViewRepresentable {
    @ObservedObject var model: SettingsViewModel

    func makeNSView(context: Context) -> HotkeyRecorder {
        let view = HotkeyRecorder()
        view.onCapture = { keyCode, modifiers in
            model.applyHotkey(keyCode: keyCode, modifiers: modifiers)
        }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorder, context: Context) {
        nsView.currentDescription = model.hotkeyDescription
    }
}

/// Carbon 修饰键 → NSEvent 修饰键换算在捕获处完成。
final class HotkeyRecorder: NSView {

    var onCapture: ((Int, Int) -> Void)?
    var currentDescription = "" {
        didSet { needsDisplay = true }
    }
    var isRecording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 26) }

    private var recordedModifiers: Int = 0

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let text = (isRecording ? "按下新热键…" : currentDescription) as NSString
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attr)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2),
                  withAttributes: attr)
    }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        window?.makeFirstResponder(self)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else {
            super.flagsChanged(with: event)
            return
        }
        recordedModifiers = carbonModifiers(from: event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        // Esc 取消录制；功能键忽略
        if event.keyCode == 53 {
            isRecording = false
            return
        }
        let carbonMods = recordedModifiers != 0
            ? recordedModifiers
            : carbonModifiers(from: event.modifierFlags)
        isRecording = false
        onCapture?(Int(event.keyCode), carbonMods)
    }

    /// NSEvent.ModifierFlags → Carbon 修饰键掩码（RegisterEventHotKey 用）。
    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.command) { result |= Int(cmdKey) }
        if flags.contains(.option) { result |= Int(optionKey) }
        if flags.contains(.control) { result |= Int(controlKey) }
        if flags.contains(.shift) { result |= Int(shiftKey) }
        return result
    }
}
