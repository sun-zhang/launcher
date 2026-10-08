import XCTest
@testable import Core

/// 性能预算（NFR-PERF：键入→结果 ≤30ms，FR-S3）。
final class SearchPerfTests: XCTestCase {

    private func makeFixture(_ count: Int) -> [AppRecord] {
        (0..<count).map { i in
            let zh = ["微信", "网易云音乐", "QQ音乐", "飞书", "钉钉", "有道云笔记", "百度网盘"][i % 7]
            let en = ["App\(String(format: "%03d", i))", "Tool", "Utility", "Reader"][i % 4]
            let name = i % 2 == 0 ? en : "\(zh) \(i)"
            return AppRecord(bundleId: "com.perf.app\(i)", name: name,
                             path: "/Applications/\(i).app", version: "1", isIOSApp: false)
        }
    }

    /// 300 应用上单次查询平均耗时必须远小于 30ms 预算。
    func testSearchUnder30msPerKeystroke() {
        let records = makeFixture(300)
        let queries = ["a", "app", "wx", "weixin", "com.perf", "zz", "网易云", "ＡＰＰ"]
        // 预热（首次查询触发 CFStringTransform 缓存页加载等）
        _ = SearchEngine.search("app", in: records)

        let start = CFAbsoluteTimeGetCurrent()
        var total = 0
        for _ in 0..<20 {
            for q in queries {
                total += SearchEngine.search(q, in: records).count
            }
            _ = total
        }
        let perQuery = (CFAbsoluteTimeGetCurrent() - start) / Double(20 * queries.count) * 1000
        XCTAssertLessThan(perQuery, 30.0, "平均每次查询 \(perQuery)ms 超出 30ms 预算")
    }

    func testSearchMeasure() {
        let records = makeFixture(300)
        measure {
            _ = SearchEngine.search("app", in: records)
            _ = SearchEngine.search("wx", in: records)
            _ = SearchEngine.search("com.perf.app1", in: records)
        }
    }
}
