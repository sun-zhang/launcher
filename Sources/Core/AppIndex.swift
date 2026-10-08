import AppKit
import Foundation

/// 应用索引（FR-I1..I4）。
/// 双通道：Spotlight 元数据（主，事件驱动增量）→ 0 结果或 5s 超时判定不可用 → 目录扫描（兜底，60s 轮询增量）。
/// 解析（读 Info.plist + 过滤 + 拼音键预计算）全部在后台队列，主线程只发布结果。
public final class AppIndex: NSObject, ObservableObject {

    public enum Channel: String {
        case spotlight
        case directory
    }

    public enum State: Equatable {
        case idle
        case scanning(Channel)
        case ready(count: Int, channel: Channel)
    }

    @Published public private(set) var records: [AppRecord] = []   // 系统应用在前、组内名称本地化自然序
    @Published public private(set) var state: State = .idle

    /// 本应用自身的 bundleId（网格过滤自身）。裸二进制运行时为空。
    public var ownBundleId: String = Bundle.main.bundleIdentifier ?? ""

    private let settings: SettingsStore
    private var query: NSMetadataQuery?
    private var queryTimeoutWork: DispatchWorkItem?
    private var directoryTimer: Timer?
    private let parseQueue = DispatchQueue(label: "launcherz.index.parse", qos: .userInitiated)
    /// path -> (mtime, record) 缓存，未变更路径不重复解析
    private var parsedCache: [String: (mtime: TimeInterval, record: AppRecord)] = [:]
    private var activeChannel: Channel = .spotlight

    public init(settings: SettingsStore = .shared) {
        self.settings = settings
        super.init()
    }

    // MARK: - 生命周期

    public func start() {
        rescan()
    }

    /// 全量重扫（手动入口 FR-X4 / 设置变更后调用）。
    public func rescan() {
        state = .scanning(.spotlight)
        activeChannel = .spotlight
        runSpotlightQuery()
    }

    private func switchToDirectoryChannel(reason: String) {
        Log.index.warning("Spotlight 通道不可用（\(reason, privacy: .public)），切换目录扫描")
        activeChannel = .directory
        state = .scanning(.directory)
        scanDirectories()
        startDirectoryPolling()
    }

    // MARK: - Spotlight 主通道

    private func runSpotlightQuery() {
        stopSpotlightQuery()
        stopDirectoryPolling()

        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemContentType == %@", "com.apple.application-bundle")
        q.searchScopes = ["/"]
        query = q

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(queryDidFinishGathering),
                       name: .NSMetadataQueryDidFinishGathering, object: q)
        nc.addObserver(self, selector: #selector(queryDidUpdate),
                       name: .NSMetadataQueryDidUpdate, object: q)

