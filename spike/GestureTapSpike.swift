// GestureTapSpike —— 验证 CGEventTap 能否捕获触控板手势事件(kCGEventGesture=29, 未文档化)
// 用法: gesture-tap-spike [--duration 秒=20] [--log 路径]
// 输出: 每个手势事件的字段全量dump(前3个) + 结束时的字段统计与候选判定字段
import Cocoa

// MARK: - 日志

final class PLog {
    static var handle: FileHandle?
    static let t0 = Date()
    static func setup(_ path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = FileHandle(forWritingAtPath: url.path)
        log("=== LauncherZ spike: gesture event tap recon, pid=\(ProcessInfo.processInfo.processIdentifier) ===")
    }
    static func log(_ s: String) {
        let line = String(format: "%7.3fs ", Date().timeIntervalSince(t0)) + s
        print(line)
        if let d = (line + "\n").data(using: .utf8) { handle?.write(d) }
    }
}

// MARK: - tap 上下文

final class TapBox {
    let recon: Recon
    let name: String
    var tap: CFMachPort?
    init(_ r: Recon, _ n: String) { recon = r; name = n }
}

@inline(__always) func fieldOf(_ i: Int) -> CGEventField {
    unsafeBitCast(UInt32(i), to: CGEventField.self)
}

final class Recon {
    // 五个tap：手势事件分别挂 HID / 会话两级，鼠标事件做基线（验证回调机制与权限）
    struct TapDesc { let name: String; let location: CGEventTapLocation; let mask: CGEventMask }

    var boxes: [TapBox] = []
    var typeCounts: [String: [Int: Int]] = [:]          // tapName -> eventTypeRaw -> count
    var gestureTotal = 0
    var fullDumpBudget = 3
    var eventSeq = 0
    // 手势事件的字段统计（用于反推哪个字段编码缩放增量）
    var gIntHist: [Int: [Int64: Int]] = [:]             // int字段 -> 值直方图
    var gDblMin: [Int: Double] = [:]
    var gDblMax: [Int: Double] = [:]
    var gDblSum: [Int: Double] = [:]
    var gDblN: [Int: Int] = [:]
    var gDblNegN = 0, gDblPosN = 0
    // T0.1 扩展：field 扫描上限提至 256；NSEvent 转换路径探测（.magnify 的 magnification 即增量）
    static let fieldScanLimit = 256
    var nseDumpBudget = 3
    var nseTypeHist: [Int: Int] = [:]                   // 转换后 NSEvent.type -> 次数
    var nseMagN = 0, nseMagNonZeroN = 0
    var nseMagMin = 0.0, nseMagMax = 0.0, nseMagAbsSum = 0.0

    let descs: [TapDesc] = [
        .init(name: "HID+gesture(29)", location: .cghidEventTap,
              mask: (CGEventMask(1) << 29)),
        .init(name: "session+gesture(29)", location: .cgSessionEventTap,
              mask: (CGEventMask(1) << 29)),
        .init(name: "HID+mouse(基线)", location: .cghidEventTap,
              mask: (CGEventMask(1) << CGEventType.mouseMoved.rawValue)
                  | (CGEventMask(1) << CGEventType.scrollWheel.rawValue)),
        .init(name: "annotSession+mouse(基线)", location: .cgAnnotatedSessionEventTap,
              mask: (CGEventMask(1) << CGEventType.mouseMoved.rawValue)
                  | (CGEventMask(1) << CGEventType.scrollWheel.rawValue)),
    ]

