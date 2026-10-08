// PanelSpike —— 验证全屏启动面板的窗口工程：全屏覆盖(含菜单栏)、层级、非激活、
//              热键触发(⌥Space, Carbon, 无需权限)、开关延迟、面板内公开API捏合关闭
// 用法: panel-spike --selftest                 自动化自测(约5秒, 无需人工)
//       panel-spike --interactive [--duration] 人工交互模式
import Cocoa
import Carbon.HIToolbox

// MARK: - 日志

final class PLog {
    static var handle: FileHandle?
    static let t0 = Date()
    static func setup(_ path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = FileHandle(forWritingAtPath: url.path)
        log("=== LauncherZ spike: panel, pid=\(ProcessInfo.processInfo.processIdentifier) ===")
    }
    static func log(_ s: String) {
        let line = String(format: "%7.3fs ", Date().timeIntervalSince(t0)) + s
        print(line)
        if let d = (line + "\n").data(using: .utf8) { handle?.write(d) }
    }
}

// MARK: - 面板

final class SpikePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class RootView: NSVisualEffectView {
    var magnifyAccum: CGFloat = 0
    var pinchCloseCount = 0

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let grid = GridView(frame: bounds)
        grid.autoresizingMask = [.width, .height]
        addSubview(grid, positioned: .below, relativeTo: nil)
    }

    // 面板打开期间, 自己就是焦点应用 → 关闭手势走公开API
    override func magnify(with event: NSEvent) {
        magnifyAccum += event.magnification
        PLog.log("本地捏合事件(公开API) delta=\(String(format: "%+.4f", event.magnification)) 累计=\(String(format: "%+.4f", magnifyAccum))")
        if magnifyAccum > 0.30 {
            magnifyAccum = 0
            pinchCloseCount += 1
            PLog.log("→ 累计张开超过阈值 +0.30，关闭面板（第\(pinchCloseCount)次手势关闭）")
            PanelController.shared.close(from: "pinch-out(公开API)")
        } else if magnifyAccum < -0.30 {
            magnifyAccum = 0
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > 2 {
            PLog.log("横向滚动 dx=\(String(format: "%.1f", event.scrollingDeltaX)) phase=\(event.phase.rawValue) → 可用于翻页")
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            PanelController.shared.close(from: "Esc")
        } else {
            super.keyDown(with: event)
        }
    }
}

// 普通NSView画网格(独立视图, 离屏渲染可靠)
final class GridView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let cols = 7, rows = 5, side: CGFloat = 120, radius: CGFloat = 24
        let gapX = (bounds.width - CGFloat(cols) * side) / CGFloat(cols + 1)
        let gapY: CGFloat = 100
        let gridTop = bounds.midY + 200
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 40, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: para,
        ]
        NSColor.white.withAlphaComponent(0.10).setFill()
        var idx = 1
        for r in 0..<rows {
            for c in 0..<cols {
                let x = gapX + CGFloat(c) * (side + gapX)
                let y = gridTop - CGFloat(r) * (side + gapY) - side
                let rect = NSRect(x: x, y: y, width: side, height: side)
                NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                NSString(string: String(idx)).draw(in: rect, withAttributes: attrs)
                idx += 1
            }
        }
    }
}

// MARK: - 控制器

final class PanelController {
    static var shared: PanelController!
    let panel: SpikePanel
    let root: RootView
    var hotkeyOK = false
    var openCount = 0
    var openLatencies: [Double] = []

    init(screenFrame: NSRect) {
        root = RootView(frame: NSRect(origin: .zero, size: screenFrame.size))
        panel = SpikePanel(contentRect: screenFrame,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: 21)          // 盖住菜单栏, 低于系统浮层
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = root
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .active

        let title = NSTextField(labelWithString: "LauncherZ 面板预研 · ⌥Space 开关 · 面板上双指/四指张开关闭 · Esc 关闭")
        title.font = .systemFont(ofSize: 20, weight: .medium)
        title.textColor = .white
        title.sizeToFit()
        title.frame.origin = NSPoint(x: (screenFrame.width - title.frame.width) / 2,
                                     y: screenFrame.height - 130)
        root.addSubview(title)
    }

    func toggle(source: String) {
        panel.isVisible ? close(from: source) : open(from: source)
    }

    func open(from source: String) {
        let t = CFAbsoluteTimeGetCurrent()
        openCount += 1
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()   // 非激活面板: 成为key但不抢夺前台应用激活状态
        panel.initialFirstResponder = root
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        let dt = (CFAbsoluteTimeGetCurrent() - t) * 1000
        openLatencies.append(dt)
        PLog.log("OPEN(#\(openCount) src=\(source)) orderFront+makeKey=\(String(format: "%.1f", dt))ms isVisible=\(panel.isVisible) isKeyWindow=\(panel.isKeyWindow)")
    }

