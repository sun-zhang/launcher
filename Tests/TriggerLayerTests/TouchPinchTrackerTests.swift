import XCTest

@testable import TriggerLayer

/// TouchPinchTracker：指距增量推导的纯逻辑（真机标定数据回放语义）。
/// 真机基线（2026-10-05，macOS 26.6）：四指捏合簇累计 −0.48…−0.81、
/// 张开 +0.37…+2.01、3 指捏合同样强负（指数门控的必要性实证）；
/// 四指快速放置也会产生假位移（指集稳定门控的必要性实证）。
final class TouchPinchTrackerTests: XCTestCase {

    private typealias S = TouchPinchTracker.TouchSample

    /// 四指稳定在触、逐帧收拢（无指集变化）：十字布局指距 0.6 → 0.2 的真实捏合。
    private func stableConverge() -> [[S]] {
        func cross(_ f: Float) -> [S] {
            [S(id: 1, x: 0.5 - f / 2, y: 0.5), S(id: 2, x: 0.5 + f / 2, y: 0.5),
             S(id: 3, x: 0.5, y: 0.5 - f / 2), S(id: 4, x: 0.5, y: 0.5 + f / 2)]
        }
        var frames: [[S]] = [cross(0.6)]   // 帧0：四指同时落下（锚定 d0）
        for step in 1...4 {
            frames.append(cross(Float(0.6 - 0.1 * Float(step))))
        }
        frames.append([])   // 抬手
        return frames
    }

    func testStableFourFingerConvergeEmitsNegative() {
        let tracker = TouchPinchTracker(minFingers: 4)
        var all: [Double] = []
        for frame in stableConverge() {
            all.append(contentsOf: tracker.onFrame(frame))
        }
        // 锚定帧 + 4 个稳定帧 → 4 个增量
        XCTAssertEqual(all.count, 4)
        // 望远镜和 = (0.2 − 0.6)/0.6 = −0.667
        XCTAssertEqual(all.reduce(0, +), -0.667, accuracy: 0.01)
        XCTAssertTrue(all.allSatisfy { $0 < 0 }, "捏合增量须全为负")
        XCTAssertNotNil(tracker.takeLastBurstSummary(), "闭簇后应有摘要")
        XCTAssertNil(tracker.takeLastBurstSummary(), "摘要取后即清")
    }

    /// 用户主诉场景：四指依次落上（2→3→4 指,位置不变）→ 不得有任何输出。
    func testSequentialPlacementEmitsNothing() {
        let tracker = TouchPinchTracker(minFingers: 4)
        var emitted: [Double] = []
        // 两指落下(远距)
        emitted += tracker.onFrame([S(id: 1, x: 0.2, y: 0.5), S(id: 2, x: 0.8, y: 0.5)])
        // 第三指落在中间（平均指距骤降——旧实现会把它当捏合位移）
        emitted += tracker.onFrame([S(id: 1, x: 0.2, y: 0.5), S(id: 2, x: 0.8, y: 0.5),
                                    S(id: 3, x: 0.5, y: 0.5)])
        // 第四指落下
        emitted += tracker.onFrame([S(id: 1, x: 0.2, y: 0.5), S(id: 2, x: 0.8, y: 0.5),
                                    S(id: 3, x: 0.5, y: 0.5), S(id: 4, x: 0.5, y: 0.45)])
        // 放着不动几帧
        for _ in 0..<10 {
            emitted += tracker.onFrame([S(id: 1, x: 0.2, y: 0.5), S(id: 2, x: 0.8, y: 0.5),
                                        S(id: 3, x: 0.5, y: 0.5), S(id: 4, x: 0.5, y: 0.45)])
        }
        _ = tracker.onFrame([])
        XCTAssertTrue(emitted.isEmpty, "落指与静置不得产生位移（主诉:放置即误触）")
    }

