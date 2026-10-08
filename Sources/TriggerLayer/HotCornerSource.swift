import AppKit
import Core
import Foundation

/// 热角源（FR-T8 / US-T8，P1）：默认关闭。
/// 实现取公开 API 轮询路径（NSEvent.mouseLocation + 短驻留判定）：
/// - 关闭时零开销（无定时器无 tap），满足 NFR-PRIV 不引入任何常驻监听；
/// - 轮询方式天然不存在「与其他 App 热角冲突注册失败」的问题（US-T8 AC3 由构造保证）。
/// M2 若手势 Event Tap 就位，可评估共用独立鼠标位 tap 的替代实现。
@MainActor
public final class HotCornerSource: NSObject, TriggerSource {

    public let kind: SourceKind = .hotCorner
    public var isHealthy: Bool { timer != nil }

    public enum Corner {
        case topLeft, topRight
    }

    private let settings: SettingsStore
    private let coordinator: () -> TriggerCoordinator
    private var timer: Timer?

    public var corner: Corner = .topRight
    /// 鼠标须在角落驻留时长（模拟系统热角触发的时延感）。
    public var dwell: TimeInterval = 0.22
    /// 触发后的再武装冷却（防抖；与 FR-T6 冷却叠加）。
    public var rearmDelay: TimeInterval = 1.2

    private var enteredAt: Date?
    private var armed = true

    public init(settings: SettingsStore, coordinator: @escaping () -> TriggerCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: .launcherzSettingsChanged, object: nil)
    }

    @discardableResult
    public func start() -> Bool {
        // 热角无独立开关键（默认关）：预留 enabled 设置，当前由 App 层装配决定是否启用
        stop()
        let t = Timer(timeInterval: 0.05, target: self, selector: #selector(pollTick),
                      userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        return true
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        enteredAt = nil
        armed = true
    }

    @objc private func settingsChanged() {
        // 设置变化时 App 层会重建各源；这里无需处理
    }

    @objc private func pollTick() { poll() }

    private func poll() {
        let location = NSEvent.mouseLocation
        guard let screenFrame = NSScreen.main?.frame else { return }

        let edge: CGFloat = 3
        let inCorner: Bool
        switch corner {
        case .topRight:
            inCorner = location.x >= screenFrame.maxX - edge && location.y >= screenFrame.maxY - edge
        case .topLeft:
            inCorner = location.x <= screenFrame.minX + edge && location.y >= screenFrame.maxY - edge
        }

        if inCorner {
            if armed, enteredAt == nil {
                enteredAt = Date()
            }
            if armed, let since = enteredAt?.timeIntervalSinceNow, -since >= dwell {
                armed = false
                enteredAt = nil
                _ = coordinator().handleTrigger(source: .hotCorner, action: .open)
            }
        } else {
            enteredAt = nil
            if !armed {
                // 离开角落 + 冷却过后再武装
                DispatchQueue.main.asyncAfter(deadline: .now() + rearmDelay) { [weak self] in
                    self?.armed = true
                }
            }
        }
    }
}
