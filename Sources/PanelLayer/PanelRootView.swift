import AppKit
import Core
import Foundation

/// 面板根视图（AppKit 容器）：
/// - 自身为 `NSVisualEffectView(.sidebar, .behindWindow)`——毛玻璃背景（FR-P2 兜底层）；
/// - 壁纸快照层（WallpaperStore：文件解析 + CoreImage 模糊，Launchpad 口径）插入毛玻璃之上，
///   解析失败保持毛玻璃；快照画在窗口内部，cacheDisplay 取证可捕获（F9 规避）；
/// - 上叠 20% 深色遮罩层与 SwiftUI 内容宿主；
/// - 承接面板内手势（FR-T3 张开关闭，spike 验证的公开 API 路径）与横向滑动翻页（FR-G2）。
///
/// 壁纸快照数据源（2026-10-08 修订）：预研 F9「NSWorkspace 壁纸读取 API 已从
/// macOS 26 SDK 移除」系误读——swiftinterface 仅含 Swift overlay，ObjC 声明在
/// Headers/NSWorkspace.h，desktopImageURL(for:) 实证完好。候选链现为：
/// NSWorkspace 公开 API（provider 型壁纸系统侧解析为具体文件）→ wallpaper
/// Store Index.plist 文件解析 → 系统默认兜底。快照每次唤起重解析、缓存键含
/// 来源指纹（路径+mtime）——用户换壁纸无需重启即生效。
/// 翻页拖拽流(纸带跟手):began 开场、changed 逐事件携带增量、ended 携带松手速度。
enum PageDragEvent {
    case began
    case changed(deltaX: CGFloat)
    case ended(velocityX: CGFloat)   // px/s，最近 ~80ms 事件窗口估算
    case cancelled
}

final class PanelRootView: NSVisualEffectView {

    override var acceptsFirstResponder: Bool { true }

    var onPinchOutClose: (() -> Void)?
    var onPageDrag: ((PageDragEvent) -> Void)?
    /// 手势总开关关闭时置 false（面板内张开关闭一并停用，design.md §3.4）。
    var isPinchCloseEnabled = true

    /// 面板内张开累计（FR-T3，默认阈值 +0.30，SRS §6）。
    private var magnifyAccum: CGFloat = 0

    /// 拖拽速度采样（时间戳为 NSEvent.timestamp 秒，distance 为手势累计位移 pt）。
    private struct DragSample { let time: TimeInterval; let distance: CGFloat }
    private var dragSamples: [DragSample] = []

    let maskView = NSView()
    let wallpaperView = NSView()
    var contentHost: NSView?

    /// 当前背景是否为壁纸快照（取证日志用；false = behindWindow 毛玻璃兜底）。
    private(set) var usesWallpaperSnapshot = false

    override var frame: NSRect {
        didSet { wallpaperView.frame = bounds }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, contentHost == nil else { return }

        material = .sidebar
        blendingMode = .behindWindow
        state = .active

        wallpaperView.wantsLayer = true
        wallpaperView.layer?.contentsGravity = .resizeAspectFill
        wallpaperView.layer?.masksToBounds = true
        wallpaperView.autoresizingMask = [.width, .height]
        wallpaperView.frame = bounds
        wallpaperView.isHidden = true
        addSubview(wallpaperView, positioned: .below, relativeTo: nil)

        maskView.wantsLayer = true
        maskView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        maskView.autoresizingMask = [.width, .height]
        maskView.frame = bounds
        addSubview(maskView, positioned: .above, relativeTo: wallpaperView)
    }

    /// 加载/刷新壁纸快照（启动、屏幕参数变化与每次唤起时调用；异步，主线程落层）。
    /// 缓存键含来源指纹：壁纸未变直接命中（近零开销），变了才后台重渲染——
    /// 渲染完成前保留旧快照，不闪毛玻璃。
    func loadWallpaper() {
        let scale = window?.screen?.backingScaleFactor ?? 2
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        WallpaperStore.blurredWallpaper(
            pixelSize: CGSize(width: size.width * scale, height: size.height * scale),
            scale: scale,
            nsworkspaceURL: WallpaperStore.nsworkspaceWallpaperURL(for: window?.screen)
        ) { [weak self] image in
            guard let self else { return }
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.usesWallpaperSnapshot = false
                return   // 保持毛玻璃兜底
            }
            self.wallpaperView.layer?.contents = cg
            self.wallpaperView.isHidden = false
            self.usesWallpaperSnapshot = true
        }
    }

    func embed(content: NSView) {
        guard contentHost == nil else { return }
        contentHost = content
        content.autoresizingMask = [.width, .height]
        content.frame = bounds
        addSubview(content, positioned: .above, relativeTo: maskView)
    }

    // MARK: 面板内手势

    override func magnify(with event: NSEvent) {
        guard isPinchCloseEnabled else { return }
        // 面板不可见时不累计（事件不应到达，防御）
        magnifyAccum += event.magnification
        if magnifyAccum > 0.30 {
            magnifyAccum = 0
            onPinchOutClose?()
        } else if magnifyAccum < -0.30 {
            magnifyAccum = 0   // 反向捏合清零防漂移
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // 双指横滑纸带跟手：逐事件转发增量，让页面实时跟随手指。
        // 只在 .began/.changed 相位转发——惯性滚动事件 phase == .none，自然排除，
        // 松手后的动量交给控制器的收尾判定（速度 + 进度），不继续喂给跟手。
        switch event.phase {
        case .began:
            dragSamples = [DragSample(time: event.timestamp, distance: 0)]
            onPageDrag?(.began)
        case .changed:
            let cum = (dragSamples.last?.distance ?? 0) + event.scrollingDeltaX
            dragSamples.append(DragSample(time: event.timestamp, distance: cum))
            onPageDrag?(.changed(deltaX: event.scrollingDeltaX))
        case .ended:
            onPageDrag?(.ended(velocityX: dragVelocity()))
            dragSamples = []
        case .cancelled:
            onPageDrag?(.cancelled)
            dragSamples = []
        default:
            break
        }
    }

    /// 松手速度 = 最近 ~80ms 窗口内的位移斜率（窗口内无跨度则视为 0）。
    private func dragVelocity() -> CGFloat {
        guard let last = dragSamples.last, dragSamples.count >= 2 else { return 0 }
        let windowStart = last.time - 0.08
        let start = dragSamples.last(where: { $0.time <= windowStart }) ?? dragSamples[0]
        let dt = last.time - start.time
        guard dt > 0.005 else { return 0 }
        return (last.distance - start.distance) / CGFloat(dt)
    }
}
