import Core
import Foundation
import Testing

/// WallpaperStore 纯函数部分（路径解析 / Store plist 字符串收集）。
/// 渲染与真实数据源依赖本机环境，不入单测（selftest 取证覆盖）。
struct WallpaperStoreTests {

    // MARK: resolveCandidate

    @Test func resolveAbsoluteExistingPath() {
        let tmp = NSTemporaryDirectory() + "lz-wallpaper-test-\(UUID().uuidString).jpg"
        FileManager.default.createFile(atPath: tmp, contents: Data([0xFF]))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        #expect(WallpaperStore.resolveCandidate(tmp)?.path == tmp)
    }

    @Test func resolveAbsoluteMissingPathReturnsNil() {
        #expect(WallpaperStore.resolveCandidate("/nonexistent/lz-\(UUID().uuidString).heic") == nil)
    }

    @Test func resolveBareNameSearchesInjectedDirs() {
        let dir = NSTemporaryDirectory() + "lz-dirs-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/Chroma Blue.heic"
        FileManager.default.createFile(atPath: file, contents: Data([0xFF]))
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let dirs = [dir, "/nonexistent-lz"]
        #expect(WallpaperStore.resolveCandidate("Chroma Blue.heic", searchDirs: dirs)?.path == file)
        #expect(WallpaperStore.resolveCandidate("不存在壁纸.heic", searchDirs: dirs) == nil)
    }

    @Test func resolveRejectsNonFilelikeStrings() {
        #expect(WallpaperStore.resolveCandidate("automatic") == nil)
        #expect(WallpaperStore.resolveCandidate("") == nil)
        #expect(WallpaperStore.resolveCandidate("relative/path/heic") == nil)
    }

    // MARK: stringsFromStoreIndex

    @Test func collectStringsFromNestedStorePlist() throws {
        // 构造含 Files 数组 + 内嵌 bplist（EncodedOptionValues 形态）的 Index.plist
        let inner = try PropertyListSerialization.data(
            fromPropertyList: ["values": ["appearance": ["picker": ["_0": ["id": "hello"]]]]],
            format: .binary, options: 0)
        let index: [String: Any] = [
            "AllSpacesAndDisplays": [
                "Linked": [
                    "Content": [
                        "Choices": [[
                            "Files": ["/tmp/some-wallpaper.heic"],
                            "Provider": "com.apple.wallpaper.choice.macintosh",
                            "EncodedOptionValues": inner,
                        ]],
                    ],
                ],
            ],
        ]
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "lz-index-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: index, format: .binary, options: 0)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let strings = WallpaperStore.stringsFromStoreIndex(url)
        #expect(strings.contains("/tmp/some-wallpaper.heic"))
        #expect(strings.contains("hello"))
        #expect(strings.contains("com.apple.wallpaper.choice.macintosh"))
    }

    @Test func missingStoreIndexYieldsEmpty() {
        #expect(WallpaperStore.stringsFromStoreIndex(
            URL(fileURLWithPath: "/nonexistent/lz-index.plist")).isEmpty)
    }

    // MARK: fingerprint（缓存键的来源指纹部分）

    @Test func fingerprintIsStableAndSensitiveToPathAndMTime() throws {
        let dir = NSTemporaryDirectory() + "lz-fp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let a = URL(fileURLWithPath: dir + "/a.heic")
        try Data([0xFF]).write(to: a)
        // 显式固定 mtime，规避同秒写入的精度干扰
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: t0], ofItemAtPath: a.path)

        let base = WallpaperStore.fingerprint(candidates: [a])
        #expect(WallpaperStore.fingerprint(candidates: [a]) == base)   // 同输入稳定

        let b = URL(fileURLWithPath: dir + "/b.heic")
        try Data([0x00]).write(to: b)
        try FileManager.default.setAttributes([.modificationDate: t0], ofItemAtPath: b.path)
        #expect(WallpaperStore.fingerprint(candidates: [b]) != base)   // 路径变化

        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(5)],
                                               ofItemAtPath: a.path)
        #expect(WallpaperStore.fingerprint(candidates: [a]) != base)   // 原文件被替换（mtime 变化）

        // Index.plist 自身更新（如 provider 型换壁纸）也应失配
        #expect(WallpaperStore.fingerprint(candidates: [a], indexPlistModificationDate: t0)
                != WallpaperStore.fingerprint(candidates: [a], indexPlistModificationDate: t0.addingTimeInterval(1)))
    }

    @Test func fingerprintToleratesMissingFiles() {
        // 候选文件不存在（路径已失效）不崩溃，输出仍非空可作键
        let fp = WallpaperStore.fingerprint(
            candidates: [URL(fileURLWithPath: "/nonexistent/lz-\(UUID().uuidString).heic")])
        #expect(!fp.isEmpty)
    }

    // MARK: candidates（数据源优先级）

    @Test func candidatesPrioritizeNSWorkspaceURL() throws {
        let tmp = NSTemporaryDirectory() + "lz-cand-\(UUID().uuidString).heic"
        FileManager.default.createFile(atPath: tmp, contents: Data([0xFF]))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // 公开 API 来源排首位；nil 时纯文件解析（临时文件不在 Store 内，不应出现）
        #expect(WallpaperStore.candidates(nsworkspaceURL: URL(fileURLWithPath: tmp)).first?.path == tmp)
        #expect(!WallpaperStore.candidates(nsworkspaceURL: nil).contains { $0.path == tmp })
    }
}
