import Foundation

/// 目录兜底扫描通道（FR-I1：Spotlight 不可用时自动切换）。
public enum DirectoryScanner {

    /// 标准目录（SRS §4.8 FR-X4；Utilities 经由嵌套层级覆盖）。
    public static let standardDirs: [String] = [
        "/Applications",
        NSHomeDirectory() + "/Applications",
        "/System/Applications",
        "/System/Library/CoreServices",
    ]

    /// 枚举 .app 路径（含一级嵌套目录，如 /Applications/Utilities）。
    /// 后台队列调用；隐藏文件跳过。
    public static func scan(extraDirs: [String]) -> [String] {
        let fm = FileManager.default
        let roots = (standardDirs + extraDirs).filter { fm.fileExists(atPath: $0) }
        var result: Set<String> = []

        for root in roots {
            let rootAbs = URL(fileURLWithPath: root)
            // 根目录直接的 .app
            for entry in listChildren(rootAbs) where entry.hasSuffix(".app") {
                result.insert(entry)
            }
            // 一级子目录中的 .app（Utilities、厂商分组目录等）
            for sub in listChildren(rootAbs) {
                var isDir: ObjCBool = false
                guard !sub.hasSuffix(".app"),
                      fm.fileExists(atPath: sub, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                for entry in listChildren(URL(fileURLWithPath: sub)) where entry.hasSuffix(".app") {
                    result.insert(entry)
                }
            }
        }
        return Array(result).sorted()
    }

    private static func listChildren(_ dir: URL) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") }
            .map { dir.appendingPathComponent($0).path }
    }
}
