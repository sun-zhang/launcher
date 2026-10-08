import Foundation

// MARK: - layout.json schema v1（design.md §5.1）

/// 页/格引用。
public struct SlotRef: Codable, Hashable, Sendable {
    public var page: Int
    public var slot: Int
    public init(page: Int, slot: Int) { self.page = page; self.slot = slot }
}

public struct LayoutItem: Codable, Hashable, Sendable {
    public var bundleId: String
    public var slot: Int
    public init(bundleId: String, slot: Int) {
        self.bundleId = bundleId
        self.slot = slot
    }
}

public struct LayoutPage: Codable, Hashable, Sendable {
    public var items: [LayoutItem] = []
    public init(items: [LayoutItem] = []) { self.items = items }
}

public struct Tombstone: Codable, Hashable, Sendable {
    public var bundleId: String
    public var lastSlot: SlotRef
    public init(bundleId: String, lastSlot: SlotRef) {
        self.bundleId = bundleId
        self.lastSlot = lastSlot
    }
}

public struct LayoutGridConfig: Codable, Hashable, Sendable {
    public var columns: Int = 7
    public init(columns: Int = 7) { self.columns = columns }
}

public struct LayoutDocument: Codable, Sendable, Equatable {

    /// 当前默认排序模式（系统应用在前）。变更此值会使存量布局一次性全量重排。
    /// 注：r2 修正全量重排时仍按墓碑旧 slot 锚定、导致前部空页的缺陷（真机实证，
    /// 2026-10-08），升版以触发已写坏布局的自动重排修复。
    public static let currentSortMode = "systemFirst2"

    public var version: Int = 1
    public var grid: LayoutGridConfig = LayoutGridConfig()
    public var pages: [LayoutPage] = []
    public var folders: [Int] = []     // M3 前向兼容，MVP 恒空
    public var hidden: [String] = []   // M3 前向兼容，MVP 恒空
    public var tombstones: [Tombstone] = []
    /// 生成该布局时的排序模式；空 = 旧版纯字母序（首次 rebuild 检测不一致即全量重排）
    public var sortMode: String = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        grid = try c.decode(LayoutGridConfig.self, forKey: .grid)
        pages = try c.decode([LayoutPage].self, forKey: .pages)
        folders = try c.decode([Int].self, forKey: .folders)
        hidden = try c.decode([String].self, forKey: .hidden)
        tombstones = try c.decode([Tombstone].self, forKey: .tombstones)
        sortMode = try c.decodeIfPresent(String.self, forKey: .sortMode) ?? ""
    }
}

// MARK: - 布局构建（纯函数，FR-G4 / FR-I3 / FR-D2）

/// 布局算法：
/// - 首次（无既有布局、列数变化或排序模式变化）：已装应用按默认序
///   （系统应用在前、组内名称本地化自然序）铺页；
/// - 增量：既有合法位置保持不变；墓碑命中（重装）恢复 lastSlot；
///   新应用追加到最后一页末尾（放不下则新开页）——US-I2「≤60s 内出现在最后一页末尾」；
/// - 卸载：从网格移除并写墓碑（重装回原 slot）；
/// - 不变量：任何 bundleId 至多出现一次；页内 slot 不重复。
public enum LayoutBuilder {

    public static let rows = 5

    /// 每页应用容量（设置入口为右下角悬浮角标，不占格位；原首页 -1 方案随
    /// FR-G5 修订废弃——既有布局的首页槽位仍在新容量界内，迁移无感）。
    public static func capacity(columns: Int) -> Int {
        columns * rows
    }

