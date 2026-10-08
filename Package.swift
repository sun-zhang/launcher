// swift-tools-version: 6.2
// LauncherZ — 模块划分依据 docs/specs/design.md §2：TriggerLayer / PanelLayer / Core + App 装配层
import PackageDescription

let package = Package(
    name: "LauncherZ",
    platforms: [.macOS(.v26)],
    targets: [
        // Core：数据与领域逻辑（索引/搜索/布局/设置/启动），不依赖其他层
        .target(
            name: "Core",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // MultitouchBridge：私有 MultitouchSupport.framework 的 C 类型桥接
        // （仅类型与函数指针原型，不 extern 符号——运行时 dlsym 取地址，零链接依赖）
        .target(
            name: "MultitouchBridge",
            path: "Sources/MultitouchBridge"
        ),
        // TriggerLayer：触发源（热键/热角/菜单栏/手势）+ 开关仲裁
        .target(
            name: "TriggerLayer",
            dependencies: ["Core", "MultitouchBridge"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // PanelLayer：常驻 NSPanel（AppKit）+ SwiftUI 内容层
        .target(
            name: "PanelLayer",
            dependencies: ["Core", "TriggerLayer"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // App：装配 + 首启 + 设置窗口 + selftest
        .executableTarget(
            name: "LauncherZApp",
            dependencies: ["Core", "TriggerLayer", "PanelLayer"],
            path: "Sources/LauncherZApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Tests/CoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // GestureEngine 状态机等触发层单测（design.md §8：事件序列→触发断言）
        .testTarget(
            name: "TriggerLayerTests",
            dependencies: ["TriggerLayer"],
            path: "Tests/TriggerLayerTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
