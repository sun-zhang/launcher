import CoreGraphics
import Core
import Foundation

/// 手势闸门：面板占用期间拦截系统手势事件，不再下放前台应用。
///
/// 修复的问题：面板是非激活窗口（FR-P3），捏合唤起达到阈值后手指仍在触控板上，
/// 剩余捏合量、以及面板内张开关闭（FR-T3）的增量，都会被前台应用当成缩放吃掉
/// ——真机上表现为捏开面板的同时 Safari/地图被缩放，误操作。
///
/// 原理（spike F4 + design.md §1.2 结论的逆向应用）：macOS 26 手势管线中，
/// 会话事件流里的 type29（kCGEventGesture）是触控板捏合的逐帧载体（真机实测
/// 每簇约 300 条），`.magnify`(30) 与 begin(33)/end(34) 由前台应用侧据此合成。
/// 在会话层 head 插入**过滤型** tap 吞掉 29/30/33/34，前台应用即收不到整套
/// 手势。触点识别（唤起/张开关闭）走 MultitouchSupport 设备级流（FR-T9 的
/// 「只读订阅」语义不变），不经此 tap，两者互不影响；type22 scrollWheel
/// 不在掩码内，面板翻页拖拽不受影响。
///
/// 拦截窗口由 `shouldBlock` 逐事件求值（tap 挂主线程 RunLoop，回调即主线程）：
/// 面板窗口可见（含跟手预览期与退场动画期）或已认领的捏合簇仍在途（面板期
/// 落指、尚未抬手）——保证同一簇手势从面板出现到抬手全程不漏，抬手后立即
/// 放行，用户在面板关闭后的正常捏合缩放不受影响。
///
/// 权限：过滤型 tap 与触点流同级，同需「输入监控」授权；创建失败（未授权/
/// 策略禁止）时静默降级为现状（不拦截），不阻塞手势功能本身。
@MainActor
public final class GestureEventShield {

    /// 拦截的事件族：29 元数据载体 / 30 magnify / 33·34 手势起止括号。
    /// （33/34 为保险项：若应用侧从 29 合成则本就不出现，吞之无害。）
    fileprivate static let blockedTypes: Set<UInt32> = [29, 30, 33, 34]

    /// 逐事件求值：true = 吞掉本条手势事件。App 层注入（面板窗口可见 ||
    /// 认领簇在途）。
    public var shouldBlock: () -> Bool = { false }

    public private(set) var isHealthy = false   // tap 安装成功（失败 = 降级不拦截）

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init() {}

    /// 安装常驻 tap（掩码限定手势族，无手势时零回调，无谓不启停）。
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return isHealthy }
        var mask: CGEventMask = 0
        for t in Self.blockedTypes { mask |= CGEventMask(1) << t }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                        place: .headInsertEventTap,
                                        options: .defaultTap,
                                        eventsOfInterest: mask,
                                        callback: shieldTapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.trigger.error("手势闸门 tap 创建失败（输入监控未授权或被策略禁止）——面板期手势将漏至前台应用（唤起/关闭功能不受影响）")
            isHealthy = false
            return false
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        runLoopSource = src
        isHealthy = true
        Log.trigger.info("手势闸门就绪（会话层过滤 tap：type29/30/33/34，面板占用期拦截）")
        return true
    }

    public func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let t = tap { CFMachPortInvalidate(t) }
        tap = nil
        runLoopSource = nil
        if isHealthy {
            isHealthy = false
            Log.trigger.info("手势闸门已移除")
        }
    }

    /// 回调线程读取当前 tap 句柄（超时禁用后重启用）。
    nonisolated func currentTap() -> CFMachPort? { MainActor.assumeIsolated { tap } }
}

/// C 回调（主线程 RunLoop）：`shouldBlock()` 为真且事件属拦截族 → 返回 NULL
/// 吞掉；否则原样放行。tapDisabledByTimeout 按惯例自愈重启用。
private let shieldTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let shield = Unmanaged<GestureEventShield>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // 回调超时/输入禁用后的自愈（listenOnly 变体实证不可恢复，过滤型
        // tap 重启用无害——能恢复则恢复，不能则保持降级放行）
        if let t = shield.currentTap() { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    let block = MainActor.assumeIsolated {
        GestureEventShield.blockedTypes.contains(type.rawValue) && shield.shouldBlock()
    }
    return block ? nil : Unmanaged.passUnretained(event)
}
