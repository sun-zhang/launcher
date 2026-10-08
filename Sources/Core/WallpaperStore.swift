import AppKit
import CoreImage
import Foundation

/// 壁纸快照（FR-P2「双保险」的实现路径，2026-10-05 重启；2026-10-08 数据源修订）：
/// 首选 `NSWorkspace.desktopImageURL(for:)`——公开 API 且实证完好于 macOS 26 SDK
/// （`AppKit.framework/Headers/NSWorkspace.h` 复核；预研 F9「已移除」系误读
/// swiftinterface——该文件仅含 Swift overlay，ObjC 声明在 Headers/）。provider 型
/// 系统壁纸（Index.plist 的 Files 为空、选择由 Provider 键承载）由系统侧解析为
/// 具体文件；降级走 Sonoma+ 的 `~/Library/Application Support/com.apple.wallpaper/
/// Store/Index.plist` 文件路径解析；最终兜底 `/System/Library/CoreServices/DefaultDesktop.heic`。
///
/// 输出为「按屏幕像素铺满 + 高斯模糊」的位图，由调用方画在窗口内部——
/// 因此 cacheDisplay 取证可捕获（规避 F9 的 behindWindow 不可捕获限制），
/// 模糊强度也按 Launchpad 口径可控（NSVisualEffectView 的模糊半径不可调）。
/// 解析失败返回 nil，调用方回退 behindWindow 毛玻璃（原单一层次）。
///
/// 缓存键 = 像素尺寸 + 来源指纹（候选路径+mtime+Index.plist mtime）：面板每次
/// 唤起重解析，指纹未变直接命中缓存（近零开销），换壁纸即时重渲染、无需重启
/// 进程。视频/动态壁纸（.mov）NSImage 不可解码，自然落到静态候选兜底——实时帧
/// 需 ScreenCaptureKit + 屏幕录制权限，超出 MVP 口径。
public enum WallpaperStore {

    /// Launchpad 口径的模糊半径（pt）；画到 2x 位图上即 ×scale。
    public static let blurRadiusPt: CGFloat = 28

