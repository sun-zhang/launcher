import AppKit
import Foundation

/// 应用启动器（FR-L1/L2）：
/// - `openApplication` 默认激活已运行实例（L2 不双开）
/// - 面板退场与启动调用并行（时序由 PanelController 侧保证：先关面板再发起或并行均可）
/// - 失败回调（US-L1 AC3：面板照常退场 + 提示，不崩溃）
public final class AppLauncher {

    /// 主线程回调：启动失败 (应用名, 错误)。
    public var onFailure: ((String, Error) -> Void)?

    public init() {}

    public func launch(_ record: AppRecord) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: record.path),
                                           configuration: config) { [weak self] _, error in
            if let error {
                Log.app.error("启动 \(record.bundleId, privacy: .public) 失败: \(String(describing: error), privacy: .public)")
                DispatchQueue.main.async {
                    self?.onFailure?(record.name, error)
                }
            } else {
                Log.app.info("已启动 \(record.bundleId, privacy: .public)")
            }
        }
    }
}
