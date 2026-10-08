import XCTest
@testable import Core

/// 布局构建与持久化（FR-G4/D1/D2，US-D1/US-I2/US-G2）。
final class LayoutStoreTests: XCTestCase {

    private func record(_ name: String, _ id: String = "") -> AppRecord {
        AppRecord(bundleId: id.isEmpty ? "com.test.\(name.lowercased())" : id,
                  name: name, path: "/Applications/\(name).app", version: "1.0", isIOSApp: false)
    }

    /// 指定路径（系统/用户分类由路径前缀决定）。
    private func record(_ name: String, path: String) -> AppRecord {
        AppRecord(bundleId: "com.test.\(name.lowercased())", name: name,
                  path: path, version: "1.0", isIOSApp: false)
    }

    private func ids(_ doc: LayoutDocument) -> [String] {
        doc.pages.flatMap { $0.items.map(\.bundleId) }
    }

    // MARK: 首建：字母序铺页

    func testInitialLayoutAlphabeticalPaged() {
        let records = (0..<80).map { record(String(format: "App%03d", $0)) }
        let doc = LayoutBuilder.build(records: records, existing: LayoutDocument(), columns: 7)
        XCTAssertEqual(doc.grid.columns, 7)
        // 每页容量 35（设置入口为右下角角标，不占格位）
        XCTAssertEqual(doc.pages[0].items.count, 35)
        XCTAssertEqual(doc.pages[1].items.count, 35)
        XCTAssertEqual(doc.pages[2].items.count, 10)
        // 字母序
        XCTAssertEqual(doc.pages[0].items.first?.bundleId, "com.test.app000")
        // 槽位 0..34 顺序无重复
        XCTAssertEqual(Set(doc.pages[0].items.map(\.slot)).count, 35)
    }

    // MARK: 增量：新装追加末页末尾（US-I2 AC1）

    func testNewAppAppendedToLastPageEnd() {
        var records = (0..<10).map { record("App\($0)") }
        let first = LayoutBuilder.build(records: records, existing: LayoutDocument(), columns: 7)

        records.append(record("ZZZ"))
        let second = LayoutBuilder.build(records: records, existing: first, columns: 7)
        let lastPage = second.pages.last!
        let maxSlot = lastPage.items.map(\.slot).max()!
        // 新应用在最后一页的末尾
        XCTAssertTrue(lastPage.items.contains { $0.bundleId == "com.test.zzz" && $0.slot == maxSlot })
        // 既有应用位置不动
        for (pageIndex, page) in first.pages.enumerated() {
            for item in page.items {
                let still = second.pages[pageIndex].items.first { $0.bundleId == item.bundleId }
                XCTAssertEqual(still?.slot, item.slot)
            }
        }
    }

    // MARK: 默认排序：系统应用在前、组内字母序（FR-G4，2026-10-08 修订）

    func testInitialLayoutSystemFirstGrouped() {
        let records = [
            record("WeChat", path: "/Applications/WeChat.app"),
            record("Calculator", path: "/System/Applications/Calculator.app"),
            record("Chrome", path: "/Applications/Chrome.app"),
            record("Notes", path: "/System/Applications/Notes.app"),
        ]
        let doc = LayoutBuilder.build(records: records, existing: LayoutDocument(), columns: 7)
        // 系统块（Calculator、Notes）在前，用户块（Chrome、WeChat）随后
        XCTAssertEqual(ids(doc), ["com.test.calculator", "com.test.notes",
                                  "com.test.chrome", "com.test.wechat"])
    }

    // MARK: 排序模式迁移：旧布局一次性全量重排

    func testLegacySortModeTriggersFullRelayout() {
        let userRecords = (0..<5).map { record("User\($0)") }
        var legacy = LayoutBuilder.build(records: userRecords, existing: LayoutDocument(), columns: 7)
        legacy.sortMode = ""   // 模拟旧版本（纯字母序）生成的布局

        let mixed = userRecords + [
            record("SysA", path: "/System/Applications/SysA.app"),
            record("SysB", path: "/System/Applications/SysB.app"),
        ]
        let relaid = LayoutBuilder.build(records: mixed, existing: legacy, columns: 7)
        XCTAssertEqual(relaid.sortMode, LayoutDocument.currentSortMode)
        // 全量重排：系统块铺在前（而非增量追加到末页末尾），用户块按名称序随后
        XCTAssertEqual(ids(relaid).prefix(2), ["com.test.sysa", "com.test.sysb"])
        XCTAssertEqual(ids(relaid).suffix(5), userRecords.map(\.bundleId))
    }

