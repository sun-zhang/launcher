import XCTest

@testable import TriggerLayer

/// GestureEngine 状态机单测（design.md §3.4 / §8；覆盖 US-T2 AC、X1 冷却连击、FR-T5 进度）。
/// 时钟注入,事件序列全部同步驱动。
final class GestureEngineTests: XCTestCase {

    private var engine: GestureEngine!
    private var clock: Date!
    private var fires: Int!
    private var ends: Int!
    private var progressValues: [Double]!

    override func setUp() {
        super.setUp()
        clock = Date(timeIntervalSince1970: 1_000)
        engine = GestureEngine(now: { [unowned self] in clock })
        fires = 0
        ends = 0
        progressValues = []
        engine.onFire = { [unowned self] in fires += 1 }
        engine.onEnd = { [unowned self] in ends += 1 }
        engine.onProgress = { [unowned self] in progressValues.append($0) }
    }

    private func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    // MARK: delta 模式

    func testPinchInReachingThresholdFiresOnce() {
        // US-T2 AC1:600ms 窗口内累计 < -0.35 → 触发
        for _ in 0..<5 {
            advance(0.05)
            engine.feed(delta: -0.08)
        }
        XCTAssertEqual(fires, 1)
        XCTAssertEqual(ends, 0)
        // 前 4 条累计至 -0.32(进度 0.914);第 5 条越阈直接触发,不再发进度
        XCTAssertEqual(progressValues.last ?? 0, 0.32 / 0.35, accuracy: 0.001)
    }

    func testPinchBelowThresholdDoesNotFireAndClearsAfterWindow() {
        // US-T2 AC2:累计仅 -0.20,松手(窗口期过)不触发,累计清零
        advance(0.05)
        engine.feed(delta: -0.12)
        advance(0.05)
        engine.feed(delta: -0.08)
        XCTAssertEqual(fires, 0)

        advance(0.7)   // 超过 600ms 窗口
        engine.settle()
        XCTAssertEqual(ends, 1)
        XCTAssertEqual(engine.state, .idle)

        // 清零后:再次 -0.20 不应触发(若未清零,累计 -0.40 会触发)
        engine.feed(delta: -0.20)
        XCTAssertEqual(fires, 0)
    }

    func testWindowSplitsTwoGestures() {
        advance(0.05)
        engine.feed(delta: -0.30)
        advance(0.7)   // 手势 1 中断超窗
        engine.feed(delta: -0.30)   // 手势 2 从零累计
        XCTAssertEqual(fires, 0)
        XCTAssertEqual(ends, 1)   // 手势 1 结算 onEnd
    }

    func testProgressIsMonotonicDuringPinch() {
        var last = 0.0
        for _ in 1...4 {
            advance(0.05)
            engine.feed(delta: -0.1)
            let p = progressValues.last ?? 0
            XCTAssertGreaterThanOrEqual(p, last)
            last = p
        }
        // 前 3 条累计 -0.1/-0.2/-0.3(进度 3/0.35≈0.857),第 4 条越阈触发
        XCTAssertEqual(last, 0.3 / 0.35, accuracy: 0.001)
        XCTAssertEqual(fires, 1)
    }

    func testPinchOutDoesNotFireAndResetsAccum() {
        // 面板关闭时张开:无触发;正向累计超阈值即清零(漂移保护)
        advance(0.05)
        engine.feed(delta: 0.2)
        advance(0.05)
        engine.feed(delta: 0.2)   // +0.40 ≥ 阈值 → 清零 + onEnd
        XCTAssertEqual(fires, 0)
        XCTAssertEqual(ends, 1)

        advance(0.05)
        engine.feed(delta: -0.34)
        XCTAssertEqual(fires, 0, "正负不抵消后残留:清零后 -0.34 不触发")
    }

    func testReversalNetAccumStillFires() {
        // 先小幅张开再深捏合:带符号累计,净深捏合触发
        advance(0.05)
        engine.feed(delta: 0.1)
        advance(0.05)
        engine.feed(delta: -0.46)   // 净 -0.36
        XCTAssertEqual(fires, 1)
    }

    func testCooldownSuppressesImmediateRefire() {
        // X1:触发后 800ms 内的连击不再触发
        advance(0.05)
        engine.feed(delta: -0.36)
        XCTAssertEqual(fires, 1)

        advance(0.2)
        engine.feed(delta: -0.36)
        XCTAssertEqual(fires, 1, "冷却期内不重复触发")

        advance(0.9)   // 冷却结束
        engine.feed(delta: -0.36)
        XCTAssertEqual(fires, 2)
    }

