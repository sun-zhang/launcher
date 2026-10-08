import XCTest
@testable import Core

/// 搜索匹配（FR-S1/S2，US-S1；X4 边界）。
final class SearchEngineTests: XCTestCase {

    private func make(_ name: String, _ bundleId: String) -> AppRecord {
        AppRecord(bundleId: bundleId, name: name, path: "/Applications/\(name).app",
                  version: "1.0", isIOSApp: false)
    }

    private var fixture: [AppRecord] {
        [
            make("Safari", "com.apple.Safari"),
            make("微信", "com.tencent.xinWeChat"),
            make("GitHub Desktop", "com.github.GitHubDesktop"),
            make("SafeInCloud", "com.safeincloud.mac"),
            make("网易云音乐", "com.netease.163music"),
            make("Surge", "com.nssurge.surge-mac"),
        ]
    }

    func testPrefixRanksBeforeSubstring() {
        // US-S1 AC1："saf" → Safari（前缀）应排 SafeInCloud（子串）之前
        let hits = SearchEngine.search("saf", in: fixture)
        XCTAssertEqual(hits.first?.name, "Safari")
        XCTAssertTrue(hits.contains { $0.name == "SafeInCloud" })
        XCTAssertGreaterThan(hits.firstIndex(where: { $0.name == "SafeInCloud" })!,
                             hits.firstIndex(where: { $0.name == "Safari" })!)
    }

    func testPinyinInitialsMatchChineseName() {
        // US-S1 AC2："wx" 命中「微信」
        let hits = SearchEngine.search("wx", in: fixture)
        XCTAssertTrue(hits.contains { $0.name == "微信" })
        // "wyy" 命中「网易云音乐」（wǎng yì yún）
        let music = SearchEngine.search("wyy", in: fixture)
        XCTAssertTrue(music.contains { $0.name == "网易云音乐" })
    }

    func testFullPinyinMatch() {
        let hits = SearchEngine.search("weixin", in: fixture)
        XCTAssertTrue(hits.contains { $0.name == "微信" })
    }

    func testBundleIdMatch() {
        // US-S1 AC3："com.apple.Sa" 命中 Safari
        let hits = SearchEngine.search("com.apple.sa", in: fixture)
        XCTAssertEqual(hits.first?.bundleId, "com.apple.Safari")
    }

    func testNormalizationX4() {
        // X4：空格/大写/全角不敏感，不崩溃
        XCTAssertTrue(SearchEngine.search("SAF", in: fixture).contains { $0.name == "Safari" })
        XCTAssertTrue(SearchEngine.search("  saf ", in: fixture).contains { $0.name == "Safari" })
        XCTAssertTrue(SearchEngine.search("ＳＡＦ", in: fixture).contains { $0.name == "Safari" })
        XCTAssertTrue(SearchEngine.search("github desktop", in: fixture)
            .contains { $0.name == "GitHub Desktop" })
        // 无结果返回空
        XCTAssertTrue(SearchEngine.search("zzzz不存在的应用", in: fixture).isEmpty)
    }

    func testEmptyQueryReturnsAll() {
        XCTAssertEqual(SearchEngine.search("", in: fixture).count, fixture.count)
        XCTAssertEqual(SearchEngine.search("   ", in: fixture).count, fixture.count)
    }

    func testSystemAppFirstWithinSameTier() {
        // FR-G4 2026-10-08 修订：同匹配层级内系统应用排在用户应用之前（与网格默认排序一致）
        let stickies = AppRecord(bundleId: "com.apple.stickies", name: "Stickies",
                                 path: "/System/Applications/Stickies.app",
                                 version: "1.0", isIOSApp: false)
        let hits = SearchEngine.search("s", in: fixture + [stickies])
        XCTAssertEqual(hits.first?.name, "Stickies")
        // 其余同层级结果仍按名称序
        XCTAssertEqual(hits.map(\.name).dropFirst().prefix(3), ["Safari", "SafeInCloud", "Surge"])
    }

    func testDeterministicOrder() {
        let a = SearchEngine.search("s", in: fixture)
        let b = SearchEngine.search("s", in: fixture)
        XCTAssertEqual(a.map(\.bundleId), b.map(\.bundleId))
    }
}

/// 拉丁化/归一化（FR-S2 支撑）。
final class TransliteratorTests: XCTestCase {

    func testChinesePinyin() {
        let r = Transliterator.pinyin("微信")
        XCTAssertEqual(r.initials, "wx")
        XCTAssertEqual(r.full, "weixin")
    }

    func testMixedContent() {
        let r = Transliterator.pinyin("GitHub Desktop")
        XCTAssertEqual(r.full, "githubdesktop")
        XCTAssertEqual(r.initials, "githubdesktop")
    }

    func testChineseEnglishMixed() {
        let r = Transliterator.pinyin("微信WeChat")
        XCTAssertEqual(r.initials, "wxwechat")
        XCTAssertTrue(r.full.hasPrefix("weixin"))
    }

    func testNormalizeFullWidthAndCase() {
        XCTAssertEqual(Transliterator.normalize("ＳＡＦ"), "saf")
        XCTAssertEqual(Transliterator.normalize("  A　 B  "), "a b")
    }
}
