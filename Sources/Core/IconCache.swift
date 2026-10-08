import AppKit
import Foundation

/// 图标缓存（FR-I5 / US-I4）：
/// - 内存 NSCache（首屏常驻，系统压力下可逐出）
/// - 磁盘 `~/Library/Caches/LauncherZ/icons/{bundleId}-{version}.png`（128pt@2x = 256px，版本变化重渲染）
/// - 解码/渲染在后台队列；失败用占位图标（X8 不崩溃）
public final class IconCache {

    public static let shared = IconCache()

    public enum Constants {
        public static let pixelSize = 256          // 128pt @2x
        /// 渲染管线版本（r3：按目标尺寸选取高清源表示）：变化即失效旧磁盘缓存
        public static let renderVersion = "r3"
        public static let cacheDir = NSHomeDirectory() + "/Library/Caches/LauncherZ/icons"
    }

    private let memCache = NSCache<NSString, NSImage>()
    private let renderQueue = DispatchQueue(label: "launcherz.icon.render", qos: .userInitiated)

    public init() {
        memCache.countLimit = 512
        try? FileManager.default.createDirectory(atPath: Constants.cacheDir, withIntermediateDirectories: true)
    }

    /// 同步读：仅命中内存缓存（UI 首帧用，未命中返回 nil → 调用方先渲染占位）。
    public func cachedImage(for record: AppRecord) -> NSImage? {
        memCache.object(forKey: record.bundleId as NSString)
    }

    /// 异步取图：磁盘命中 → 直接加载；否则后台渲染 PNG 落盘并回填内存。
    /// 主线程回调；任何失败回调占位图标。
    public func image(for record: AppRecord, completion: @escaping (NSImage) -> Void) {
        if let hit = cachedImage(for: record) {
            completion(hit)
            return
        }
        renderQueue.async { [weak self] in
            let image = self?.loadOrRender(record) ?? IconCache.placeholderImage()
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    // MARK: - 磁盘与渲染（renderQueue）

    private func diskURL(_ record: AppRecord) -> URL {
        // bundleId 理论可含非法路径字符，统一替换
        let safeId = record.bundleId.replacingOccurrences(of: "/", with: "_")
        return URL(fileURLWithPath: "\(Constants.cacheDir)/\(safeId)-\(record.version)-\(Constants.renderVersion).png")
    }

    private func loadOrRender(_ record: AppRecord) -> NSImage {
        let url = diskURL(record)
        if let disk = NSImage(contentsOf: url), disk.isValid {
            memCache.setObject(disk, forKey: record.bundleId as NSString)
            return disk
        }
        // 渲染：系统图标 → 裁透明边距 → 下采样重绘到 256px → PNG 写盘
        let source = NSWorkspace.shared.icon(forFile: record.path)
        guard let rendered = IconCache.trimmedAndDownsampled(source, to: Constants.pixelSize) else {
            return IconCache.placeholderImage()
        }
        if let png = rendered.tiffRepresentation,
           let rep = NSBitmapImageRep(data: png),
           let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url, options: .atomic)
        }
        memCache.setObject(rendered, forKey: record.bundleId as NSString)
        return rendered
    }

    /// 裁掉系统图标自带的透明边距后等比缩放（Launchpad 口径：不同形状图标视觉等大）。
    /// 三步：先缩到 ≤512px 中间图（控制扫描成本）→ 扫 alpha 包围盒 → 裁剪后绘制到 size×size。
    static func trimmedAndDownsampled(_ image: NSImage, to size: Int) -> NSImage? {
        // proposedRect 必须传目标尺寸：传 nil 会按图片自身 point size（NSWorkspace 图标为 32pt）
        // 选中 64px 表示，放大绘制必糊；传 256pt 可选中 512px 高清表示
        var proposedRect = CGRect(x: 0, y: 0, width: size, height: size)
        guard let srcCG = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        // 1) 中间位图（RGBA8，最长边 ≤512）
        let maxEdge: CGFloat = 512
        let srcMaxEdge = CGFloat(max(srcCG.width, srcCG.height))
        let scale: CGFloat = srcMaxEdge > maxEdge ? maxEdge / srcMaxEdge : 1
        let midW = max(1, Int((CGFloat(srcCG.width) * scale).rounded()))
        let midH = max(1, Int((CGFloat(srcCG.height) * scale).rounded()))
        guard let midCtx = CGContext(data: nil, width: midW, height: midH,
                                     bitsPerComponent: 8, bytesPerRow: midW * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        midCtx.interpolationQuality = CGInterpolationQuality.high
        midCtx.draw(srcCG, in: CGRect(x: 0, y: 0, width: midW, height: midH))
        guard let midCG = midCtx.makeImage() else { return nil }

        // 2) alpha 包围盒（>3% 不透明即视为内容）
        guard let bbox = alphaBoundingBox(midCtx) else { return nil }
        var cropRect = bbox
        if bbox.width < CGFloat(midW) * 0.97 || bbox.height < CGFloat(midH) * 0.97 {
            cropRect = bbox.insetBy(dx: -1, dy: -1).intersection(
                CGRect(x: 0, y: 0, width: midW, height: midH))
        } else {
            cropRect = CGRect(x: 0, y: 0, width: midW, height: midH)   // 全满，无需裁
        }

        // 3) 裁剪 → 等比绘制到 size×size（短边贴边、居中）
        guard let cropped = midCG.cropping(to: cropRect),
              let outRep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: size, pixelsHigh: size,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        outRep.size = NSSize(width: size, height: size)
        let cW = CGFloat(cropped.width), cH = CGFloat(cropped.height)
        let drawScale: CGFloat = min(CGFloat(size) / cW, CGFloat(size) / cH)
        let drawW: CGFloat = (cW * drawScale).rounded()
        let drawH: CGFloat = (cH * drawScale).rounded()
        let drawRect = NSRect(x: (CGFloat(size) - drawW) / 2,
                              y: (CGFloat(size) - drawH) / 2,
                              width: drawW, height: drawH)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: outRep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cropped, size: NSSize(width: drawW, height: drawH))
            .draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage()
        out.addRepresentation(outRep)
        return out
    }

    /// 扫描 RGBA8 上下文的 alpha 通道，返回不透明内容包围盒（上下文坐标）。
    private static func alphaBoundingBox(_ ctx: CGContext) -> CGRect? {
        guard let data = ctx.data else { return nil }
        let w = ctx.width, h = ctx.height
        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let threshold: UInt8 = 8
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let rowBase = y * w * 4
            for x in 0..<w where ptr[rowBase + x * 4 + 3] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// 占位图标（扫描期间/损坏兜底，US-I4 / X8）。
    public static func placeholderImage() -> NSImage {
        let symbol = NSImage(systemSymbolName: "app.dashed",
                             accessibilityDescription: "placeholder app icon")
        if let symbol, let tinted = symbol.tinted(.white.withAlphaComponent(0.55)) {
            return tinted
        }
        return NSImage()
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(origin: .zero, size: size)
        NSImage(cgImage: cg, size: size).draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }
}
