import Foundation

/// 搜索引擎（FR-S1..S3）：预排序数组上的线性匹配，无正则。
/// 匹配层级（严格递增的排序权重，US-S1 AC：前缀优先于子串）：
///   0 应用名前缀 → 1 拼音首字母前缀 → 2 全拼前缀 → 3 应用名子串 → 4 bundleID 子串
public enum SearchEngine {

    public static func search(_ rawQuery: String, in records: [AppRecord]) -> [AppRecord] {
        let query = Transliterator.normalize(rawQuery)
        guard !query.isEmpty else { return records }

        var scored: [(record: AppRecord, tier: Int)] = []
        scored.reserveCapacity(min(records.count, 64))
        for r in records {
            if let tier = matchTier(query: query, keys: r.searchKeys) {
                scored.append((r, tier))
            }
        }
        // 稳定排序：先按层级，再与网格默认排序一致（系统应用在前 → 名称序），保证确定性
        scored.sort { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            return AppRecord.isInDefaultOrder(a.record, before: b.record)
        }
        return scored.map(\.record)
    }

    @inline(__always)
    private static func matchTier(query: String, keys: SearchKeys) -> Int? {
        if keys.nameLower.hasPrefix(query) { return 0 }
        if keys.pinyinInitials.hasPrefix(query) { return 1 }
        if keys.pinyinFull.hasPrefix(query) { return 2 }
        if keys.nameLower.contains(query) { return 3 }
        if keys.bundleIdLower.contains(query) { return 4 }
        return nil
    }
}
