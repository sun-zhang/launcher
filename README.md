# LauncherZ

macOS 26（Tahoe）全屏应用启动器——Launchpad 替代品，核心卖点为四指捏合手势唤起。

**当前状态：M2 手势链路已接入（2026-10-05 定案 MultitouchSupport 路线）——四指捏合全局唤起 + 跟手预览 + 面板内张开关闭可用，无需标定。** 方向由触点指距导出（等效系统 magnification），≥4 指门控天然区分双指/三指捏合；真机数据：四指捏合簇累计 −0.48…−0.81、张开 +0.37…+2.01，与阈值 −0.35 完全可分（`spike/logs/mt-human.log`）。

## 快速开始

```bash
# 构建 + 单元测试
swift build
swift test

# 打包 ad-hoc 签名的 .app（开发自测用）
scripts/build-app.sh
open build/LauncherZ.app        # 后台常驻（无 Dock/菜单栏图标），⌥Space 唤出面板

# 自动化自测（合成热键闭环 + on-screen 断言 + 计时 + 截图取证，跑完自动退出）
./build/LauncherZ.app/Contents/MacOS/LauncherZ --selftest

# 唤出面板 + 延迟截图取证（无需屏幕录制权限，走 cacheDisplay）
./build/LauncherZ.app/Contents/MacOS/LauncherZ --open --proof 25 --proof-path logs/proof.png
```

日志：`log stream --predicate 'subsystem == "com.launcherz.app"'`（selftest 另写 `logs/selftest.log`）。

## 功能范围（MVP）

| 能力 | 说明 | 依据 |
|---|---|---|
| 全屏面板 | 覆盖含菜单栏整屏、非激活不抢焦点、任意 Space 可唤出，常驻窗口开关 ~3ms | FR-P / 预研 F1/F2 |
| 热键 ⌥Space | Carbon 注册零权限；设置中可改键（冲突保留旧键） | FR-T1 |
| 四指捏合唤起 | MultitouchSupport 触点帧流（只读订阅零拦截）→ TouchPinchTracker 五道识别门（≥4 指 / 指集稳定 / 速度分解横扫门 / 质心位移兜底 / 静置零输出，中位数指距抗掌点稀释）→ 状态机（阈值 0.30 可调 / 600ms 窗口 / 800ms 冷却）。双指/三指/放置/横扫均不误触（逐项真机实证） | FR-T2/T6/T9 |
| 跟手预览（双向） | 内容自屏幕边缘外 1.35× 随捏合进度**收拢至屏幕中心**落定（中心锚点），透明度同步；**停则停、中断弹回、完成弹簧收尾**；面板内张开为对称反向（放大淡出跟手关闭） | FR-T5 / FR-T3 |
| 面板内张开关闭 | 触点流驱动（非激活面板收不到系统手势事件，真机实证）累计 +0.30 一簇一击；公开 API `magnify(with:)` 幂等共存 | FR-T3 |
| Esc / 空白点击关闭 | Esc 链：先清搜索再关面板 | FR-T4 |
| 面板角标 | 右下角「设置」齿轮 + 左下角「退出」电源角标（同视觉口径、镜像对称）；手势状态与授权深链在设置窗口；启动失败右上角气泡（2026-10-08 修订：菜单栏图标移除，屏幕无任何常驻元素，左下角角标为唯一常规退出入口） | FR-T7 / FR-G5 |
| 热角（默认关） | 右上角驻留唤起，设置开关 | FR-T8 |
| 应用索引 | Spotlight 主通道 + 目录扫描兜底自动切换；过滤（版本超标/隐身/系统内部工具）；新装/卸载增量同步 | FR-I |
| 网格 | 7×5 分页（列数 5–9 可调）、页码点、双指横滑/←→/PgUpPgDn 翻页、键盘导航、右下角「设置」角标（点击＝面板退场 + 设置窗口置顶）；唤起恒显第一页（翻页状态不跨会话保留） | FR-G |
| 搜索 | 前缀>子串排序、拼音首字母/全拼（`CFStringTransform` 预转写）、bundleID 匹配；单次查询 ~0.1ms | FR-S |
| 启动 | `openApplication` 并行退场、已运行仅激活、失败气泡 | FR-L |
| 数据 | `layout.json` v1 原子写、损坏重建、墓碑（卸载记位重装还原）；UserDefaults 设置 | FR-D |

## 代码结构（SwiftPM，`swift package` 可直接用 Xcode 打开）

