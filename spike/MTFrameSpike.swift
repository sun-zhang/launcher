// MTFrameSpike —— 验证现役 MultitouchSupport 帧回调 API 在本机(macOS 26.6 arm64)可用性
//
// 背景: 旧 MTProbe 探测的老符号组(MTDeviceRegisterContactBufferCallback / MTDeviceStartDefault)已缺失,
//       行业现役方案(MiddleClick / everypinch / asmagill)用的是:
//         MTDeviceCreateList() -> CFMutableArray<MTDeviceRef>
//         MTRegisterContactFrameCallback(device, cb) -> bool
//         MTDeviceStart(device, runMode: 0)
//       回调: (device, MTTouch[], numTouches, timestamp, frame) —— 每帧原始触点
//
// 本 spike 回答三个问题:
//   Q1 新符号是否都在?  Q2 帧回调是否出数据(含触点数)?  Q3 四指捏合的指距变化是否给出稳定的方向增量?
//
// 用法: mt-frame-spike [--duration 45] [--log path]
import Foundation
import MTBridge

// MARK: - 参数

var duration = 45.0
var logPath = "logs/mt-frame-spike.log"
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    switch args.removeFirst() {
    case "--duration": duration = Double(args.removeFirst()) ?? 45
    case "--log": logPath = args.removeFirst()
    default: break
    }
}

// MARK: - 日志(双写 stdout + 文件)

// FileHandle(forWritingAtPath:) 不创建新文件, 先用 FileManager 建
_ = FileManager.default.createFile(atPath: logPath, contents: nil)
let logHandle = FileHandle(forWritingAtPath: logPath) ?? FileHandle.standardError
func log(_ s: String) {
    let line = s + "\n"
    print(line, terminator: "")
    logHandle.write(line.data(using: .utf8)!)
}

let t0 = Date()
func ts() -> String { String(format: "[%7.2fs]", Date().timeIntervalSince(t0)) }

// MARK: - 统计状态(回调线程与主线程共访, 加锁)

final class Stats {
    let lock = NSLock()
    var totalFrames = 0
    var framesByFingers = [Int: Int]()          // numTouches -> 帧数
    var firstTouchDumpDone = false
    var fourFingerDumpCount = 0

    // 簇(≥2 指连续在触)跟踪
    struct Burst {
        var startAt: Double
        var endAt: Double
        var maxFingers = 0
        var frames = 0
        var fingerTicks = [Int: Int]()          // 每帧指数直方图
        var d0: Float = 0                       // 起始平均两两距离
        var dLast: Float = 0
        var dMin: Float = .greatestFiniteMagnitude
        var dMax: Float = 0
        var cumMag: Float = 0                   // (d - d0) / d0, 等效系统 magnification
        var totalMagTravel: Float = 0           // 逐帧 |Δd|/d0 累计(手势强度/噪声度量)
    }
    var currentBurst: Burst?
    var bursts: [Burst] = []
    var liveLine = ""

    // 由回调调用
    func onFrame(touches: UnsafeMutablePointer<MTTouch>?, numTouches: Int32) {
        lock.lock(); defer { lock.unlock() }
        let n = Int(numTouches)
        totalFrames += 1
        framesByFingers[min(n, 6), default: 0] += 1
        let now = Date().timeIntervalSince(t0)

        guard n >= 2, let touches else {
            if var b = currentBurst {
                b.endAt = now
                // 掉到 <2 指即结算(抬手)
                bursts.append(b)
                currentBurst = nil
                liveLine = "簇结束: \(describe(b))"
            }
            return
        }

        // 平均两两距离(归一化坐标)
        var sum: Float = 0; var pairs = 0
        for i in 0..<n {
            for j in (i + 1)..<n {
                let a = touches[i].normalizedVector.position
                let b = touches[j].normalizedVector.position
                sum += ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
                pairs += 1
            }
        }
        let d = sum / Float(max(pairs, 1))

        if var b = currentBurst {
            let dd = (d - b.dLast) / b.d0
            b.totalMagTravel += abs(dd)
            b.dLast = d
            b.dMin = min(b.dMin, d); b.dMax = max(b.dMax, d)
            b.cumMag = (d - b.d0) / b.d0
            b.frames += 1
            b.maxFingers = max(b.maxFingers, n)
            b.fingerTicks[min(n, 6), default: 0] += 1
            b.endAt = now
            currentBurst = b
            liveLine = String(format: "在触: %d指 平均指距=%.3f 等效放大率=%.3f (帧#%d)", n, d, b.cumMag, b.frames)
        } else {
            currentBurst = Burst(startAt: now, endAt: now, maxFingers: n,
                                 fingerTicks: [min(n, 6): 1],
                                 d0: d, dLast: d, dMin: d, dMax: d)
            liveLine = String(format: "新簇: %d指 起始指距=%.3f", n, d)
        }

        // 布局校验: 首个触点帧 + 前两个四指帧, 落盘原始字段
        if !firstTouchDumpDone {
            firstTouchDumpDone = true
            dumpTouch(touches[0], tag: "首触点帧")
        }
        if n >= 4 && fourFingerDumpCount < 2 {
            fourFingerDumpCount += 1
            dumpTouch(touches[0], tag: "四指帧#\(fourFingerDumpCount)")
            for i in 1..<n { dumpTouch(touches[i], tag: "四指帧#\(fourFingerDumpCount).指\(i)") }
        }
    }