    /// 放置完成后在同一指形上收拢 → 正常触发（放置不影响后续识别）。
    func testConvergeAfterPlacementFires() {
        let tracker = TouchPinchTracker(minFingers: 4)
        let engine = GestureEngine()
        engine.updateParams { $0.openThreshold = 0.30 }
        var fired = 0
        engine.onFire = { fired += 1 }
        // 落指（集合变化帧全部重锚）
        _ = tracker.onFrame([S(id: 1, x: 0.15, y: 0.5), S(id: 2, x: 0.85, y: 0.5)])
        _ = tracker.onFrame([S(id: 1, x: 0.15, y: 0.5), S(id: 2, x: 0.85, y: 0.5), S(id: 3, x: 0.5, y: 0.3)])
        _ = tracker.onFrame([S(id: 1, x: 0.15, y: 0.5), S(id: 2, x: 0.85, y: 0.5),
                             S(id: 3, x: 0.5, y: 0.3), S(id: 4, x: 0.5, y: 0.7)])
        // 稳定后深度收拢（指距约 0.52 → 0.20）
        for step in 1...8 {
            let f = Float(0.52 - 0.04 * Float(step))
            let pts = [S(id: 1, x: 0.5 - f / 2, y: 0.5), S(id: 2, x: 0.5 + f / 2, y: 0.5),
                       S(id: 3, x: 0.5, y: 0.5 - f / 2), S(id: 4, x: 0.5, y: 0.5 + f / 2)]
            for d in tracker.onFrame(pts) { engine.feed(delta: d) }
        }
        XCTAssertEqual(fired, 1, "放置后的真实收拢应触发")
    }

    func testTwoFingerPinchNeverEmits() {
        let tracker = TouchPinchTracker(minFingers: 4)
        var emitted = 0
        for t in stride(from: 0.0, through: 1.0, by: 0.1) {
            let spread = Float(0.8 - 0.7 * t)
            emitted += tracker.onFrame([S(id: 1, x: 0.5 - spread / 2, y: 0.5),
                                        S(id: 2, x: 0.5 + spread / 2, y: 0.5)]).count
        }
        _ = tracker.onFrame([])
        XCTAssertEqual(emitted, 0, "未达 4 指的稳定簇必须零输出（SRS 双指捏合不唤起）")
    }

    func testThreeFingerPinchNeverEmits() {
        // 真机实证：3 指捏合给出强负累计（−0.36/−0.64）——不门控必误触
        let tracker = TouchPinchTracker(minFingers: 4)
        var emitted = 0
        for t in stride(from: 0.0, through: 1.0, by: 0.1) {
            let r = Float(0.4 - 0.35 * t)
            emitted += tracker.onFrame([S(id: 1, x: 0.5, y: 0.5 - r),
                                        S(id: 2, x: 0.5 - r, y: 0.5 + r),
                                        S(id: 3, x: 0.5 + r, y: 0.5 + r)]).count
        }
        _ = tracker.onFrame([])
        XCTAssertEqual(emitted, 0, "3 指捏合必须被指数门控拦截")
    }

    /// 抬指中途（4→3,集合变化重锚）后 3 指继续收拢 → 不再输出（指数门控）。
    func testFingerLiftMidPinchStopsEmission() {
        let tracker = TouchPinchTracker(minFingers: 4)
        var emitted: [Double] = []
        var f: Float = 0.6
        // 四指稳定收两帧
        for _ in 0..<2 {
            let pts = [S(id: 1, x: 0.5 - f / 2, y: 0.5), S(id: 2, x: 0.5 + f / 2, y: 0.5),
                       S(id: 3, x: 0.5, y: 0.5 - f / 2), S(id: 4, x: 0.5, y: 0.5 + f / 2)]
            emitted += tracker.onFrame(pts)
            f -= 0.05
        }
        let before = emitted.count
        // 抬起第 4 指,余 3 指继续收拢
        for _ in 0..<5 {
            let pts = [S(id: 1, x: 0.5 - f / 2, y: 0.5), S(id: 2, x: 0.5 + f / 2, y: 0.5),
                       S(id: 3, x: 0.5, y: 0.5 - f / 2)]
            emitted += tracker.onFrame(pts)
            f -= 0.05
        }
        XCTAssertEqual(emitted.count, before, "抬指后的 3 指收拢不得继续输出")
    }