```
Sources/Core          领域层：AppIndex / SearchEngine / LayoutStore / IconCache /
                      AppLauncher / SettingsStore / Transliterator（无 UI 依赖，全部单测覆盖）
Sources/MultitouchBridge  MultitouchSupport 私有框架 C 类型桥接（仅类型声明，
                          运行时 dlsym 取符号，零链接依赖）
Sources/TriggerLayer  触发层：TriggerSource 协议 + HotkeySource /
                      HotCornerSource / MultitouchGestureSource（帧回调 →
                      TouchPinchTracker 指距增量 → GestureEngine 状态机）+
                      TriggerCoordinator（冷却仲裁）+ ToastSource（右上角气泡）
Sources/PanelLayer    面板层：PanelController（AppKit 窗口，预研 F1 参数；手势跟手预览）+
                      SwiftUI 内容（PanelViewModel / PanelContentView）
Sources/LauncherZApp  装配：AppDelegate / 设置窗口 / SelfTest
Tests/CoreTests       领域层单测（拼音、过滤、布局不变量、性能预算、手势设置）
Tests/TriggerLayerTests  GestureEngine 状态机 + TouchPinchTracker 指距逻辑单测
```

架构与参数决策的事实来源：`docs/specs/design.md`；验收场景：`docs/specs/requirements.md`。

## 已知偏差 / 后续

- **壁纸快照（FR-P2 双保险）已恢复**（2026-10-08 修订）：此前「`NSWorkspace` 壁纸读取 API 已从 macOS 26 SDK 移除」系误判——`desktopImageURL(for:)` 实证完好于 SDK（`AppKit.framework/Headers/NSWorkspace.h`；swiftinterface 仅含 Swift overlay，不能作依据）。候选链：`NSWorkspace.desktopImageURL`（provider 型壁纸由系统侧解析为具体文件）→ wallpaper Store `Index.plist` 文件路径 → `DefaultDesktop.heic` 兜底；缓存键含来源指纹（候选路径 + mtime + Index mtime），每次唤起重解析——换壁纸无需重启即生效。视频/动态壁纸（.mov）`NSImage` 不可解码，落静态兜底；实时帧需 ScreenCaptureKit + 屏幕录制权限，留待后续评估。
- **手势路线定案（2026-10-05）**：Event Tap 增量路线在 macOS 26 不可行——type29 原始帧不携带增量（字段 0–383 穷举为空）、type30 `.magnify` 仅前台应用处理捏合时合成（非全局）、`.listenOnly` 会遭 UserInput 禁用不可恢复，已整体退役。现役 MultitouchSupport 触点流路线（MiddleClick / everypinch 等开源同路线）真机验证通过；决策链见 `docs/specs/design.md` §3.3，spike 为 `spike/MTFrameSpike.swift`。
- **判据与动画参数为真机实证值，重新生成代码须照抄 `design.md` §3.3/§4.1.1–4.1.3**：五道识别门参数（0.85×3 帧 / 0.2 位移 / 0.0025 噪声地板 / 中位数指距 / d0≥0.05）、双向动画语言（1.35×、起显双门、弹回固定定时器）、面板状态机 model 逻辑开关 + 死锁自愈、缩放锚点显式居中——每项都对应一次真机故障的修复，附 macOS 26 实证清单（§10）。
- **双指/三指捏合不触发**：≥4 指门控（真机实测 3 指捏合累计 −0.36/−0.64，不门控必误触）；落指/抬指帧静默重锚（含同帧重复 fingerID 的驱动异常处理）。
- **首启冷解析约 15–20s**（600+ 应用逐个读 Info.plist），完成后图标全量就位；二次启动走磁盘图标缓存即时显示。首启引导流程（FR-O4/T4.6 完整 OnboardingFlow）未交付，当前为设置窗口授权深链 + 热键形态降级（原菜单栏入口已随菜单栏图标移除，2026-10-08）。
- 开发自测为 ad-hoc 签名；**手势人工测试需固定 Developer ID 签名**（TCC 授权与签名绑定，预研 §1.1 教训），打包脚本已预留说明。

## 测试

- `swift test`：拼音/前缀排序/过滤规则/布局序列化与不变量/性能预算/手势设置钳制 + GestureEngine 状态机 + TouchPinchTracker 判据门（每门含真机场景回归：放置/横扫/拖手捏合/重复 ID 防崩）（66 项 XCTest + 6 项 swift-testing）
- `--selftest`：合成 ⌥Space 开关闭环、on-screen 窗口列表断言、Esc 链、N 轮计时（US-P4 预算 ≤120ms）、手势链路冒烟（引擎越阈→预览收尾、弹回）、`cacheDisplay` 截图取证。**跑 selftest 前先退出常驻实例**（两进程抢注热键导致断言抖动，真机实证）
- CI（`.github/workflows/ci.yml`）：push/PR 构建单测；每日 cron 冒烟 selftest
- 手势人工矩阵（Chrome/Finder/全屏视频 × ≥100 次捏合）为 T5.3 验收项，需真机授权环境
