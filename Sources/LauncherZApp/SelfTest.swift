import AppKit
import Core
import Foundation
import PanelLayer
import TriggerLayer

/// 自动化自测（T2.7 产品化，spike `--selftest` 演进）。
/// 流程：合成 ⌥Space（F3：CGEventPost 无需授权）→ 断言面板 on-screen（US-P1 AC4）
///       → 截图取证（cacheDisplay，F9 限制）→ 合成关闭 → Esc 关闭 → 空白点击关闭 → N 轮计时。
/// 合成热键被系统丢弃（无辅助功能权限）时自动降级为直开路径，并在报告中注明。
@MainActor
enum SelfTest {

    final class Result {
        var hotkeyLoopWorks = false
        var openLatencies: [Double] = []
        var onScreenAsserts = 0
        var closeAsserts = 0
        var failures: [String] = []
        var proofPath: String?
    }

    private static var logHandle: FileHandle?

    static func run(controller: PanelController, hotkey: HotkeySource,
                    gesture: MultitouchGestureSource, rounds: Int, logPath: String) {
        let url = URL(fileURLWithPath: logPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = FileHandle(forWritingAtPath: url.path)
        log("=== LauncherZ selftest pid=\(ProcessInfo.processInfo.processIdentifier) rounds=\(rounds) ===")

        var result = Result()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            stepHotkeyProbe(controller: controller, hotkey: hotkey, result: &result)
        }

        // 主流程排程
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if !controller.model.isPanelVisible {
                log("[降级] 合成热键未触发（合成事件可能被丢弃）→ 改用直开路径继续验证")
                controller.openPanel(source: .selftest)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            assertVisible(controller, result: &result, tag: "probe")
            result.proofPath = "logs/selftest_proof.png"
            controller.captureProof(to: result.proofPath!)
            log("取证: \(result.proofPath ?? "")（背景=\(controller.usesWallpaperSnapshot ? "壁纸快照" : "毛玻璃兜底")）")
        }

        // N 轮 开→关 计时（直开路径，等价于热键回调后的同一 openPanel 热路径）
        var cursor: Double = 2.4
        for i in 0..<rounds {
            let openAt = cursor
            DispatchQueue.main.asyncAfter(deadline: .now() + openAt) {
                controller.openPanel(source: .selftest)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + openAt + 0.25) {
                assertVisible(controller, result: &result, tag: "round\(i + 1)-open")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + openAt + 0.4) {
                controller.closePanel(source: .selftest)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + openAt + 0.65) {
                result.closeAsserts += controller.isPanelVisible ? 0 : 1
                if controller.isPanelVisible {
                    result.failures.append("round\(i + 1): 关闭后仍可见")
                }
            }
            cursor += 0.8
        }

        // Esc 关闭链（US-T4：先清搜索再关面板）
        DispatchQueue.main.asyncAfter(deadline: .now() + cursor + 0.1) {
            controller.openPanel(source: .selftest)
            controller.model.query = "saf"
            _ = controller.model.escAction()   // 第一按：应清空搜索且不关面板
            if controller.model.isSearching {
                result.failures.append("Esc 链：第一按未清空搜索")
            }
            if !controller.isPanelVisible {
                result.failures.append("Esc 链：清搜索时不应关面板")
            } else {
                log("Esc 链 ✅（清空搜索后面板保持打开）")
            }
            controller.closePanel(source: .esc)
        }

        // 手势链路冒烟（T4.5）：直接驱动生产引擎——engine → 源回调 → App 装配 → 面板。
        // 先停真实触点流源（授权环境下真机手势帧会干扰断言确定性），测完恢复。
        let g1 = cursor + 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + g1) {
            let openCountBefore = controller.openCount
            gesture.stop()
            gesture.engine.setMode(.delta)
            // delta 模式：按引擎实际阈值缩放（用户可能调过滑杆），三份喂入共越阈 1%
            let per = -(gesture.engine.params.openThreshold * 1.01) / 3
            gesture.engine.feed(delta: per)
            gesture.engine.feed(delta: per)
            gesture.engine.feed(delta: per)
            log("引擎诊断: threshold=\(gesture.engine.params.openThreshold) state=\(gesture.engine.state) ticks=\(gesture.engine.burstTickCount) accum=\(gesture.engine.currentAccum)")
            if controller.model.isPanelVisible && controller.openCount == openCountBefore + 1 {
                log("手势链路 ✅（引擎越阈 → 协调器 → 预览收尾为打开，openCount+1）")
            } else {
                result.failures.append("手势链路：捏合越阈未打开面板（model=\(controller.model.isPanelVisible) openCount=\(controller.openCount)）")
            }
            controller.closePanel(source: .selftest)
        }
        // 预览弹回（FR-T5：未达阈值 <150ms 消失）
        DispatchQueue.main.asyncAfter(deadline: .now() + g1 + 0.4) {
            controller.updateGesturePreview(0.5)
            if controller.isPanelVisible && !controller.model.isPanelVisible {
                log("手势预览呈现 ✅（窗口上屏、逻辑未打开）")
            } else {
                result.failures.append("手势预览：预览态不正确")
            }
            controller.cancelGesturePreview()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + g1 + 0.95) {
            if !controller.isPanelVisible && controller.windowAlphaValue == 1 {
                log("手势预览弹回 ✅（窗口退场、alpha 复位）")
            } else {
                result.failures.append("手势预览弹回：窗口仍可见或 alpha 未复位（visible=\(controller.isPanelVisible) alpha=\(controller.windowAlphaValue)）")
            }
            // 恢复真实触点流源（原 toggle 降级冒烟随 Event Tap 路线退役）
            gesture.engine.setMode(.delta)
            gesture.start()
        }

