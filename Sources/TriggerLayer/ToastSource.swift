import AppKit
import Foundation

/// 轻量气泡提示（US-L1 AC3）：启动失败 / 授权引导等短暂反馈。
/// 菜单栏状态图标已移除（2026-10-08 需求），仅保留气泡能力，
/// 锚定鼠标所在屏幕的右上角。
@MainActor
public final class ToastSource {

    private var toastPanel: NSPanel?

    public init() {}

    /// 在屏幕右上角弹出短暂提示后自动消失（默认 2.6s；引导类提示可加长）。
    ///
    /// 定位不依赖状态项窗口：macOS 26 上 `statusItem.button?.window` 返回的是停泊
    /// 在屏幕外的模板窗口（实测 frame.x ≈ -4000,气泡随之被放到屏外不可见）——
    /// 改锚定鼠标所在屏幕的右上角，多屏与单屏均确定可见。
    public func showToast(_ text: String, duration: TimeInterval = 2.6) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame   // 已扣除菜单栏

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]

        let visual = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 260, height: 44))
        visual.material = .popover
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.layer?.cornerRadius = 10

        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.frame = NSRect(x: 12, y: 12, width: 236, height: 20)
        visual.addSubview(field)
        panel.contentView = visual

        let x = visible.maxX - 300   // 右上角偏左,不遮最右侧系统项
        let y = visible.maxY - 50
        panel.setFrame(NSRect(x: x, y: y, width: 260, height: 44), display: false)
        panel.orderFrontRegardless()

        toastPanel?.orderOut(nil)
        toastPanel = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak panel] in
            panel?.orderOut(nil)
            if self.toastPanel === panel { self.toastPanel = nil }
        }
    }
}
