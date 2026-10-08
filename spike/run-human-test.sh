#!/bin/bash
# LauncherZ 技术预研 · 人工手势测试（全程约 2 分钟）
# 前置: 已运行 build.sh（本脚本不再重新编译, 否则授权会因签名变化失效）
cd "$(dirname "$0")"

BIN="$PWD/bin/gesture-tap-spike"
PANEL="$PWD/bin/panel-spike"

echo "════════════════════════════════════════════════"
echo " 第 0 步 · 授权（一次性, 约 30 秒）"
echo "════════════════════════════════════════════════"
echo "已为你打开「系统设置 → 隐私与安全性 → 输入监控」。"
echo "请点 「+」 添加以下两个文件（快捷键 ⌘⇧G 可输入路径跳转）:"
echo "  1) $BIN"
echo "  2) $PANEL"
echo "添加后若开关是关的, 请打开。"
osascript -e 'tell application "System Settings" to reveal anchor "Privacy_ListenEvent" of pane id "com.apple.preference.security"' >/dev/null 2>&1
open "/System/Library/PreferencePanes/Security.prefPane"
read -p "完成添加后按回车继续..."

echo
echo "════════════════════════════════════════════════"
echo " 第 1 步 · 手势事件捕获（45 秒）"
echo "════════════════════════════════════════════════"
echo "开始后请在触控板上连续做（停留在任意普通应用里即可, 不用点按）:"
echo "  · 四指捏合(Pinch-in) 5 次 —— 像以前打开 Launchpad"
echo "  · 四指张开(Pinch-out) 5 次"
echo "  · 双指捏合/张开 3 次（对照四指与双指的事件差异）"
echo "  · 双指滚动几下、旋转 1 次"
read -p "准备好后按回车开始计时..."
"$BIN" --duration 45 --log logs/human-gesture.log

echo
echo "──────── 第 1 步即时判读 ────────"
if grep -q "创建成功" logs/human-gesture.log && grep -q "手势事件(29)总数: [1-9]" logs/human-gesture.log; then
    echo "✅ tap 创建成功 且 捕获到手势事件 —— 全局手势监听可行!"
    grep "field\[" logs/human-gesture.log | head -30
elif grep -q "创建成功" logs/human-gesture.log; then
    echo "⚠️ tap 创建成功但没收到手势事件——重跑一次本步骤并确认手势期间脚本在计时中"
else
    echo "❌ tap 仍创建失败: 请确认已把 bin/gesture-tap-spike 加入「输入监控」, 若仍失败再尝试加入「辅助功能」后重跑"
    exit 1
fi

echo
echo "════════════════════════════════════════════════"
echo " 第 2 步 · 面板交互（40 秒, 无需权限）"
echo "════════════════════════════════════════════════"
echo "面板即将打开, 请依次:"
echo "  a) 在面板上 双指或四指张开 —— 应触发关闭(阈值累计+0.30)"
echo "  b) 按 ⌥Space 重新打开"
echo "  c) 按 Esc 关闭, 再 ⌥Space 打开"
echo "  d) 双指横向滑动(翻页示意)"
read -p "按回车开始..."
"$PANEL" --interactive --duration 40 --log logs/human-panel.log

echo
echo "──────── 第 2 步即时判读 ────────"
PC=$(grep -c "本地捏合事件" logs/human-panel.log || true)
CLOSE=$(grep -c "公开API" logs/human-panel.log || true)
echo "面板内公开API捏合事件: ${PC} 条; 其中触发关闭: ${CLOSE} 次"
[ "${PC:-0}" -gt 0 ] && echo "✅ 面板内捏合关闭走通" || echo "⚠️ 未收到面板内捏合事件(重试或反馈日志)"

echo
echo "完成。三份日志: logs/human-gesture.log / logs/human-panel.log / logs/gesture-tap.log"
echo "把它们发回对话即可自动生成预研结论。"