    /// - Parameters:
    ///   - records: 当前已装应用（已按默认序排序）
    ///   - existing: 上次持久化的布局
    ///   - columns: 网格列数（变化触发全量重排）
    public static func build(records: [AppRecord], existing: LayoutDocument, columns: Int) -> LayoutDocument {
        var doc = LayoutDocument()
        doc.grid = LayoutGridConfig(columns: columns)
        doc.sortMode = LayoutDocument.currentSortMode

        let installed = Set(records.map(\.bundleId))
        let structureChanged = existing.grid.columns != columns || existing.pages.isEmpty
            || existing.sortMode != LayoutDocument.currentSortMode

        // 1) 收集可保留的位置（bounds 内、无重复）
        var assigned: [String: SlotRef] = [:]
        var occupied: Set<SlotRef> = []
        var keepSources: [LayoutPage] = structureChanged ? [] : existing.pages

        // 墓碑优先：重装应用回到原 slot（在保留既有位置之前处理，两者不冲突——
        // 既有布局里不可能同时存在该 id，因为卸载时已移除）。
        // 仅增量路径恢复；全量重排（列数/排序模式变化/首建）时旧 slot 语义已失效，
        // 若仍按墓碑锚定，会把整批重排应用挤到锚点之后、留下前部空页
        var restoredTombstones: [Tombstone] = []
        if !structureChanged {
            for t in existing.tombstones where installed.contains(t.bundleId) {
                if t.lastSlot.slot < capacity(columns: columns),
                   !occupied.contains(t.lastSlot) {
                    assigned[t.bundleId] = t.lastSlot
                    occupied.insert(t.lastSlot)
                    restoredTombstones.append(t)
                }
            }
        }

        for (pageIndex, page) in keepSources.enumerated() {
            for item in page.items where installed.contains(item.bundleId) {
                let ref = SlotRef(page: pageIndex, slot: item.slot)
                guard item.slot < capacity(columns: columns),
                      assigned[item.bundleId] == nil,
                      !occupied.contains(ref) else { continue }
                assigned[item.bundleId] = ref
                occupied.insert(ref)
            }
        }

        // 2) 未定位的应用：新装 → 追加末页末尾（默认序）
        let sorted = records.sorted(by: AppRecord.isInDefaultOrder)
        let unplaced = sorted.filter { assigned[$0.bundleId] == nil }

        // 计算现有最大页，准备追加（无既有位置时从第 0 页开始）
        var maxPage = max(0, assigned.values.map(\.page).max() ?? 0)
        var nextSlotInLastPage: [Int: Int] = [:] // page -> 下一个可用 slot（追加用）
        for (page, slots) in Dictionary(grouping: occupied, by: \.page) {
            nextSlotInLastPage[page] = (slots.map(\.slot).max() ?? -1) + 1
        }

        for record in unplaced {
            // 先尝试重装墓碑（上面 bounds 失败的情况不会到这里——restored 已 assigned）
            var placed = false
            // 追加末页末尾
            while !placed {
                let page = maxPage
                var slot = nextSlotInLastPage[page] ?? 0
                let cap = capacity(columns: columns)
                if slot >= cap {
                    maxPage += 1
                    nextSlotInLastPage[maxPage] = 0
                    continue
                }
                // 找该页下一个未被占用的 slot
                while slot < cap, occupied.contains(SlotRef(page: page, slot: slot)) { slot += 1 }
                if slot < cap {
                    let ref = SlotRef(page: page, slot: slot)
                    assigned[record.bundleId] = ref
                    occupied.insert(ref)
                    nextSlotInLastPage[page] = slot + 1
                    placed = true
                } else {
                    maxPage += 1
                    nextSlotInLastPage[maxPage] = 0
                }
            }
        }

        // 3) 页数组重组（含空洞：卸载留下的空位保留给墓碑重装，不前移压缩）
        var pages: [LayoutPage] = []
        let pageCount = assigned.values.map(\.page).max() ?? -1
        if pageCount >= 0 { pages = Array(repeating: LayoutPage(), count: pageCount + 1) }
        var perPage: [Int: [LayoutItem]] = [:]
        for (bundleId, ref) in assigned {
            perPage[ref.page, default: []].append(LayoutItem(bundleId: bundleId, slot: ref.slot))
        }
        for (idx, _) in pages.enumerated() {
            pages[idx].items = (perPage[idx] ?? []).sorted { $0.slot < $1.slot }
        }

        doc.pages = pages

        // 4) 墓碑：已重装的清除，新卸载的记录 lastSlot
        var tombstones: [Tombstone] = []
        let restoredIds = Set(restoredTombstones.map(\.bundleId))
        for t in existing.tombstones where !installed.contains(t.bundleId) && !restoredIds.contains(t.bundleId) {
            tombstones.append(t)
        }
        // 新卸载：在既有布局中但已不在 installed —— 从保留前的 existing 里找最后位置
        if !structureChanged {
            for (pageIndex, page) in existing.pages.enumerated() {
                for item in page.items where !installed.contains(item.bundleId) {
                    let id = item.bundleId
                    if !tombstones.contains(where: { $0.bundleId == id }) {
                        tombstones.append(Tombstone(bundleId: id, lastSlot: SlotRef(page: pageIndex, slot: item.slot)))
                    }
                }
            }
        }
        doc.tombstones = tombstones.sorted { $0.bundleId < $1.bundleId }
        return doc
    }
}

// MARK: - 存取（原子写 / 损坏重建 / 版本前向兼容，FR-D1/D3/D4，US-D1）

public final class LayoutStore {

    public static let defaultURL = URL(fileURLWithPath:
        NSHomeDirectory() + "/Library/Application Support/LauncherZ/layout.json")

    public private(set) var document = LayoutDocument()
    public let fileURL: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    public init(fileURL: URL = LayoutStore.defaultURL) {
        self.fileURL = fileURL
    }

    /// 读取：损坏 → 重建默认 + 告警；更高 schema 版本 → 拒绝并回退默认（US-D1 AC3）。
    public func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            Log.layout.info("layout.json 不存在，使用默认布局")
            document = LayoutDocument()
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let doc = try decoder.decode(LayoutDocument.self, from: data)
            guard doc.version <= 1 else {
                Log.layout.error("layout.json version=\(doc.version) 高于支持的 v1，回退默认布局")
                document = LayoutDocument()
                return
            }
            document = doc
            Log.layout.info("layout.json 读取成功: \(doc.pages.count) 页, \(doc.pages.reduce(0) { $0 + $1.items.count }) 项, 墓碑 \(doc.tombstones.count)")
        } catch {
            Log.layout.error("layout.json 损坏（\(String(describing: error), privacy: .public)），重建默认布局")
            document = LayoutDocument()
        }
    }

    /// 原子写：同目录 tmp + rename（US-D1：任何时刻断电不留半截文件）。
    public func save() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.layout.error("layout.json 写入失败: \(String(describing: error), privacy: .public)")
        }
    }

    /// 以当前已装应用重算并持久化。
    @discardableResult
    public func rebuild(records: [AppRecord], columns: Int) -> LayoutDocument {
        document = LayoutBuilder.build(records: records, existing: document, columns: columns)
        save()
        return document
    }
}