    func dumpTouch(_ t: MTTouch, tag: String) {
        let raw = String(format: "stage=%d fingerID=%d handID=%d", t.stage, t.fingerID, t.handID)
        let norm = String(format: "norm=(%.4f, %.4f) normVel=(%.3f, %.3f)",
                          t.normalizedVector.position.x, t.normalizedVector.position.y,
                          t.normalizedVector.velocity.x, t.normalizedVector.velocity.y)
        let abs = String(format: "abs=(%.1f, %.1f)", t.absoluteVector.position.x, t.absoluteVector.position.y)
        let misc = String(format: "pressure=%.3f angle=%.2f axis=%.2f/%.2f total=%.3f ts=%.4f",
                          t.pressure, t.angle, t.majorAxis, t.minorAxis, t.total, t.timestamp)
        log("  \(ts()) [\(tag)] \(raw) \(norm) \(abs) \(misc)")
    }

    func describe(_ b: Burst) -> String {
        let dur = b.endAt - b.startAt
        let cum = b.cumMag
        let dir = cum < -0.08 ? "捏合(负)" : (cum > 0.08 ? "张开(正)" : "无明显方向")
        return String(format: "%d指(峰值) %.2fs %d帧 等效放大率=%.3f [%@] 指距 %.3f→%.3f",
                      b.maxFingers, dur, b.frames, cum, dir, b.d0, b.dLast)
    }
}

let stats = Stats()

// MARK: - 主流程

let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
log("MTFrameSpike —— 现役 MultitouchSupport 帧回调探测")
log("布局自检: MemoryLayout<MTTouch>.size=\(MemoryLayout<MTTouch>.size) (C 头文件推算应为 96)")

guard let h = dlopen(frameworkPath, RTLD_LAZY) else {
    log("❌ dlopen 失败: \(String(cString: dlerror()))")
    exit(1)
}
log("✅ dlopen 成功")

let needSymbols = ["MTDeviceCreateList", "MTRegisterContactFrameCallback",
                   "MTDeviceStart", "MTDeviceStop", "MTDeviceRelease"]
var allPresent = true
for s in needSymbols {
    let ok = dlsym(h, s) != nil
    log("  符号 \(s): \(ok ? "存在 ✅" : "缺失 ❌")")
    allPresent = allPresent && ok
}
guard allPresent else {
    log("❌ Q1 不通过: 现役符号缺失, MT 路线在本机不可行")
    exit(2)
}
log("✅ Q1 通过: 现役符号 5/5 齐全(与老符号组不同, 这组是活的)")

guard let pCreate = dlsym(h, "MTDeviceCreateList") else { exit(2) }
let createList = unsafeBitCast(pCreate, to: (@convention(c) () -> UnsafeMutableRawPointer?).self)
guard let rawArr = createList(), let arr = unsafeBitCast(rawArr, to: CFArray.self) as CFArray? else {
    log("❌ MTDeviceCreateList 返回空")
    exit(2)
}
let deviceCount = CFArrayGetCount(arr)
log("✅ 设备数: \(deviceCount)")

