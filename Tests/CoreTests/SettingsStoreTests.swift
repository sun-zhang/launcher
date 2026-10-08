import XCTest

@testable import Core

/// 手势设置键位（FR-T2：开关默认开、阈值 0.2–0.6 钳制、标定字段覆盖）。
final class SettingsStoreTests: XCTestCase {

    private var suiteName: String!
    private var suite: UserDefaults!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        suiteName = "launcherz.tests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: suite)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suiteName = nil
        suite = nil
        store = nil
        super.tearDown()
    }

    func testGestureDefaults() {
        XCTAssertTrue(store.gestureEnabled, "手势默认开启")
        XCTAssertEqual(store.gestureThreshold, 0.35, accuracy: 0.0001)
    }

    func testGestureThresholdClamp() {
        store.gestureThreshold = 0.05
        XCTAssertEqual(store.gestureThreshold, 0.2, accuracy: 0.0001, "低于下界钳到 0.2")
        store.gestureThreshold = 0.9
        XCTAssertEqual(store.gestureThreshold, 0.6, accuracy: 0.0001, "高于上界钳到 0.6")
        store.gestureThreshold = 0.42
        XCTAssertEqual(store.gestureThreshold, 0.42, accuracy: 0.0001)
    }

    func testGestureToggleRoundTrip() {
        store.gestureEnabled = false
        XCTAssertFalse(store.gestureEnabled)
        store.gestureEnabled = true
        XCTAssertTrue(store.gestureEnabled)
    }

    // MARK: 手势调参（设置界面「手势调参」区全量开放）

    /// 全部调参键位的默认值 = 历史定稿值（各层硬编码迁移前口径）。
    func testTuningDefaults() {
        XCTAssertEqual(store.gestureWindow, 0.6, accuracy: 0.0001)
        XCTAssertEqual(store.gestureEngineCooldown, 0.8, accuracy: 0.0001)
        XCTAssertEqual(store.gestureMinBurstTicks, 8)
        XCTAssertEqual(store.gestureSettleTolerance, 0.05, accuracy: 0.0001)
        XCTAssertEqual(store.gestureMinFingers, 4)
        XCTAssertEqual(store.gestureAnchorDistanceFloor, 0.05, accuracy: 0.0001)
        XCTAssertEqual(store.gestureSwipeCommonRatio, 0.85, accuracy: 0.0001)
        XCTAssertEqual(store.gestureVelocityNoiseFloor, 0.0025, accuracy: 0.00001)
        XCTAssertEqual(store.gestureSwipeConsecutiveFrames, 3)
        XCTAssertEqual(store.gestureSwipeCentroidTravel, 0.2, accuracy: 0.0001)
        XCTAssertEqual(store.gestureCloseThreshold, 0.30, accuracy: 0.0001)
        XCTAssertEqual(store.gesturePinchOutSuppress, 1.5, accuracy: 0.0001)
        XCTAssertEqual(store.gesturePreviewMinTicks, 4)
        XCTAssertEqual(store.gesturePreviewMinProgress, 0.4, accuracy: 0.0001)
        XCTAssertEqual(store.gesturePreviewScaleRange, 1.35, accuracy: 0.0001)
        XCTAssertEqual(store.gesturePreviewCommitProgress, 0.75, accuracy: 0.0001)
        XCTAssertEqual(store.triggerCooldown, 0.8, accuracy: 0.0001)
        XCTAssertEqual(store.hotCornerDwell, 0.22, accuracy: 0.0001)
        XCTAssertEqual(store.hotCornerRearmDelay, 1.2, accuracy: 0.0001)
        XCTAssertEqual(store.pageCommitProgress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(store.pageFlickMinProgress, 0.12, accuracy: 0.0001)
        XCTAssertEqual(store.pageFlickVelocity, 600, accuracy: 0.0001)
        XCTAssertEqual(store.pageDragDeadZone, 3, accuracy: 0.0001)
        XCTAssertEqual(store.pageDriveDuration, 0.22, accuracy: 0.0001)
        XCTAssertEqual(store.pageSettleMinDuration, 0.15, accuracy: 0.0001)
        XCTAssertEqual(store.pageSettleMaxDuration, 0.28, accuracy: 0.0001)
    }

    func testTuningClamps() {
        store.gestureWindow = 5.0
        XCTAssertEqual(store.gestureWindow, 2.0, accuracy: 0.0001, "窗口期钳到 2.0s 上界")
        store.gestureMinFingers = 9
        XCTAssertEqual(store.gestureMinFingers, 6, "指数钳到 6 上界")
        store.gestureCloseThreshold = 0.01
        XCTAssertEqual(store.gestureCloseThreshold, 0.1, accuracy: 0.0001, "关闭阈值钳到 0.1 下界")
        store.pageCommitProgress = 2.0
        XCTAssertEqual(store.pageCommitProgress, 0.95, accuracy: 0.0001, "提交进度钳到 0.95 上界")
        store.gesturePreviewCommitProgress = 1.5
        XCTAssertEqual(store.gesturePreviewCommitProgress, 0.95, accuracy: 0.0001, "松手提交线钳到 0.95 上界")
        store.triggerCooldown = -1
        XCTAssertEqual(store.triggerCooldown, 0, accuracy: 0.0001, "冷却允许调到 0（关闭）但不为负")
    }

    func testTuningReset() {
        store.gestureWindow = 1.5
        store.gestureMinFingers = 2
        store.gestureThreshold = 0.6
        store.resetGestureTuning()
        XCTAssertEqual(store.gestureWindow, 0.6, accuracy: 0.0001)
        XCTAssertEqual(store.gestureMinFingers, 4)
        XCTAssertEqual(store.gestureThreshold, 0.35, accuracy: 0.0001)
    }
}