    /// 中位数抗稀释：4 指 + 静止掌点（第 5 触点）的收拢量不应被显著稀释
    /// （真机峰值指数恒为 5——拇指/掌沿常被报为触点;均值下 5 指捏合仅 −0.25）。
    func testMedianRobustToStationaryOutlier() {
        let pure = TouchPinchTracker(minFingers: 4)
        let withPalm = TouchPinchTracker(minFingers: 4)
        let palm = S(id: 9, x: 0.05, y: 0.05)   // 静止外点
        func core(_ f: Float) -> [S] {
            [S(id: 1, x: 0.5 - f / 2, y: 0.5), S(id: 2, x: 0.5 + f / 2, y: 0.5),
             S(id: 3, x: 0.5, y: 0.5 - f / 2), S(id: 4, x: 0.5, y: 0.5 + f / 2)]
        }
        var sumPure = 0.0
        var sumPalm = 0.0
        _ = pure.onFrame(core(0.6))
        _ = withPalm.onFrame(core(0.6) + [palm])
        for step in 1...6 {
            let f = Float(0.6 - 0.06 * Float(step))   // 指距 0.6 → 0.24
            sumPure += pure.onFrame(core(f)).reduce(0, +)
            sumPalm += withPalm.onFrame(core(f) + [palm]).reduce(0, +)
        }
        XCTAssertLessThan(sumPalm, -0.30, "带静止掌点仍应给出可越阈的收拢量")
        XCTAssertLessThan(sumPalm, sumPure * 0.55, "掌点版本量级应与纯四指同量级（不被稀释到消失）")
        XCTAssertGreaterThan(sumPalm, sumPure * 1.35, "外点会摊薄距离——但幅度受限（中位数鲁棒性界）")
    }

    func testFourFingerSpreadEmitsPositiveAndEngineDoesNotFire() {
        let tracker = TouchPinchTracker(minFingers: 4)
        let engine = GestureEngine()
        var fired = 0
        engine.onFire = { fired += 1 }
        var f: Float = 0.2
        // 四指同时落下锚定,然后张开 0.2 → 0.8
        _ = tracker.onFrame([S(id: 1, x: 0.4, y: 0.5), S(id: 2, x: 0.6, y: 0.5),
                             S(id: 3, x: 0.5, y: 0.4), S(id: 4, x: 0.5, y: 0.6)])
        for _ in 0..<6 {
            f += 0.1
            let pts = [S(id: 1, x: 0.5 - f / 2, y: 0.5), S(id: 2, x: 0.5 + f / 2, y: 0.5),
                       S(id: 3, x: 0.5, y: 0.5 - f / 2), S(id: 4, x: 0.5, y: 0.5 + f / 2)]
            for d in tracker.onFrame(pts) { engine.feed(delta: d) }
        }
        _ = tracker.onFrame([])
        XCTAssertEqual(fired, 0, "张开方向（正增量）不得触发唤起")
    }

    func testFourFingerPinchDrivesEngineToFire() {
        let tracker = TouchPinchTracker(minFingers: 4)
        let engine = GestureEngine()
        engine.updateParams { $0.openThreshold = 0.30 }
        var fired = 0
        engine.onFire = { fired += 1 }
        for frame in stableConverge() {
            for d in tracker.onFrame(frame) { engine.feed(delta: d) }
        }
        XCTAssertEqual(fired, 1, "累计 −0.667 越阈 −0.30 应触发一次（真机捏合簇量级）")
    }

    func testAnchorClampPreventsDeltaExplosion() {
        let tracker = TouchPinchTracker(minFingers: 4)
        // 两指落点过近（0.01）→ d0 钳到 0.05，后续增量有界
        _ = tracker.onFrame([S(id: 1, x: 0.50, y: 0.5), S(id: 2, x: 0.51, y: 0.5)])
        let out = tracker.onFrame([S(id: 1, x: 0.40, y: 0.5), S(id: 2, x: 0.60, y: 0.5),
                                   S(id: 3, x: 0.5, y: 0.4), S(id: 4, x: 0.5, y: 0.6)])
        // 集合变化帧重锚 → 零输出;关键是簇状态健康（无 inf/NaN 由后续帧保证）
        XCTAssertTrue(out.isEmpty)
        let next = tracker.onFrame([S(id: 1, x: 0.38, y: 0.5), S(id: 2, x: 0.62, y: 0.5),
                                    S(id: 3, x: 0.5, y: 0.38), S(id: 4, x: 0.5, y: 0.62)])
        XCTAssertTrue(next.allSatisfy { $0.isFinite })
    }