        // 汇总退出
        DispatchQueue.main.asyncAfter(deadline: .now() + cursor + 3.2) {
            summarize(controller: controller, hotkey: hotkey, result: result, rounds: rounds)
        }
    }

    // MARK: - 步骤

    private static func stepHotkeyProbe(controller: PanelController, hotkey: HotkeySource,
                                        result: inout Result) {
        log("热键注册状态: \(hotkey.isHealthy ? "OK" : "FAIL")")
        postOptionSpace()
    }

    private static func assertVisible(_ controller: PanelController, result: inout Result, tag: String) {
        let visible = controller.isPanelVisible
        let listed = controller.isOnScreenListed()
        if visible && listed {
            result.onScreenAsserts += 1
            log("on-screen 断言 ✅ [\(tag)]（可见且出现在系统窗口列表）")
        } else {
            result.failures.append("[\(tag)] visible=\(visible) listed=\(listed)")
            log("on-screen 断言 ❌ [\(tag)] visible=\(visible) listed=\(listed)")
        }
    }

    private static func summarize(controller: PanelController, hotkey: HotkeySource,
                                  result: Result, rounds: Int) {
        let latencies = controller.openLatenciesMs
        let maxLatency = latencies.max() ?? 0
        let hotkeyLoop = controller.openCount > rounds   // 探测轮 + 计时轮均计入
        log("══════════ selftest 汇总 ══════════")
        log("打开次数: \(controller.openCount)  打开耗时(ms): \(latencies.map { String(format: "%.1f", $0) }.joined(separator: ", "))")
        log("最大打开耗时: \(String(format: "%.1f", maxLatency))ms（预算 ≤120ms，US-P4）→ \(maxLatency <= 120 ? "✅" : "❌")")
        log("on-screen 断言通过: \(result.onScreenAsserts)  关闭断言通过: \(result.closeAsserts)")
        log("合成热键闭环: \(hotkeyLoop ? "✅（合成事件被处理）" : "⚠️ 未走通（合成事件被丢弃，需人工按 ⌥Space 复核热键路径）")")
        if result.failures.isEmpty {
            log("结果: PASS（\(result.failures.count) 项失败）")
        } else {
            log("结果: FAIL（\(result.failures.count) 项失败）")
            for f in result.failures { log("  - \(f)") }
        }
        logHandle?.closeFile()
        exit(result.failures.isEmpty ? 0 : 1)
    }

    // MARK: - 工具

    private static func postOptionSpace() {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        for down in [true, false] {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(49), keyDown: down) {
                e.flags = .maskAlternate
                e.post(tap: .cghidEventTap)
            }
        }
        log("已注入合成 ⌥Space")
    }

    static func log(_ s: String) {
        let line = String(format: "%7.3fs ", Date().timeIntervalSince(Self.t0)) + s
        print(line)
        if let d = (line + "\n").data(using: .utf8) {
            logHandle?.write(d)
        }
    }

    private static let t0 = Date()
}
