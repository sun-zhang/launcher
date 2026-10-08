import XCTest
@testable import Core

/// 过滤规则（FR-I4 / US-I3 单测化）。
final class AppFilterTests: XCTestCase {

    private let baseInfo: [String: Any] = [
        "CFBundleIdentifier": "com.example.app",
        "CFBundleName": "Example",
        "CFBundlePackageType": "APPL",
    ]

    func testMinimumSystemVersionTooHighFiltered() {
        var info = baseInfo
        info["LSMinimumSystemVersion"] = "99.0"
        XCTAssertFalse(AppFilter.passes(infoDict: info, path: "/Applications/Example.app",
                                        ownBundleId: "self", showSystemTools: false))
        info["LSMinimumSystemVersion"] = "13.0"
        XCTAssertTrue(AppFilter.passes(infoDict: info, path: "/Applications/Example.app",
                                       ownBundleId: "self", showSystemTools: false))
    }

    func testUnparsableMinVersionPassesConservatively() {
        var info = baseInfo
        info["LSMinimumSystemVersion"] = "abc"   // 解析失败 → 放行（X10 原则）
        XCTAssertTrue(AppFilter.passes(infoDict: info, path: "/Applications/Example.app",
                                       ownBundleId: "self", showSystemTools: false))
    }

    func testInvisibleFiltered() {
        var info = baseInfo
        info["ISInvisible"] = true
        XCTAssertFalse(AppFilter.passes(infoDict: info, path: "/Applications/Example.app",
                                        ownBundleId: "self", showSystemTools: false))
    }

    func testCoreServicesEULAToolsHiddenByDefault() {
        // US-I3 AC：默认隐藏，开启「显示系统工具」后可见
        XCTAssertFalse(AppFilter.passes(infoDict: baseInfo,
                                        path: "/System/Library/CoreServices/Some Tool.app",
                                        ownBundleId: "self", showSystemTools: false))
        XCTAssertTrue(AppFilter.passes(infoDict: baseInfo,
                                       path: "/System/Library/CoreServices/Some Tool.app",
                                       ownBundleId: "self", showSystemTools: true))
        // 私有框架/框架目录下的后台 agent 同样默认隐藏（Spotlight 通道会捞出）
        XCTAssertFalse(AppFilter.passes(infoDict: baseInfo,
                                        path: "/System/Library/PrivateFrameworks/AOSHeartbeat.app",
                                        ownBundleId: "self", showSystemTools: false))
        // 系统主应用目录不受影响
        XCTAssertTrue(AppFilter.passes(infoDict: baseInfo,
                                       path: "/System/Applications/Chess.app",
                                       ownBundleId: "self", showSystemTools: false))
    }

    func testOwnBundleFiltered() {
        XCTAssertFalse(AppFilter.passes(infoDict: baseInfo, path: "/Applications/Example.app",
                                        ownBundleId: "com.example.app", showSystemTools: false))
    }

    func testEmptyBundleIdFiltered() {
        var info = baseInfo
        info["CFBundleIdentifier"] = ""
        XCTAssertFalse(AppFilter.passes(infoDict: info, path: "/Applications/Example.app",
                                        ownBundleId: "self", showSystemTools: false))
    }

    func testVersionParsing() {
        let v = AppFilter.parseVersion("13.4.1")
        XCTAssertEqual(v?.0, 13)
        XCTAssertEqual(v?.1, 4)
        XCTAssertEqual(AppFilter.parseVersion("26")?.2, 0)
        XCTAssertNil(AppFilter.parseVersion("beta"))
    }
}

/// 解析器：Info.plist → AppRecord 字段（FR-I2）。
final class AppParserTests: XCTestCase {

    private func writeApp(name: String, bundleId: String, extra: [String: Any] = [:],
                          dir: URL) -> String {
        let appURL = dir.appendingPathComponent("\(name).app")
        let contents = appURL.appendingPathComponent("Contents")
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": bundleId, "CFBundleName": name,
                                   "CFBundlePackageType": "APPL"]
        info.merge(extra) { current, _ in current }
        let xml = info.map { key, value in
            let v = value as? String ?? "0"
            return "<key>\(key)</key><string>\(v)</string>"
        }.joined()
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>\(xml)</dict></plist>"
        try? plist.write(to: contents.appendingPathComponent("Info.plist"),
                         atomically: true, encoding: .utf8)
        return appURL.path
    }

    func testRecordFields() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lz-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = writeApp(name: "Demo", bundleId: "com.example.demo",
                            extra: ["CFBundleShortVersionString": "2.1"],
                            dir: dir)
        let record = AppParser.record(atPath: path, ownBundleId: "self", showSystemTools: false)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.bundleId, "com.example.demo")
        XCTAssertEqual(record?.name, "Demo")
        XCTAssertEqual(record?.version, "2.1")
        XCTAssertEqual(record?.isIOSApp, false)
        // 搜索键已预计算
        XCTAssertEqual(record?.searchKeys.nameLower, "demo")

        // iOS 标记
        let iosPath = writeApp(name: "iOSApp", bundleId: "com.example.ios",
                               extra: ["LSRequiresIPhoneOS": "true"], dir: dir)
        let ios = AppParser.record(atPath: iosPath, ownBundleId: "self", showSystemTools: false)
        XCTAssertEqual(ios?.isIOSApp, true)
    }
}