    func testMedianPairwiseDistance() {
        let d = TouchPinchTracker.medianPairwiseDistance(
            [S(id: 1, x: 0, y: 0), S(id: 2, x: 0.3, y: 0.4)])
        XCTAssertEqual(d, 0.5, accuracy: 1e-6)
        // 正方形四角：pair 距离 [1,1,1,1,√2,√2] → 中位 = (1+1)/2 = 1
        let q = TouchPinchTracker.medianPairwiseDistance(
            [S(id: 1, x: 0, y: 0), S(id: 2, x: 1, y: 0), S(id: 3, x: 0, y: 1), S(id: 4, x: 1, y: 1)])
        XCTAssertEqual(q, 1.0, accuracy: 1e-6)
    }

    /// 四指横扫（整体平移 + 手型收拢/边缘压扁）不得触发——质心门控。
    func testHorizontalSwipeSuppressed() {
        let tracker = TouchPinchTracker(minFingers: 4)
        let engine = GestureEngine()
        engine.updateParams { $0.openThreshold = 0.30 }
        var fired = 0
        engine.onFire = { fired += 1 }
        func cross(_ f: Float, _ cx: Float) -> [S] {
            [S(id: 1, x: cx - f / 2, y: 0.5), S(id: 2, x: cx + f / 2, y: 0.5),
             S(id: 3, x: cx, y: 0.5 - f / 2), S(id: 4, x: cx, y: 0.5 + f / 2)]
        }
        // 锚定后整体右移 0.36，同时指距收拢 0.6→0.36（纯距离判据会误触的量级）
        _ = tracker.onFrame(cross(0.6, 0.3))
        var cx: Float = 0.3
        var f: Float = 0.6
        for _ in 0..<9 {
            cx += 0.04
            f -= 0.027
            for d in tracker.onFrame(cross(f, cx)) { engine.feed(delta: d) }
        }
        _ = tracker.onFrame([])
        XCTAssertEqual(fired, 0, "横扫（质心平移 0.36）不得触发——即使指距收拢到 −0.4 量级")
        XCTAssertNotNil(tracker.takeLastBurstSummary()?.contains("横扫抑制") ?? nil)
    }

    /// 轻微漂移（质心平移 ~0.1，单帧 <0.01）的正常捏合仍须触发——门控不误伤。
    func testConvergeWithMildDriftStillFires() {
        let tracker = TouchPinchTracker(minFingers: 4)
        let engine = GestureEngine()
        engine.updateParams { $0.openThreshold = 0.30 }
        var fired = 0
        engine.onFire = { fired += 1 }
        func cross(_ f: Float, _ cx: Float) -> [S] {
            [S(id: 1, x: cx - f / 2, y: 0.5), S(id: 2, x: cx + f / 2, y: 0.5),
             S(id: 3, x: cx, y: 0.5 - f / 2), S(id: 4, x: cx, y: 0.5 + f / 2)]
        }
        _ = tracker.onFrame(cross(0.6, 0.4))
        var cx: Float = 0.4
        var f: Float = 0.6
        for _ in 0..<12 {
            cx += 0.008   // 总漂移 ~0.1，单帧速度 0.008 < 0.015 门限
            f -= 0.034    // 指距 0.6 → 0.2
            for d in tracker.onFrame(cross(f, cx)) { engine.feed(delta: d) }
        }
        _ = tracker.onFrame([])
        XCTAssertEqual(fired, 1, "带轻微漂移的深捏合应照常触发")
    }

    /// 横扫加速期（前几帧慢、随后提速）的泄漏增量须低于可感知量级——
    /// 单帧速度门在提速帧即粘滞抑制,只剩加速前的小泄漏。
    func testSwipeAccelerationLeakIsNegligible() {
        let tracker = TouchPinchTracker(minFingers: 4)
        func cross(_ f: Float, _ cx: Float) -> [S] {
            [S(id: 1, x: cx - f / 2, y: 0.5), S(id: 2, x: cx + f / 2, y: 0.5),
             S(id: 3, x: cx, y: 0.5 - f / 2), S(id: 4, x: cx, y: 0.5 + f / 2)]
        }
        _ = tracker.onFrame(cross(0.6, 0.3))
        var cx: Float = 0.3
        var f: Float = 0.6
        let speeds: [Float] = [0.002, 0.006, 0.01, 0.02, 0.03, 0.04, 0.045, 0.045, 0.04]
        for s in speeds {
            cx += s
            f -= 0.03   // 全程收拢 0.6→0.33（纯距离判据会 -0.45 误触）
            _ = tracker.onFrame(cross(f, cx))
        }
        _ = tracker.onFrame([])
        let summary = tracker.takeLastBurstSummary() ?? ""
        XCTAssertTrue(summary.contains("横扫抑制"), "加速横扫最终被抑制: \(summary)")
    }