    func close(from source: String) {
        guard panel.isVisible else { return }
        PLog.log("CLOSE(src=\(source))")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            self.panel.orderOut(nil)
            PLog.log("CLOSED (orderOut 完成, 原应用焦点不受影响: 面板为nonactivating)")
        })
    }

    // MARK: 屏上验证 + 截图取证

    func verifyOnScreen() {
        let screen = NSScreen.main!
        PLog.log("验证: 面板frame=\(panel.frame) 主屏frame=\(screen.frame) 全屏覆盖(含菜单栏)=\(panel.frame == screen.frame ? "✅" : "❌")")
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]],
           let mine = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }) {
            let layer = mine[kCGWindowLayer as String] as? Int ?? -99
            PLog.log("验证: 面板出现在系统on-screen窗口列表 ✅ (windowID=\(panel.windowNumber) layer=\(layer) 排名最前=\(list.first?[kCGWindowNumber as String] as? Int == panel.windowNumber ? "是" : "否"))")
        } else {
            PLog.log("验证: 面板未出现在on-screen窗口列表 ❌ isVisible=\(panel.isVisible)")
        }
    }

    func captureProof() {
        // CGWindowListCreateImage 已从 macOS 26 SDK 移除, 改用应用内离屏渲染 (无需屏幕录制权限)
        let path = URL(fileURLWithPath: "logs/panel_proof.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(root.bounds.width),
                                   pixelsHigh: Int(root.bounds.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        root.cacheDisplay(in: root.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: path)
        PLog.log("取证: 已保存面板离屏渲染 logs/panel_proof.png (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    }

    // MARK: 热键 (Carbon, 无需任何权限)

    func installHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var handler: EventHandlerRef?
        let st = InstallEventHandler(GetApplicationEventTarget(), { _, theEvent, userData in
            var hkID = EventHotKeyID()
            GetEventParameter(theEvent, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let pc = Unmanaged<PanelController>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { pc.toggle(source: "hotkey ⌥Space") }
            return noErr
        }, 1, &spec, selfPtr, &handler)
        guard st == noErr else { PLog.log("热键: InstallEventHandler 失败 (\(st))"); return }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4C5A5A31), id: 1)  // 'LZZ1'
        let rs = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id,
                                     GetApplicationEventTarget(), 0, &ref)
        hotkeyOK = (rs == noErr)
        PLog.log("热键 ⌥Space 注册: \(hotkeyOK ? "✅ (Carbon RegisterEventHotKey, 无需辅助功能权限)" : "❌ (\(rs))")")
    }

    func postOptionSpace() {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        for down in [true, false] {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Space), keyDown: down) {
                e.flags = .maskAlternate
                e.post(tap: .cghidEventTap)
            }
        }
        PLog.log("[selftest] 已注入合成 ⌥Space (若未触发多半是无辅助功能权限导致合成事件被丢弃, 需人工确认)")
    }

    func summary() {
        PLog.log("══════════ 面板自测汇总 ══════════")
        PLog.log("热键注册: \(hotkeyOK ? "OK" : "FAIL")  打开次数: \(openCount)  单次打开耗时ms: \(openLatencies.map { String(format: "%.1f", $0) }.joined(separator: ", "))")
        PLog.log("手势关闭(公开API)触发次数: \(root.pinchCloseCount) \(root.pinchCloseCount == 0 ? "(需人工在面板上做张开手势验证)" : "")")
    }
}

// MARK: - main

var interactive = false, selftest = false
var duration = 60.0
var logPath = "logs/panel.log"
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    switch args.removeFirst() {
    case "--selftest": selftest = true
    case "--interactive": interactive = true
    case "--duration": duration = Double(args.removeFirst()) ?? 60
    case "--log": logPath = args.removeFirst()
    default: break
    }
}
if !interactive && !selftest { interactive = true }

NSApplication.shared.setActivationPolicy(.accessory)   // 无Dock图标, 不抢前台
PLog.setup(logPath)
let screen = NSScreen.main!.frame
PanelController.shared = PanelController(screenFrame: screen)
PLog.log("主屏 \(Int(screen.width))x\(Int(screen.height)) 含菜单栏区域 frame=\(screen)")
PanelController.shared.installHotkey()

if selftest {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        PLog.log("[selftest] 流程: 合成热键→应打开→取证→合成热键→应关闭→再打开→直接关闭→退出")
        PanelController.shared.postOptionSpace()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
        if PanelController.shared.openCount == 0 {
            PLog.log("[selftest] 合成热键未触发面板 (可能无AX权限) → 直接打开继续验证面板本身")
            PanelController.shared.open(from: "selftest直开")
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
        PanelController.shared.verifyOnScreen()
        PanelController.shared.captureProof()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
        PanelController.shared.close(from: "selftest")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
        PanelController.shared.postOptionSpace()   // 第二轮: 验证热键开→热键关循环
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5.4) {
        if PanelController.shared.openCount >= 2 { PLog.log("[selftest] 热键循环开关 ✅") }
        else { PLog.log("[selftest] 热键循环未走通 → ⚠️ 合成事件受限, 需人工按 ⌥Space 验证") }
        PanelController.shared.close(from: "selftest收尾")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 6.2) {
        PanelController.shared.summary()
        exit(0)
    }
}

if interactive {
    PLog.log("交互模式: 面板即将打开。请依次尝试—— 1)⌥Space 关闭/打开  2)面板上双指或四指张开(捏合关闭)  3)打开后按Esc  4)双指横向滚动")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        PanelController.shared.open(from: "interactive启动")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        PanelController.shared.summary()
        exit(0)
    }
}

NSApp.run()
