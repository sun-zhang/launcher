#!/bin/bash
# 编译三个预研工具
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin logs
swiftc -O -suppress-warnings GestureTapSpike.swift -o bin/gesture-tap-spike -framework Cocoa
swiftc -O -suppress-warnings PanelSpike.swift -o bin/panel-spike -framework Cocoa -framework Carbon
swiftc -O -suppress-warnings MTProbe.swift -o bin/mt-probe
swiftc -O -suppress-warnings -I MTBridge MTFrameSpike.swift -o bin/mt-frame-spike
echo "构建完成: bin/{gesture-tap-spike, panel-spike, mt-probe, mt-frame-spike}"
