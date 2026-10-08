import Carbon.HIToolbox
import Core
import Foundation

/// 全局热键源（FR-T1 / US-T1）。
/// Carbon `RegisterEventHotKey`（预研 F3：零权限；默认 ⌥Space）。
/// 改键 = 先注册新键，成功后注销旧键（冲突时旧键保留可用，US-T1 AC3）。
@MainActor
public final class HotkeySource: TriggerSource {

    public let kind: SourceKind = .hotkey
    public private(set) var isHealthy = false

    private let settings: SettingsStore
    private let coordinator: () -> TriggerCoordinator
    private var hotKeyRef: EventHotKeyRef?
    private var installedKeyCode: Int = 0
    private var installedModifiers: Int = 0

    public init(settings: SettingsStore, coordinator: @escaping () -> TriggerCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
    }

    @discardableResult
    public func start() -> Bool {
        installHandlerIfNeeded()
        let keyCode = settings.hotkeyKeyCode
        let modifiers = settings.hotkeyModifiers
        let ok = register(keyCode: keyCode, modifiers: modifiers)
        isHealthy = ok
        if ok {
            Log.trigger.info("热键就绪: \(Self.describe(keyCode: keyCode, modifiers: modifiers), privacy: .public)")
        } else {
            Log.trigger.error("热键注册失败（可能与其他应用冲突）")
        }
        return ok
    }

    public func stop() {
        unregister()
        isHealthy = false
    }

    /// 改键入口（设置窗口调用）。
    /// - Returns: nil = 成功；非 nil = 失败描述（旧热键仍可用）。
    public func updateHotkey(keyCode: Int, modifiers: Int) -> String? {
        guard keyCode != installedKeyCode || modifiers != installedModifiers else { return nil }
        // 先试注册新键：失败则不动旧键
        guard register(keyCode: keyCode, modifiers: modifiers) else {
            return "热键注册失败（可能与其他应用冲突），已保留原热键"
        }
        isHealthy = true
        Log.trigger.info("热键已切换: \(Self.describe(keyCode: keyCode, modifiers: modifiers), privacy: .public)")
        return nil
    }

    // MARK: - Carbon

    private static let signature: OSType = 0x4C5A5A31   // 'LZZ1'（沿用 spike）
    private static let hotkeyID = EventHotKeyID(signature: 0x4C5A5A31, id: 1)
    private var handlerInstalled = false

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, theEvent, userData in
            var hkID = EventHotKeyID()
            GetEventParameter(theEvent, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard hkID.signature == HotkeySource.signature else { return noErr }
            let source = Unmanaged<HotkeySource>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async {
                _ = source.coordinator().handleTrigger(source: .hotkey, action: .toggle)
            }
            return noErr
        }, 1, &spec, selfPtr, nil)
        handlerInstalled = (status == noErr)
        if status != noErr {
            Log.trigger.error("InstallEventHandler 失败: \(status, privacy: .public)")
        }
    }

    /// 注册指定键（若已有注册先注销——仅在成功注册新键后）。
    private func register(keyCode: Int, modifiers: Int) -> Bool {
        let newKey = registerRaw(keyCode: keyCode, modifiers: modifiers)
        if newKey != nil {
            if hotKeyRef != nil { unregister() }   // 新键生效后才弃旧键
            hotKeyRef = newKey
            installedKeyCode = keyCode
            installedModifiers = modifiers
            return true
        }
        return false
    }

    private func registerRaw(keyCode: Int, modifiers: Int) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                         HotkeySource.hotkeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

    private func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        hotKeyRef = nil
        installedKeyCode = 0
        installedModifiers = 0
    }

    // MARK: - 展示

    /// 「⌥Space」式描述（设置界面/日志共用）。
    public static func describe(keyCode: Int, modifiers: Int) -> String {
        var s = ""
        if modifiers & Int(cmdKey) != 0 { s += "⌘" }
        if modifiers & Int(controlKey) != 0 { s += "⌃" }
        if modifiers & Int(optionKey) != 0 { s += "⌥" }
        if modifiers & Int(shiftKey) != 0 { s += "⇧" }
        return s + (keyEquivalent(for: keyCode) ?? "Key\(keyCode)")
    }

    /// keyCode → 可打印字符（覆盖字母数字与常用键）。
    public static func keyEquivalent(for keyCode: Int) -> String? {
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z",
            kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
            kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9", kVK_ANSI_0: "0",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
            kVK_ANSI_KeypadPlus: "+", kVK_ANSI_KeypadMinus: "-", kVK_ANSI_KeypadMultiply: "*",
            kVK_ANSI_KeypadDivide: "/", kVK_ANSI_KeypadDecimal: ".",
        ]
        return letters[keyCode]
    }
}