    private static let ciContext = CIContext()
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 4   // 主屏尺寸 × 若干
        return c
    }()

    private static var storeIndexURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()
            + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }
    private static var defaultDesktopURL: URL {
        URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    }
    private static var pictureDirs: [String] {
        ["/Library/Desktop Pictures",
         NSHomeDirectory() + "/Library/Desktop Pictures",
         "/System/Library/Desktop Pictures"]
    }

    // MARK: - 对外

    /// NSWorkspace 公开 API 取当前屏壁纸（主线程调用；provider 型选择由系统侧
    /// 解析为具体文件路径）。nil = 不可用，降级文件级解析。
    @MainActor
    public static func nsworkspaceWallpaperURL(for screen: NSScreen?) -> URL? {
        guard let screen else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    /// 异步取「已模糊」壁纸：内存缓存（指纹未变即命中）→ 解析+渲染（后台）。
    /// 主线程回调；失败回调 nil。nsworkspaceURL 由调用方在主线程先行取得。
    public static func blurredWallpaper(pixelSize: CGSize, scale: CGFloat,
                                        nsworkspaceURL: URL?,
                                        completion: @escaping (NSImage?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let urls = candidates(nsworkspaceURL: nsworkspaceURL)
            let key = cacheKey(pixelSize: pixelSize, scale: scale, candidates: urls)
            if let hit = cache.object(forKey: key) {
                DispatchQueue.main.async { completion(hit) }
                return
            }
            let radius = blurRadiusPt * scale
            let image = urls.lazy.compactMap { url -> NSImage? in
                let src = NSImage(contentsOf: url)
                return src.flatMap { renderBlurred($0, pixelSize: pixelSize, radiusPx: radius) }
            }.first
            if let image { cache.setObject(image, forKey: key) }
            DispatchQueue.main.async { completion(image) }
        }
    }

    // MARK: - 候选解析（按数据源优先级）

    /// 当前壁纸候选：NSWorkspace 公开 API（首选）→ Store Index.plist 显式选择
    /// → 系统默认 → 旧式文件兜底；同路径去重。视频型候选保留——NSImage 解码
    /// 失败自然落到下一候选（静态兜底）。
    public static func candidates(nsworkspaceURL: URL? = nil) -> [URL] {
        var urls: [URL] = []
        if let ws = nsworkspaceURL, FileManager.default.fileExists(atPath: ws.path) {
            urls.append(ws)
        }
        for raw in stringsFromStoreIndex(storeIndexURL) {
            if let url = resolveCandidate(raw) { urls.append(url) }
        }
        if FileManager.default.fileExists(atPath: defaultDesktopURL.path) {
            urls.append(defaultDesktopURL)
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// 数据源状态指纹：候选 路径+mtime 摘要 + Store Index.plist 自身 mtime。
    /// 换壁纸（候选集变化）/ 原文件被原地替换 / Store 更新任一发生即失配。
    public static func fingerprint(candidates: [URL],
                                   indexPlistModificationDate: Date? = nil) -> String {
        var parts = candidates.map { url -> String in
            url.path + "@" + (modificationDate(of: url).map { "\($0.timeIntervalSince1970)" } ?? "nil")
        }
        parts.append("index@" + (indexPlistModificationDate.map { "\($0.timeIntervalSince1970)" } ?? "nil"))
        return parts.joined(separator: "|")
    }

    /// 缓存键 = 像素尺寸@scale + 来源指纹（见 fingerprint）。
    static func cacheKey(pixelSize: CGSize, scale: CGFloat, candidates: [URL]) -> NSString {
        let fp = fingerprint(candidates: candidates,
                             indexPlistModificationDate: modificationDate(of: storeIndexURL))
        return "\(Int(pixelSize.width))x\(Int(pixelSize.height))@\(Int(scale))|\(fp)" as NSString
    }

    private static func modificationDate(of url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    /// 候选字符串 → 已存在文件：绝对路径 / ~/ 前缀 / 裸文件名（标准壁纸目录内查找）。
    public static func resolveCandidate(_ raw: String, searchDirs: [String]? = nil) -> URL? {
        let fm = FileManager.default
        let path: String
        if raw.hasPrefix("/") {
            path = raw
        } else if raw.hasPrefix("~") {
            path = NSString(string: raw).expandingTildeInPath
        } else if raw.contains("."), !raw.contains("/") {
            for dir in searchDirs ?? pictureDirs {
                let candidate = dir + "/" + raw
                if fm.fileExists(atPath: candidate) { return URL(fileURLWithPath: candidate) }
            }
            return nil
        } else {
            return nil
        }
        return fm.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    /// 递归收集 Store Index.plist 中可能指向壁纸的字符串：
    /// Files 数组条目（绝对路径）与 EncodedOptionValues 内嵌 plist 里的选择值。
    public static func stringsFromStoreIndex(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return []
        }
        var out: [String] = []
        collectStrings(plist, into: &out)
        return out
    }

    private static func collectStrings(_ node: Any, into out: inout [String]) {
        switch node {
        case let dict as [String: Any]:
            for (key, value) in dict {
                if key == "Files", let files = value as? [String] {
                    out.append(contentsOf: files)
                } else {
                    collectStrings(value, into: &out)
                }
            }
        case let data as Data:
            // EncodedOptionValues 等内嵌 bplist
            if let inner = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                collectStrings(inner, into: &out)
            }
        case let array as [Any]:
            for item in array { collectStrings(item, into: &out) }
        case let s as String:
            out.append(s)
        default:
            break
        }
    }

    // MARK: - 渲染（cover 铺满 + clamp + 高斯模糊）

    /// 先等比 cover 到「屏幕 + 2×radius 余量」（缩小原图，模糊成本可控），
    /// CIAffineClamp 防边缘透明，再高斯模糊、按画布裁回。
    static func renderBlurred(_ source: NSImage, pixelSize: CGSize, radiusPx: CGFloat) -> NSImage? {
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let margin = radiusPx * 2
        let canvasW = pixelSize.width + margin * 2
        let canvasH = pixelSize.height + margin * 2
        let srcW = CGFloat(cg.width), srcH = CGFloat(cg.height)
        guard srcW > 0, srcH > 0, canvasW > 0, canvasH > 0 else { return nil }

        let scale = max(canvasW / srcW, canvasH / srcH)
        let base = CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ext = base.extent
        let canvasRect = CGRect(x: ext.midX - canvasW / 2, y: ext.midY - canvasH / 2,
                                width: canvasW, height: canvasH)
        let cropped = base.cropped(to: canvasRect)

        guard let clamp = CIFilter(name: "CIAffineClamp"),
              let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        clamp.setValue(cropped, forKey: kCIInputImageKey)
        blur.setValue(clamp.outputImage, forKey: kCIInputImageKey)
        blur.setValue(radiusPx, forKey: "inputRadius")
        guard let output = blur.outputImage?.cropped(to: canvasRect),
              let outCG = ciContext.createCGImage(output, from: canvasRect) else {
            return nil
        }
        return NSImage(cgImage: outCG, size: NSSize(width: outCG.width, height: outCG.height))
    }
}