    func installAll() {
        for d in descs {
            let box = TapBox(self, d.name)
            let cb: CGEventTapCallBack = tapCallback
            let tap = CGEvent.tapCreate(tap: d.location, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: d.mask,
                                        callback: cb, userInfo: Unmanaged.passUnretained(box).toOpaque())
            if let tap {
                box.tap = tap
                let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                CFRunLoopAddSource(RunLoop.main.getCFRunLoop(), src, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                PLog.log("tap[\(d.name)] 创建成功 ✅")
            } else {
                PLog.log("tap[\(d.name)] 创建失败 ❌ (返回NULL——权限不足或被系统策略禁止)")
            }
            boxes.append(box)
        }
    }

    func onEvent(_ box: TapBox, _ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout {
            PLog.log("tap[\(box.name)] 被超时禁用，尝试重新启用")
            if let t = box.tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        if type == .tapDisabledByUserInput {
            PLog.log("tap[\(box.name)] 被用户输入禁用，尝试重新启用")
            if let t = box.tap { CGEvent.tapEnable(tap: t, enable: true) }
            return
        }
        typeCounts[box.name, default: [:]][Int(type.rawValue), default: 0] += 1

        if type.rawValue == 29 {
            gestureTotal += 1
            eventSeq += 1
            if fullDumpBudget > 0 {
                fullDumpBudget -= 1
                dumpAllFields(event, seq: eventSeq)
            } else if gestureTotal % 100 == 0 {
                PLog.log("gesture#\(gestureTotal) (每100条采样一条, ts=\(event.timestamp))")
            }
            probeNSEventConversion(event)
            accumulateStats(event)
        }
    }

    func dumpAllFields(_ event: CGEvent, seq: Int) {
        PLog.log("── gesture事件 #\(seq) 全字段dump (eventTimestamp=\(event.timestamp)) ──")
        for f in 0..<Self.fieldScanLimit {
            let i = event.getIntegerValueField(fieldOf(f))
            let d = event.getDoubleValueField(fieldOf(f))
            if i != 0 || abs(d) > 1e-9 {
                PLog.log("    field[\(f)] int=\(i) dbl=\(String(format: "%.6f", d))")
            }
        }
    }

    /// T0.1 候选路径2：CGEvent → NSEvent 转换。若得到 .magnify，
    /// 其 magnification 属性即缩放增量——生产 GestureFieldMap 直接可用，无需字段标定。
    func probeNSEventConversion(_ event: CGEvent) {
        guard let ns = NSEvent(cgEvent: event) else {
            nseTypeHist[-1, default: 0] += 1   // 转换失败
            return
        }
        nseTypeHist[Int(ns.type.rawValue), default: 0] += 1
        if ns.type == .magnify {
            let m = ns.magnification
            nseMagN += 1
            if m != 0 {
                nseMagNonZeroN += 1
                nseMagAbsSum += abs(m)
                nseMagMin = min(nseMagMin, m)
                nseMagMax = max(nseMagMax, m)
            }
        }
        if nseDumpBudget > 0 {
            nseDumpBudget -= 1
            PLog.log(String(format: "NSEvent转换#%d: type=%d magnification=%.6f scrollingDeltaY=%.4f",
                            3 - nseDumpBudget, ns.type.rawValue, ns.magnification, ns.scrollingDeltaY))
        }
    }

    func accumulateStats(_ event: CGEvent) {
        for f in 0..<Self.fieldScanLimit {
            let i = event.getIntegerValueField(fieldOf(f))
            if i != 0 { gIntHist[f, default: [:]][i, default: 0] += 1 }
            let d = event.getDoubleValueField(fieldOf(f))
            if abs(d) > 1e-9 {
                gDblN[f, default: 0] += 1
                gDblSum[f, default: 0] += d
                gDblMin[f] = min(gDblMin[f] ?? .infinity, d)
                gDblMax[f] = max(gDblMax[f] ?? -.infinity, d)
                if d > 0 { gDblPosN += 1 } else { gDblNegN += 1 }
            }
        }
    }

    func summary() {
        PLog.log("══════════ 侦察结果汇总 ══════════")
        for b in boxes {
            let c = typeCounts[b.name] ?? [:]
            let total = c.values.reduce(0, +)
            PLog.log("tap[\(b.name)] 创建=\(b.tap != nil ? "OK" : "FAILED") 事件总数=\(total) 明细=\(c.sorted { $0.key < $1.key }.map { "type\($0.key)x\($0.value)" }.joined(separator: ","))")
        }
        PLog.log("手势事件(29)总数: \(gestureTotal)")
        if gestureTotal == 0 {
            PLog.log("⚠️ 未捕获到任何手势事件。若运行期间确实没有做过捏合/张开手势，这属预期——请执行 run-human-test.sh 做人工手势验证")
        } else {
            PLog.log("double字段统计（按取值范围从大到小排序，正负皆出现且连续变化者是缩放增量的候选字段）:")
            let ranges = gDblN.keys.map { f -> (Int, Double, Double, Double, Int) in
                let (mn, mx, n) = (gDblMin[f] ?? 0, gDblMax[f] ?? 0, gDblN[f] ?? 0)
                return (f, mx - mn, (gDblSum[f] ?? 0) / Double(max(n, 1)), mn, n)
            }.sorted { $0.1 > $1.1 }
            for (f, range, mean, mn, n) in ranges.prefix(12) {
                PLog.log(String(format: "    field[%d] range=%.5f min=%.5f mean=%+.5f n=%d", f, range, mn, mean, n))
            }
            PLog.log("int字段直方图（subtype/指型等枚举候选）:")
            for (f, hist) in gIntHist.sorted(by: { ($0.value.values.reduce(0,+)) > ($1.value.values.reduce(0,+)) }).prefix(10) {
                let top = hist.sorted { $0.value > $1.value }.prefix(6)
                    .map { "\( $0.key)x\( $0.value)" }.joined(separator: ", ")
                PLog.log("    field[\(f)] \(top)")
            }
            PLog.log("── T0.1 判读 ──")
            let magnifyCount = nseTypeHist[Int(NSEvent.EventType.magnify.rawValue)] ?? 0
            if magnifyCount > 0 && nseMagNonZeroN > 0 {
                PLog.log(String(format: "✅ NSEvent 转换路径可用: .magnify 共 %d 条(非零增量 %d 条, min=%.5f max=%.5f)——生产 GestureFieldMap 直接走此路径, 无需字段标定",
                                magnifyCount, nseMagNonZeroN, nseMagMin, nseMagMax))
            } else {
                PLog.log("❌ NSEvent 转换未得到可用增量: " + nseTypeHist.sorted { $0.key < $1.key }
                    .map { "type\($0.key)x\($0.value)" }.joined(separator: ","))
                PLog.log("→ 走字段标定: 在上方 double 统计里找「捏合时为负、张开时为正、range 最大」的字段 field[N], 然后:")
                PLog.log("   defaults write com.launcherz.app trigger.gestureDeltaFieldIndex -int N")
                PLog.log("   (重启 LauncherZ 生效; 标定前生产端自动降级 toggle 模式)")
            }
        }
    }
}

// MARK: - C 回调

func tapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                 _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let box = Unmanaged<TapBox>.fromOpaque(refcon!).takeUnretainedValue()
    box.recon.onEvent(box, type, event)
    return Unmanaged.passUnretained(event)   // 只监听，不拦截
}

// MARK: - main

var duration = 20.0
var logPath = "logs/gesture-tap.log"
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    switch args.removeFirst() {
    case "--duration": duration = Double(args.removeFirst()) ?? 20
    case "--log": logPath = args.removeFirst()
    default: break
    }
}

PLog.setup(logPath)
PLog.log("运行时长 \(Int(duration))s；验证目标: macOS 上 CGEventTap 能否收到未文档化的 kCGEventGesture(29) 事件")

let recon = Recon()
recon.installAll()

// 1秒后合成一个鼠标移动事件：如果 annotatedSession 基线tap能收到，证明回调机制本身工作正常
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    if let src = CGEventSource(stateID: .combinedSessionState),
       let ev = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                        mouseCursorPosition: NSPoint(x: 500, y: 500), mouseButton: .left) {
        ev.post(tap: .cghidEventTap)
        PLog.log("已注入合成 mouseMoved 事件（若被静默丢弃则可能是无辅助功能权限，不代表tap机制损坏）")
    }
}

let deadline = Date().addingTimeInterval(duration)
while Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
}
PLog.log("时间到，退出")
recon.summary()
exit(0)
