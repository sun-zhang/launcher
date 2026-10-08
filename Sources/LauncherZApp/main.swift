import AppKit

// 启动参数（dev/selftest 辅助；正常启动无参数进入无 Dock 图标常驻）
//   --selftest [--rounds N] [--log PATH]   自动化闭环（T2.7 产品化，跑完退出）
//   --open                                 启动 0.6s 后唤出面板（人工快速检查）
//   --proof <秒> [--proof-path PATH]       延迟 N 秒对面板做 cacheDisplay 取证（无需屏幕录制权限）
var selftestRequested = false
var selftestRounds = 3
var selftestLogPath = "logs/selftest.log"
var openAfterLaunch = false
var proofDelay: Double = 0
var proofPath = "logs/panel_proof.png"

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    switch args.removeFirst() {
    case "--selftest": selftestRequested = true
    case "--rounds": selftestRounds = Int(args.removeFirst()) ?? 3
    case "--log": selftestLogPath = args.removeFirst()
    case "--open": openAfterLaunch = true
    case "--proof": proofDelay = Double(args.removeFirst()) ?? 10
    case "--proof-path": proofPath = args.removeFirst()
    default: break
    }
}

// 顶层代码在主线程执行（app.run 之前无并发池），assumeIsolated 建立隔离证明
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(
        selftest: selftestRequested,
        selftestRounds: selftestRounds,
        selftestLogPath: selftestLogPath,
        openAfterLaunch: openAfterLaunch,
        proofDelay: proofDelay, proofPath: proofPath)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // 菜单栏应用，无 Dock 图标（LSUIElement 由 Info.plist 再兜底）
    app.run()
}