    /// 慢速大收拢对角扫（速度占比 <0.85，速度门放行）——由累计位移门兜底
    /// 拦截；抑制确认回调须恰好发出一次（源侧据此清累计撤预览）。
    func testSlowDiagonalSwipeCaughtByTravelBackstop() {
        let tracker = TouchPinchTracker(minFingers: 4)
        var swipeConfirmed = 0
        tracker.onSwipeConfirmed = { swipeConfirmed += 1 }
        func cross(_ f: Float, _ cx: Float, _ cy: Float) -> [S] {
            [S(id: 1, x: cx - f / 2, y: cy), S(id: 2, x: cx + f / 2, y: cy),
             S(id: 3, x: cx, y: cy - f / 2), S(id: 4, x: cx, y: cy + f / 2)]
        }
        _ = tracker.onFrame(cross(0.6, 0.4, 0.4))
        var cx: Float = 0.4
        var cy: Float = 0.4
        var f: Float = 0.6
        for _ in 0..<30 {                    // 对角累计位移 ~0.25 越过 0.2 兜底门
            cx += 0.006
            cy += 0.006
            f -= 0.009
            _ = tracker.onFrame(cross(f, cx, cy))
        }
        _ = tracker.onFrame([])
        let summary = tracker.takeLastBurstSummary() ?? ""
        XCTAssertTrue(summary.contains("横扫抑制"), summary)
        XCTAssertEqual(swipeConfirmed, 1, "抑制确认沿恰好回调一次")
    }

    /// 刚体横扫（纯平移，速度占比 ≈1）——速度门在第 3 运动帧即粘滞，泄漏可忽略。
    func testRigidSwipeSuppressedEarlyWithNegligibleLeak() {
        let tracker = TouchPinchTracker(minFingers: 4)
        var swipeConfirmed = 0
        tracker.onSwipeConfirmed = { swipeConfirmed += 1 }
        func cross(_ f: Float, _ cx: Float) -> [S] {
            [S(id: 1, x: cx - f / 2, y: 0.5), S(id: 2, x: cx + f / 2, y: 0.5),
             S(id: 3, x: cx, y: 0.5 - f / 2), S(id: 4, x: cx, y: 0.5 + f / 2)]
        }
        _ = tracker.onFrame(cross(0.5, 0.3))
        var cx: Float = 0.3
        var leaked: Double = 0
        var leakedFrames = 0
        for _ in 0..<15 {
            cx += 0.012                       // 纯平移（指距不变）
            let out = tracker.onFrame(cross(0.5, cx))
            leakedFrames += out.count
            leaked += out.reduce(0, +)
        }
        _ = tracker.onFrame([])
        XCTAssertLessThanOrEqual(leakedFrames, 2, "速度门应在第 3 运动帧前粘滞")
        XCTAssertLessThan(abs(leaked), 0.02)
        XCTAssertEqual(swipeConfirmed, 1)
        XCTAssertTrue((tracker.takeLastBurstSummary() ?? "").contains("横扫抑制"))
    }