    func testCurrentSortModeBuildsIncrementally() {
        let userRecords = (0..<5).map { record("User\($0)") }
        let first = LayoutBuilder.build(records: userRecords, existing: LayoutDocument(), columns: 7)
        XCTAssertEqual(first.sortMode, LayoutDocument.currentSortMode)

        // 排序模式一致 → 增量：既有位置不动，新应用追加末页末尾（US-I2）
        var records = userRecords
        records.append(record("ZZZ", path: "/Applications/ZZZ.app"))
        let second = LayoutBuilder.build(records: records, existing: first, columns: 7)
        for (pageIndex, page) in first.pages.enumerated() {
            for item in page.items {
                XCTAssertEqual(second.pages[pageIndex].items
                    .first { $0.bundleId == item.bundleId }?.slot, item.slot)
            }
        }
        XCTAssertEqual(second.pages.last?.items.last?.bundleId, "com.test.zzz")
    }

    func testLegacyJSONWithoutSortModeKeyDecodes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lz-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 旧版 layout.json 无 sortMode 键 → 解码为空串（触发一次全量重排后写入当前值）
        let url = dir.appendingPathComponent("layout.json")
        let legacy = """
        {"version": 1, "grid": {"columns": 7}, "pages": [{"items": [{"bundleId": "com.test.a", "slot": 0}]}], "folders": [], "hidden": [], "tombstones": []}
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let store = LayoutStore(fileURL: url)
        store.load()
        XCTAssertEqual(store.document.sortMode, "")
        XCTAssertEqual(store.document.pages.first?.items.first?.bundleId, "com.test.a")
    }

    func testFullRelayoutDoesNotAnchorRestoredTombstones() {
        // 真机缺陷回归（2026-10-08）：全量重排（排序模式迁移/列数变化）时若仍按
        // 墓碑旧 slot 锚定已重装应用，整批重排应用会被挤到锚点之后、留下前部空页
        let records = (0..<105).map { record(String(format: "App%03d", $0)) }
        let first = LayoutBuilder.build(records: records, existing: LayoutDocument(), columns: 7)
        XCTAssertEqual(first.pages.count, 3)

        // 卸载第 98..104 个（第 2 页 slot 28..34）→ 墓碑指向深处页
        let removed = records.enumerated().filter { !(98...104).contains($0.offset) }.map(\.element)
        let uninstalled = LayoutBuilder.build(records: removed, existing: first, columns: 7)
        XCTAssertEqual(uninstalled.tombstones.count, 7)
        XCTAssertTrue(uninstalled.tombstones.allSatisfy { $0.lastSlot.page == 2 && $0.lastSlot.slot >= 28 })

        // 全部装回 + 旧排序模式 → 触发全量重排（即存量布局迁移路径）
        var stale = uninstalled
        stale.sortMode = ""
        let relaid = LayoutBuilder.build(records: records, existing: stale, columns: 7)
        // 无前部空页：三页全满，从首页 slot 0 按默认序铺开（而非锚定到第 2 页 slot 28+）
        XCTAssertEqual(relaid.pages.count, 3)
        for page in relaid.pages { XCTAssertEqual(page.items.count, 35) }
        XCTAssertEqual(relaid.pages[0].items.first?.slot, 0)
        XCTAssertEqual(relaid.pages[0].items.first?.bundleId, "com.test.app000")
        XCTAssertEqual(relaid.pages[2].items.first?.bundleId, "com.test.app070")
        // 已重装应用的墓碑不再恢复锚定，直接清除
        XCTAssertTrue(relaid.tombstones.isEmpty)
        XCTAssertEqual(ids(relaid).count, 105)
    }

    // MARK: 卸载墓碑 + 重装回原位（US-I2 AC2）

    func testUninstallTombstoneAndReinstallRestore() {
        let records = (0..<10).map { record("App\($0)") }
        let first = LayoutBuilder.build(records: records, existing: LayoutDocument(), columns: 7)
        let originalSlot = first.pages[0].items.first { $0.bundleId == "com.test.app3" }!.slot

        // 卸载 App3
        let removed = records.filter { $0.bundleId != "com.test.app3" }
        let afterUninstall = LayoutBuilder.build(records: removed, existing: first, columns: 7)
        XCTAssertFalse(ids(afterUninstall).contains("com.test.app3"))
        XCTAssertEqual(afterUninstall.tombstones.count, 1)
        XCTAssertEqual(afterUninstall.tombstones.first?.lastSlot, SlotRef(page: 0, slot: originalSlot))

        // 重装 → 回原 slot
        let reinstalled = LayoutBuilder.build(records: records, existing: afterUninstall, columns: 7)
        let back = reinstalled.pages[0].items.first { $0.bundleId == "com.test.app3" }
        XCTAssertEqual(back?.slot, originalSlot)
        XCTAssertTrue(reinstalled.tombstones.isEmpty)
        // 不重复出现（US-G2 AC4）
        XCTAssertEqual(ids(reinstalled).filter { $0 == "com.test.app3" }.count, 1)
    }

    // MARK: 持久化：往返 / 损坏 / 高版本（US-D1）

    func testCodableRoundtrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lz-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("layout.json")
        let store = LayoutStore(fileURL: url)
        let records = (0..<40).map { record("App\($0)") }
        let doc = store.rebuild(records: records, columns: 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let store2 = LayoutStore(fileURL: url)
        store2.load()
        XCTAssertEqual(store2.document, doc)
    }

    func testCorruptedFileRebuildsDefault() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lz-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("layout.json")
        try "{ not valid json !!!".write(to: url, atomically: true, encoding: .utf8)

        let store = LayoutStore(fileURL: url)
        store.load()
        XCTAssertEqual(store.document, LayoutDocument())   // 默认布局
    }

    func testHigherVersionRejected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lz-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("layout.json")
        let future = """
        {"version": 2, "grid": {"columns": 7}, "pages": [], "folders": [], "hidden": [], "tombstones": []}
        """
        try future.write(to: url, atomically: true, encoding: .utf8)

        let store = LayoutStore(fileURL: url)
        store.load()
        XCTAssertEqual(store.document, LayoutDocument())   // 拒绝 v2 → 回退默认
    }

    // MARK: 列数变化：全量重排但墓碑保留

    func testColumnChangeRelayoutsKeepsTombstones() {
        let records = (0..<20).map { record("App\($0)") }
        let first = LayoutBuilder.build(records: records, existing: LayoutDocument(), columns: 7)
        let removed = records.dropLast().map { $0 }
        let uninstalled = LayoutBuilder.build(records: Array(removed), existing: first, columns: 7)
        XCTAssertEqual(uninstalled.tombstones.count, 1)

        let relaid = LayoutBuilder.build(records: Array(removed), existing: uninstalled, columns: 5)
        XCTAssertEqual(relaid.grid.columns, 5)
        XCTAssertEqual(relaid.pages.count, 1)             // 19 个应用全部落在首页（容量 5×5=25）
        XCTAssertLessThanOrEqual(relaid.pages[0].items.count, 25)
        XCTAssertEqual(relaid.tombstones.count, 1)        // 墓碑跨重排保留
    }

    // MARK: 不变量

    func testNoDuplicateBundleIdsAcrossPages() {
        let records = (0..<100).map { record("App\($0)") }
        var doc = LayoutBuilder.build(records: records, existing: LayoutDocument(), columns: 7)
        // 迭代多轮增量（模拟反复装/卸），任何时刻不重复
        for round in 0..<5 {
            let subset = records.filter { $0.bundleId.hashValue % (round + 2) != 0 }
            doc = LayoutBuilder.build(records: subset, existing: doc, columns: 7)
            let all = ids(doc)
            XCTAssertEqual(all.count, Set(all).count)
            // 槽位 bounds 校验
            for (pageIndex, page) in doc.pages.enumerated() {
                let cap = LayoutBuilder.capacity(columns: 7)
                for item in page.items {
                    XCTAssertLessThan(item.slot, cap)
                }
                XCTAssertEqual(Set(page.items.map(\.slot)).count, page.items.count)
            }
        }
    }
}