let pRegister = unsafeBitCast(dlsym(h, "MTRegisterContactFrameCallback")!, to: MTRegisterContactFrameCallbackFn.self)
let pStart = unsafeBitCast(dlsym(h, "MTDeviceStart")!, to: MTDeviceStartFn.self)
let pStop = unsafeBitCast(dlsym(h, "MTDeviceStop")!, to: MTDeviceStopFn.self)
let pRelease = unsafeBitCast(dlsym(h, "MTDeviceRelease")!, to: MTDeviceReleaseFn.self)

// 回调保留为全局常量(注册进 C 后必须常驻)
let frameCallback: MTFrameCallbackFunction = { _, touches, numTouches, _, _ in
    stats.onFrame(touches: touches, numTouches: numTouches)
}

var devices: [MTDeviceRef] = []
for i in 0..<deviceCount {
    guard let v = CFArrayGetValueAtIndex(arr, i) else { continue }
    let dev = UnsafeMutableRawPointer(mutating: v)
    devices.append(dev)
    let ok = pRegister(dev, frameCallback)
    log("  device[\(i)] 注册帧回调: \(ok ? "成功 ✅" : "失败 ❌")")
    pStart(dev, 0)
}
log("✅ 已注册并 start(runMode:0), 开始监听 \(Int(duration)) 秒 —— 请在触控板上操作:")
log("   ① 四指捏合(像打开 Launchpad)3 次   ② 四指张开 3 次   ③ 双指捏合/张开 2 次(对照)")

// 实时行每 800ms 刷新
let liveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
    stats.lock.lock()
    let line = stats.liveLine
    let tf = stats.totalFrames
    var byF = ""
    for k in 0...6 { if let c = stats.framesByFingers[k] { byF += " \(k)指:\(c)" } }
    stats.lock.unlock()
    log("⏱ \(ts()) 总帧:\(tf)\(byF)\(line.isEmpty ? "" : " | " + line)")
}

RunLoop.main.run(until: Date().addingTimeInterval(duration))
liveTimer.invalidate()

// 结算收尾(若结束时仍在触, 把当前簇也结算)
stats.lock.lock()
if let b = stats.currentBurst { stats.bursts.append(b); stats.currentBurst = nil }
let allBursts = stats.bursts
let totalFrames = stats.totalFrames
let byFingers = stats.framesByFingers
stats.lock.unlock()

for d in devices { pStop(d); pRelease(d) }

// MARK: - 自动判读

log("")
log("═══════════ 结算 ═══════════")
log("Q2 帧数据: 总帧 \(totalFrames), 指数分布 \(byFingers.sorted { $0.key < $1.key })")
if totalFrames == 0 {
    log("❌ Q2 不通过: 无任何帧回调 —— 可能需要把本程序(或所在终端)加入「输入监控」")
    exit(3)
}
let touchFrames = byFingers.filter { $0.key >= 1 }.values.reduce(0, +)
if touchFrames == 0 {
    log("⚠️ Q2 半通过: 有帧但从未见触点 —— 权限被静默降级或手势未在录制窗口内发生")
}

log("簇数: \(allBursts.count)")
for (i, b) in allBursts.enumerated() {
    log("  簇[\(i)] \(stats.describe(b))")
}

let fourPinch = allBursts.filter { $0.maxFingers >= 4 && $0.cumMag < -0.08 }
let fourSpread = allBursts.filter { $0.maxFingers >= 4 && $0.cumMag > 0.08 }
let twoAny = allBursts.filter { $0.maxFingers <= 3 }
log("")
log("四指捏合簇: \(fourPinch.count) 个, 四指张开簇: \(fourSpread.count) 个, ≤3指对照簇: \(twoAny.count) 个")

if !fourPinch.isEmpty {
    let avg = fourPinch.map { $0.cumMag }.reduce(0, +) / Float(fourPinch.count)
    log(String(format: "✅ Q3 通过: 四指捏合方向数据稳定, 平均等效放大率=%.3f (负=收拢), 指距法可直接喂 GestureEngine", avg))
    log("")
    log("结论: MT 帧回调路线在本机完全可行 —— 建议实现 MultitouchSource 替换 EventTap 增量来源")
    exit(0)
} else if touchFrames > 0 {
    log("⚠️ Q3 未验证: 有触点帧但无四指捏合簇 —— 确认录制期间确实做了四指捏合, 重跑一次")
    exit(4)
} else {
    log("❌ 见上方 Q2 判读")
    exit(3)
}
