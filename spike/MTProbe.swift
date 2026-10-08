// MTProbe —— 探测私有 MultitouchSupport.framework 在当前系统(arm64)上是否可用
// 只做只读探测: dlopen + MTDeviceCreateList + 设备信息 + 符号存在性, 不注册回调(避免签名风险)
import Foundation

let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
print("dlopen(\(path)) ...")
guard let h = dlopen(path, RTLD_LAZY) else {
    print("❌ dlopen 失败: \(String(cString: dlerror()))")
    exit(1)
}
print("✅ dlopen 成功 (私有框架在本机可加载)")

// 关键符号存在性
for sym in ["MTDeviceCreateList", "MTDeviceGetFamilyID", "MTDeviceIsAvailable",
            "MTDeviceGetDeviceID", "MTDeviceRegisterContactBufferCallback",
            "MTDeviceStartDefault", "MTDeviceRelease"] {
    print("  符号 \(sym): \(dlsym(h, sym) != nil ? "存在 ✅" : "缺失 ❌")")
}

typealias CreateListFn = @convention(c) () -> UnsafeMutableRawPointer?  // 返回 CFMutableArrayRef
guard let p = dlsym(h, "MTDeviceCreateList") else {
    print("❌ 找不到 MTDeviceCreateList")
    exit(1)
}
let createList = unsafeBitCast(p, to: CreateListFn.self)
let raw = createList()
guard let raw = raw, let arr = unsafeBitCast(raw, to: CFArray.self) as CFArray? else {
    print("❌ MTDeviceCreateList 返回空")
    exit(1)
}
let n = CFArrayGetCount(arr)
print("✅ MTDeviceCreateList 成功, 内置触控设备数: \(n)")

typealias GetFamilyIDFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>) -> Int32
if let gp = dlsym(h, "MTDeviceGetFamilyID") {
    let getFamily = unsafeBitCast(gp, to: GetFamilyIDFn.self)
    for i in 0..<n {
        guard let dev = CFArrayGetValueAtIndex(arr, i).map({ UnsafeMutableRawPointer(mutating: $0) }) else { continue }
        var fam: Int32 = 0
        _ = getFamily(dev, &fam)
        print("  device[\(i)] familyID=\(fam)")
    }
}

print("结论: 私有框架路径可用（原始触点数据订阅的签名需在M0阶段进一步验证）")
