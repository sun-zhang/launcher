import Core
import Foundation

/// 触发源协议（design.md §3.1）。任一源失败/失效只影响自身（C2/R2 对策）。
/// M2 接入 GestureSource 后实现同一协议。
@MainActor
public protocol TriggerSource: AnyObject {
    var kind: SourceKind { get }
    /// 菜单栏状态灯数据源（FR-T7）。
    var isHealthy: Bool { get }
    /// false = 启动失败（未授权/热键冲突/后端不可用）。
    @discardableResult
    func start() -> Bool
    func stop()
}
