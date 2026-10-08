import XCTest
@testable import Core

/// 应用分类（系统/用户，FR-I2）与索引默认排序（FR-G4，2026-10-08 修订）。
final class AppIndexSortTests: XCTestCase {

    private func rec(_ name: String, _ path: String) -> AppRecord {
        AppRecord(bundleId: "com.test.\(name.lowercased())", name: name,
                  path: path, version: "1.0", isIOSApp: false)
    }

    // MARK: isSystemApp 路径分类

    func testSystemAppClassificationByPath() {
        XCTAssertTrue(rec("Chess", "/System/Applications/Chess.app").isSystemApp)
        XCTAssertTrue(rec("Feedback", "/System/Library/CoreServices/Feedback Assistant.app").isSystemApp)
        XCTAssertFalse(rec("Safari", "/Applications/Safari.app").isSystemApp)   // 苹果应用但装在 /Applications，归用户类
        XCTAssertFalse(rec("Demo", NSHomeDirectory() + "/Applications/Demo.app").isSystemApp)
    }

    // MARK: dedupeAndSort：系统在前、组内名称序

    func testDedupeAndSortSystemFirst() {
        let sorted = AppIndex.dedupeAndSort([
            rec("WeChat", "/Applications/WeChat.app"),
            rec("Calculator", "/System/Applications/Calculator.app"),
            rec("Chrome", "/Applications/Chrome.app"),
            rec("Notes", "/System/Applications/Notes.app"),
        ])
        // 系统块（Calculator、Notes）在前，用户块（Chrome、WeChat）随后，组内各按名称序
        XCTAssertEqual(sorted.map(\.name), ["Calculator", "Notes", "Chrome", "WeChat"])
    }

    func testDedupeStillPrefersUserCopy() {
        let sorted = AppIndex.dedupeAndSort([
            rec("Calculator", "/System/Applications/Calculator.app"),
            rec("Calculator", "/Applications/Calculator.app"),
        ])
        XCTAssertEqual(sorted.count, 1)
        XCTAssertEqual(sorted.first?.path, "/Applications/Calculator.app")
    }
}
