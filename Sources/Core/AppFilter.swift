import Foundation

/// 过滤规则（FR-I4 / US-I3）——纯函数，单测覆盖。
public enum AppFilter {

    /// Info.plist 关键字段读取 + 过滤判定。
    /// - Returns: false 表示不应出现在网格中。
    public static func passes(infoDict: [String: Any], path: String,
                              ownBundleId: String, showSystemTools: Bool) -> Bool {
        let bundleId = infoDict["CFBundleIdentifier"] as? String ?? ""
        if bundleId.isEmpty || bundleId == ownBundleId { return false }

        // LSMinimumSystemVersion 超标 → 过滤（解析失败保守放行，X10 不崩溃原则）
        if let minVer = infoDict["LSMinimumSystemVersion"] as? String,
           let required = parseVersion(minVer), required > currentVersion {
            return false
        }

        // ISInvisible 标记 → 过滤
        if (infoDict["ISInvisible"] as? Bool) == true { return false }

        // /System/Library 下的系统内部工具（CoreServices EULA 类、Frameworks/私有框架
        // 里的后台 agent——Spotlight 主通道会把它们全捞出来）默认隐藏，
        // 「显示系统工具」开启后可见；/System/Applications 不受影响
        if path.hasPrefix("/System/Library/"), !showSystemTools {
            return false
        }

        // 非应用包类型（理论上扫描不会命中，防御）
        if let packageType = infoDict["CFBundlePackageType"] as? String, packageType != "APPL" {
            return false
        }
        return true
    }

    /// "13.4.1" → (13, 4, 1)；无法解析返回 nil。
    public static func parseVersion(_ s: String) -> (Int, Int, Int)? {
        let parts = s.split(separator: ".").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        return (parts[0], parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0)
    }

    static let currentVersion: (Int, Int, Int) = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return (v.majorVersion, v.minorVersion, v.patchVersion)
    }()
}

/// 从 .app 路径构建 AppRecord（读 Info.plist，读不到返回 nil）。
public enum AppParser {

    public static func record(atPath path: String, ownBundleId: String,
                              showSystemTools: Bool) -> AppRecord? {
        let infoURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: infoURL) as? [String: Any] else { return nil }
        guard AppFilter.passes(infoDict: dict, path: path,
                               ownBundleId: ownBundleId, showSystemTools: showSystemTools) else { return nil }

        let bundleId = dict["CFBundleIdentifier"] as? String ?? path
        let name = displayName(dict: dict, path: path)
        guard !name.isEmpty else { return nil }
        let version = (dict["CFBundleShortVersionString"] as? String)
            ?? (dict["CFBundleVersion"] as? String) ?? ""
        let isIOSApp = iosMark(dict)

        return AppRecord(bundleId: bundleId, name: name, path: path,
                         version: version, isIOSApp: isIOSApp)
    }

    static func displayName(dict: [String: Any], path: String) -> String {
        // CFBundleDisplayName（本地化优先取 Bundle 的解析结果）> CFBundleName > 文件名
        let bundle = Bundle(url: URL(fileURLWithPath: path))
        let display = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (dict["CFBundleDisplayName"] as? String)
        let base = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? (dict["CFBundleName"] as? String)
        let fileName = URL(fileURLWithPath: path)
            .deletingPathExtension().lastPathComponent
        if let display, !display.isEmpty { return display }
        if let base, !base.isEmpty { return base }
        return fileName
    }

    static func iosMark(_ dict: [String: Any]) -> Bool {
        if let b = dict["LSRequiresIPhoneOS"] as? Bool, b { return true }
        if let s = dict["LSRequiresIPhoneOS"] as? String, s.lowercased() == "true" { return true }
        if let platforms = dict["CFBundleSupportedPlatforms"] as? [String],
           platforms.contains("iPhoneOS") { return true }
        return false
    }
}
