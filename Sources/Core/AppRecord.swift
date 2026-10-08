import Foundation

/// 应用索引记录（FR-I2：名称、bundleID、路径、版本、iOS 标记）。
/// `searchKeys` 在索引构建时预计算，搜索热路径零转换（FR-S3 ≤30ms）。
public struct AppRecord: Identifiable, Hashable, Codable, Sendable {
    public let bundleId: String
    public let name: String
    public let path: String
    public let version: String
    public let isIOSApp: Bool
    public let searchKeys: SearchKeys

    public var id: String { bundleId }

    /// 系统自带应用（/System/Applications、/System/Library/CoreServices 扫描根）。
    /// Safari 等装在 /Applications 下的苹果应用会归为用户类，属可接受边缘情况。
    public var isSystemApp: Bool { path.hasPrefix("/System/") }

    /// 默认排序（FR-G4）：系统应用在前，组内按名称本地化自然序。
    public static func isInDefaultOrder(_ a: AppRecord, before b: AppRecord) -> Bool {
        if a.isSystemApp != b.isSystemApp { return a.isSystemApp }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    public init(bundleId: String, name: String, path: String,
                version: String, isIOSApp: Bool, searchKeys: SearchKeys? = nil) {
        self.bundleId = bundleId
        self.name = name
        self.path = path
        self.version = version
        self.isIOSApp = isIOSApp
        if let searchKeys {
            self.searchKeys = searchKeys
        } else {
            let pinyin = Transliterator.pinyin(name)
            self.searchKeys = SearchKeys(
                nameLower: Transliterator.normalize(name),
                pinyinFull: pinyin.full,
                pinyinInitials: pinyin.initials,
                bundleIdLower: bundleId.lowercased())
        }
    }
}

/// 预计算的可搜索键（全部已归一化）。
public struct SearchKeys: Hashable, Codable, Sendable {
    public let nameLower: String      // 归一化应用名
    public let pinyinFull: String     // 全拼音（小写连写）
    public let pinyinInitials: String // 拼音首字母
    public let bundleIdLower: String  // bundleID 小写

    public init(nameLower: String, pinyinFull: String, pinyinInitials: String, bundleIdLower: String) {
        self.nameLower = nameLower
        self.pinyinFull = pinyinFull
        self.pinyinInitials = pinyinInitials
        self.bundleIdLower = bundleIdLower
    }
}
