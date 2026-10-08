/// 触发来源标识（面板动作的溯源，用于日志与状态灯）。
public enum SourceKind: String {
    case hotkey       // FR-T1
    case gesture      // FR-T2（M2 接入）
    case hotCorner    // FR-T8
    case menubar      // FR-T7
    case esc          // FR-T4
    case blankClick   // FR-T4
    case pinchOut     // FR-T3
    case launch       // FR-L1（启动应用后的退场）
    case settings     // 设置入口
    case selftest     // T2.7 自动化
}

/// 面板动作。
public enum PanelAction {
    case open
    case close
    case toggle
}

/// TriggerLayer → PanelLayer 的解耦协议（design.md §2）。
/// TriggerCoordinator 只依赖此协议，PanelController 在 App 层注入。
@MainActor
public protocol PanelControlling: AnyObject {
    var isPanelVisible: Bool { get }
    func openPanel(source: SourceKind)
    func closePanel(source: SourceKind)
    func togglePanel(source: SourceKind)
}