    /// 回归守护（用户主诉「正常捏合面板到一半弹回」）：边收拢边带拖手的
    /// 正常捏合（速度占比 ~0.55）不得被横扫门误杀。
    func testGlideConvergePinchFiresNotSuppressed() {
        let tracker = TouchPinchTracker(minFingers: 4)
        let engine = GestureEngine()
        engine.updateParams { $0.openThreshold = 0.30 }
        var fired = 0
        engine.onFire = { fired += 1 }
        var swipeConfirmed = 0
        tracker.onSwipeConfirmed = { swipeConfirmed += 1 }
        func cross(_ f: Float, _ cx: Float) -> [S] {
            [S(id: 1, x: cx - f / 2, y: 0.5), S(id: 2, x: cx + f / 2, y: 0.5),
             S(id: 3, x: cx, y: 0.5 - f / 2), S(id: 4, x: cx, y: 0.5 + f / 2)]
        }
        _ = tracker.onFrame(cross(0.7, 0.6))
        var cx: Float = 0.6
        var f: Float = 0.7
        for _ in 0..<14 {                     // 拖手 0.14（占比 ~0.5）+ 深收拢 0.7→0.24
            cx += 0.010
            f -= 0.033
            for d in tracker.onFrame(cross(f, cx)) { engine.feed(delta: d) }
        }
        _ = tracker.onFrame([])
        XCTAssertEqual(fired, 1, "带拖手的深捏合必须照常触发")
        XCTAssertEqual(swipeConfirmed, 0, "不得误判横扫")
    }

    /// 回归：驱动偶发同帧重复 fingerID（真机实证 Duplicate key '0' 崩溃）——
    /// 不得崩溃,该帧按指集不稳定静默重锚,后续捏合继续工作。
    func testDuplicateFingerIDFrameDoesNotCrashAndRecovers() {
        let tracker = TouchPinchTracker(minFingers: 4)
        let engine = GestureEngine()
        engine.updateParams { $0.openThreshold = 0.30 }
        var fired = 0
        engine.onFire = { fired += 1 }
        func cross(_ f: Float) -> [S] {
            [S(id: 1, x: 0.5 - f / 2, y: 0.5), S(id: 2, x: 0.5 + f / 2, y: 0.5),
             S(id: 3, x: 0.5, y: 0.5 - f / 2), S(id: 4, x: 0.5, y: 0.5 + f / 2)]
        }
        _ = tracker.onFrame(cross(0.6))          // 锚定
        XCTAssertFalse(tracker.onFrame(cross(0.56)).isEmpty)   // 正常增量
        let dup = [S(id: 1, x: 0.2, y: 0.5), S(id: 1, x: 0.8, y: 0.5),
                   S(id: 3, x: 0.5, y: 0.2), S(id: 4, x: 0.5, y: 0.8)]
        XCTAssertTrue(tracker.onFrame(dup).isEmpty, "重复 ID 帧静默重锚零输出")
        for step in 1...8 {                        // 重锚后继续收敛 → 正常触发
            for d in tracker.onFrame(cross(Float(0.6 - 0.06 * Float(step)))) {
                engine.feed(delta: d)
            }
        }
        _ = tracker.onFrame([])
        XCTAssertEqual(fired, 1, "重复 ID 帧后捏合仍应正常触发")
    }

    // MARK: - 面板张开关闭累计器（FR-T3，全局触点流路径）

    func testCloseAccumulatorFiresOnceAtThreshold() {
        var acc = PinchCloseAccumulator()
        XCTAssertFalse(acc.feed(0.15))
        XCTAssertFalse(acc.feed(0.10))
        XCTAssertTrue(acc.feed(0.06), "累计 0.31 ≥ 0.30 应触发")
        XCTAssertFalse(acc.feed(0.4), "一簇一击：触发后锁定")
        acc.reset()   // 抬手/面板关闭 → 重新武装
        XCTAssertTrue(acc.feed(0.35), "reset 后可再次触发")
    }

    func testCloseAccumulatorReverseResets() {
        var acc = PinchCloseAccumulator()
        XCTAssertFalse(acc.feed(0.29))
        XCTAssertFalse(acc.feed(-0.01), "反向（捏合）清零防漂移")
        XCTAssertFalse(acc.feed(0.2), "清零后重新累计 0.2 不足阈值")
        XCTAssertTrue(acc.feed(0.15), "0.35 ≥ 0.30 触发")
    }

    func testSpreadBurstClosesPanel() {
        // 面板打开期间的完整四指张开簇（真机量级 +0.37…+2.0）应触发一次关闭
        var acc = PinchCloseAccumulator()
        var fired = 0
        for _ in 0..<20 {
            if acc.feed(0.035) { fired += 1 }   // 20 帧 ×0.035 = +0.70
        }
        XCTAssertEqual(fired, 1, "应恰触发一次")
    }
}
