import Core
import Foundation

/// 触发仲裁（design.md §2）：
/// - 所有源的触发统一走这里，再作用到面板；
/// - 冷却防连触（FR-T6）：手势类触发 800ms 内只放行一次（热键/菜单栏等显式触发不受限）；
///   M2 GestureSource 接入后同一状态机天然覆盖 X1 场景。
@MainActor
public final class TriggerCoordinator {

    public weak var panel: PanelControlling?

    /// FR-T6 触发冷却（SRS §6 参数表，MVP 固定 800ms；可注入便于状态机单测）。
    public var cooldown: TimeInterval
    private var lastGestureFire = Date.distantPast
    private let lock = NSLock()

    public init(cooldown: TimeInterval = 0.8) {
        self.cooldown = cooldown
    }

    public enum Verdict: Equatable {
        case executed
        case suppressedByCooldown   // X1：冷却期内连击
    }

    public func handleTrigger(source: SourceKind, action: PanelAction) -> Verdict {
        if source == .gesture || source == .hotCorner {
            lock.lock()
            let now = Date()
            if now.timeIntervalSince(lastGestureFire) < cooldown {
                lock.unlock()
                // info 级：debug 在 macOS 26 不落盘——漏触发排障需要它
                Log.trigger.info("触发被冷却抑制: \(source.rawValue, privacy: .public)（距上次 \(Int(now.timeIntervalSince(self.lastGestureFire) * 1000), privacy: .public)ms < \(Int(self.cooldown * 1000), privacy: .public)ms）")
                return .suppressedByCooldown
            }
            lastGestureFire = now
            lock.unlock()
        }
        guard let panel else { return .executed }
        switch action {
        case .open: panel.openPanel(source: source)
        case .close: panel.closePanel(source: source)
        case .toggle: panel.togglePanel(source: source)
        }
        return .executed
    }
}