        // 5s 超时判定 Spotlight 不可用（design.md §5）
        let work = DispatchWorkItem { [weak self, weak q] in
            guard let self, let q, self.query === q else { return }
            if case .scanning = self.state {
                q.stop()
                self.switchToDirectoryChannel(reason: "查询 5s 未完成")
            }
        }
        queryTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)

        guard q.start() else {
            switchToDirectoryChannel(reason: "NSMetadataQuery.start 失败")
            return
        }
    }

    private func stopSpotlightQuery() {
        queryTimeoutWork?.cancel()
        queryTimeoutWork = nil
        guard let q = query else { return }
        q.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: q)
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: q)
        query = nil
    }

    @objc private func queryDidFinishGathering(_ note: Notification) {
        guard let q = note.object as? NSMetadataQuery, q === query else { return }
        queryTimeoutWork?.cancel()
        q.disableUpdates()
        let paths = collectPaths(from: q)
        q.enableUpdates()

        if paths.isEmpty {
            // 0 结果：Spotlight 索引被关闭 → 兜底通道（FR-I1 AC2）
            stopSpotlightQuery()
            switchToDirectoryChannel(reason: "0 结果")
        } else {
            Log.index.info("Spotlight 首轮收集 \(paths.count) 个 .app，解析…")
            reindex(paths: paths)
        }
    }

    /// Spotlight live 增量（FR-I3：新装/卸载 ≤60s 内同步）。
    @objc private func queryDidUpdate(_ note: Notification) {
        guard let q = note.object as? NSMetadataQuery, q === query,
              case .ready = state else { return }
        q.disableUpdates()
        let info = note.userInfo ?? [:]
        let added = (info[kMDQueryUpdateAddedItems] as? [NSMetadataItem]) ?? []
        let changed = (info[kMDQueryUpdateChangedItems] as? [NSMetadataItem]) ?? []
        let removed = (info[kMDQueryUpdateRemovedItems] as? [NSMetadataItem]) ?? []
        q.enableUpdates()

        let addedPaths = Self.prune(paths: (added + changed).compactMap { $0.value(forAttribute: "kMDItemPath") as? String },
                                    extraDirs: settings.extraScanDirs)
        let removedPaths = removed.compactMap { $0.value(forAttribute: "kMDItemPath") as? String }
        guard !addedPaths.isEmpty || !removedPaths.isEmpty else { return }
        Log.index.info("Spotlight 增量: +\(addedPaths.count) -\(removedPaths.count)")
        incrementalUpdate(added: addedPaths, removed: removedPaths)
    }

    private func collectPaths(from q: NSMetadataQuery) -> [String] {
        var paths: [String] = []
        paths.reserveCapacity(q.resultCount)
        for i in 0..<q.resultCount {
            if let item = q.result(at: i) as? NSMetadataItem,
               let p = item.value(forAttribute: "kMDItemPath") as? String {
                paths.append(p)
            }
        }
        return Self.prune(paths: paths)
    }

    /// Spotlight scope=/ 会捞出 /Library/Application Support 里的后台助手与嵌套在
    /// .app 包内的子应用（如 Xcode 内的 Accessibility Inspector）。
    /// 与目录通道口径对齐：仅保留标准目录 + 用户自定义目录、且非嵌套的 .app。
    static func prune(paths: [String], extraDirs: [String] = []) -> [String] {
        let roots = (DirectoryScanner.standardDirs + extraDirs).map { root -> String in
            root.hasSuffix("/") ? String(root.dropLast()) : root
        }
        return paths.filter { path in
            // 嵌套 .app（path 中间还有 .app/ 段）排除
            let rest = path.dropFirst(1)
            if rest.contains(".app/") { return false }
            return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    // MARK: - 目录兜底通道

    private func scanDirectories() {
        let extra = settings.extraScanDirs
        parseQueue.async { [weak self] in
            let paths = DirectoryScanner.scan(extraDirs: extra)
            DispatchQueue.main.async { self?.reindex(paths: paths) }
        }
    }

    /// 兜底通道无事件流，60s 轮询补位（US-I2 的 ≤60s 口径）。
    private func startDirectoryPolling() {
        stopDirectoryPolling()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.scanDirectories()
        }
        RunLoop.main.add(timer, forMode: .common)
        directoryTimer = timer
    }

    private func stopDirectoryPolling() {
        directoryTimer?.invalidate()
        directoryTimer = nil
    }

    // MARK: - 解析与合并（后台）

    private func reindex(paths: [String]) {
        let showSystemTools = settings.showSystemTools
        let ownId = ownBundleId
        let previous = records
        parseQueue.async { [weak self] in
            var cache = self?.parsedCache ?? [:]
            let records = Self.parseAll(paths: paths, ownId: ownId,
                                        showSystemTools: showSystemTools, cache: &cache)
            let merged = Self.dedupeAndSort(records)
            DispatchQueue.main.async {
                self?.parsedCache = cache
                self?.publish(merged, previous: previous)
            }
        }
    }

    private func incrementalUpdate(added: [String], removed: [String]) {
        let showSystemTools = settings.showSystemTools
        let ownId = ownBundleId
        var previous = records
        parseQueue.async { [weak self] in
            var cache = self?.parsedCache ?? [:]
            let newRecords = Self.parseAll(paths: added, ownId: ownId,
                                           showSystemTools: showSystemTools, cache: &cache)
            let removedSet = Set(removed)
            previous = previous.filter { !removedSet.contains($0.path) }
            let removedIds = Set(newRecords.map(\.bundleId))
            previous = previous.filter { !removedIds.contains($0.bundleId) } // 同 id 新路径替换
            let merged = Self.dedupeAndSort(previous + newRecords)
            DispatchQueue.main.async {
                self?.parsedCache = cache
                self?.publish(merged, previous: self?.records ?? [])
            }
        }
    }

    /// 批量解析（可带 mtime 缓存）。
    static func parseAll(paths: [String], ownId: String, showSystemTools: Bool,
                         cache: inout [String: (mtime: TimeInterval, record: AppRecord)]) -> [AppRecord] {
        let fm = FileManager.default
        var out: [AppRecord] = []
        out.reserveCapacity(paths.count)
        for path in paths {
            guard path.hasSuffix(".app") else { continue }
            let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            if let hit = cache[path], hit.mtime == mtime {
                out.append(hit.record)
                continue
            }
            guard let record = AppParser.record(atPath: path, ownBundleId: ownId,
                                                showSystemTools: showSystemTools) else { continue }
            cache[path] = (mtime, record)
            out.append(record)
        }
        return out
    }

    /// 同 bundleId 去重：非 /System 副本优先，其次路径短者（同名系统/用户副本取用户副本）。
    static func dedupeAndSort(_ records: [AppRecord]) -> [AppRecord] {
        var best: [String: AppRecord] = [:]
        for r in records {
            if let cur = best[r.bundleId] {
                let curScore = (cur.isSystemApp ? 1 : 0)
                let newScore = (r.isSystemApp ? 1 : 0)
                if newScore < curScore || (newScore == curScore && r.path.count < cur.path.count) {
                    best[r.bundleId] = r
                }
            } else {
                best[r.bundleId] = r
            }
        }
        return best.values.sorted(by: AppRecord.isInDefaultOrder)
    }

    private func publish(_ merged: [AppRecord], previous: [AppRecord]) {
        parsedCachePrune(against: merged)
        records = merged
        state = .ready(count: merged.count, channel: activeChannel)
        if previous.count != merged.count || previous.map(\.bundleId) != merged.map(\.bundleId) {
            Log.index.info("索引就绪: \(merged.count) 个应用（通道=\(self.activeChannel.rawValue)）")
        }
    }

    private func parsedCachePrune(against records: [AppRecord]) {
        // 墓碑重装等场景缓存会膨胀，超过 2 倍当前规模时收缩
        guard parsedCache.count > records.count * 2 + 64 else { return }
        let live = Set(records.map(\.path))
        parsedCache = parsedCache.filter { live.contains($0.key) }
    }
}