    func testHigherThresholdNeedsDeeperPinch() {
        // US-T2 AC(设置):阈值 0.5 时 -0.35 不触发
        engine.updateParams { $0.openThreshold = 0.5 }
        advance(0.05)
        engine.feed(delta: -0.35)
        XCTAssertEqual(fires, 0)
        advance(0.05)
        engine.feed(delta: -0.16)   // 累计 -0.51
        XCTAssertEqual(fires, 1)
    }

    // MARK: toggle 降级模式(A1)

    func testToggleModeFiresOnBurstSettle() {
        engine.setMode(.toggle)
        for _ in 0..<10 {
            advance(0.03)
            engine.feed(delta: nil)
        }
        XCTAssertEqual(fires, 0, "簇进行中不触发")
        advance(0.65)
        engine.settle()
        XCTAssertEqual(fires, 1, "簇结束(窗口期静默)触发一次")
        XCTAssertEqual(progressValues.count, 0, "降级模式无进度输出")
    }

    func testToggleModeIgnoresTinyBursts() {
        engine.setMode(.toggle)
        advance(0.03)
        engine.feed(delta: nil)
        engine.feed(delta: nil)   // 2 条 < 最小簇 8 条
        advance(0.65)
        engine.settle()
        XCTAssertEqual(fires, 0)
    }

    func testToggleModeCooldownApplies() {
        engine.setMode(.toggle)
        for _ in 0..<10 { advance(0.03); engine.feed(delta: nil) }
        advance(0.65)
        engine.settle()
        XCTAssertEqual(fires, 1)

        // 冷却期内下一簇结算:不触发
        for _ in 0..<10 { advance(0.03); engine.feed(delta: nil) }
        advance(0.65)
        engine.settle()
        XCTAssertEqual(fires, 1)
    }

    func testToggleCooldownPeriodEventsDoNotCountTowardNextBurst() {
        // 回归（2026-10-05 真机日志）:冷却期内的事件不得计入下一簇——
        // 否则冷却后少量噪音事件即可拼够 minBurstTicks 误触发
        engine.setMode(.toggle)
        for _ in 0..<10 { advance(0.03); engine.feed(delta: nil) }
        advance(0.65)
        engine.settle()
        XCTAssertEqual(fires, 1)

        advance(0.2)   // 仍在 800ms 冷却内:5 条事件应被丢弃
        for _ in 0..<5 { advance(0.03); engine.feed(delta: nil) }
        advance(0.7)   // 冷却结束,新簇仅 3 条(< minBurstTicks=8)
        for _ in 0..<3 { advance(0.03); engine.feed(delta: nil) }
        advance(0.65)
        engine.settle()
        XCTAssertEqual(fires, 1, "冷却期事件不得并入下一簇计数")
    }

    // MARK: 状态复位

    func testSetModeResetsState() {
        advance(0.05)
        engine.feed(delta: -0.3)
        engine.setMode(.toggle)
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.mode, .toggle)
    }

    // MARK: 抬手立即闭簇（forceSettle——松手提交/弹回即刻判定）

    func testForceSettleEndsBurstImmediatelyWithoutWaitingWindow() {
        advance(0.05)
        engine.feed(delta: -0.12)
        advance(0.05)
        engine.feed(delta: -0.08)
        XCTAssertEqual(fires, 0)
        // 未到窗口期即抬手：onEnd 即刻发出、状态回 idle（不等 600ms 定时器）
        advance(0.05)
        engine.forceSettle()
        XCTAssertEqual(ends, 1, "抬手帧应立即闭簇发出 onEnd")
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(fires, 0)

        // 闭簇后累计已清零：新簇重新计数，不与上一簇合并
        advance(0.05)
        engine.feed(delta: -0.20)
        XCTAssertEqual(fires, 0, "抬手闭簇后累计须清零（-0.20 < 0.35 不触发）")
    }

    func testForceSettleIdleAndCooldownAreNoOps() {
        engine.forceSettle()
        XCTAssertEqual(ends, 0, "idle 态 forceSettle 不得发出 onEnd")

        for _ in 0..<5 { advance(0.05); engine.feed(delta: -0.08) }
        XCTAssertEqual(fires, 1)
        engine.forceSettle()
        XCTAssertEqual(ends, 0, "冷却态 forceSettle 不得发出 onEnd")
        XCTAssertEqual(engine.state, .cooldown)
    }
}
