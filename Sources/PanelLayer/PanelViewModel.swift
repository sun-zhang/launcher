import AppKit
import Core
import Foundation
import Combine

/// 网格单元（设置入口为右下角悬浮角标，不占格位——原首页第一格方案废弃）。
public enum GridEntry: Identifiable, Hashable {
    case app(AppRecord)

    public var id: String {
        switch self {
        case .app(let r): return r.bundleId
        }
    }

    public var displayName: String {
        switch self {
        case .app(let r): return r.name
        }
    }
}

/// 面板内容状态（@MainActor）：分页、搜索、键盘导航、图标加载。
/// 键盘事件由 PanelController 的本地监听转发进来（IME 组字期事件不入此层）。
@MainActor
public final class PanelViewModel: ObservableObject {

    @Published public var query = "" {
        didSet { recomputeSearch() }
    }
    @Published public private(set) var pages: [[GridEntry]] = []
    @Published public private(set) var currentPage: Int = 0
    /// 当前页内 flat 下标（含首页的设置格=0）；nil = 无选中。
    @Published public private(set) var selection: Int?
    @Published public private(set) var searchSelection: Int?
    @Published public private(set) var searchResults: [AppRecord] = []
    @Published public private(set) var iconImages: [String: NSImage] = [:]
    @Published public var isPanelVisible = false
    /// 本次唤起来源（控制器在 isPanelVisible 置 true 前写入）：
    /// 捏合唤起（.gesture）手还在触摸板上，搜索框不自动聚焦——
    /// FR-S1 的「唤出即聚焦」只保留给键盘类来路（热键等）。
    @Published public private(set) var openSource: SourceKind?
    /// 裸键盘注入后请求聚焦搜索框的脉冲（视图层转 FocusState，见 injectSearchText）。
    @Published public private(set) var searchFocusPulse = 0
    /// 翻页纸带演出进行中：实时网格让位（PanelContentView 以空占位替换网格区），
    /// 页面视觉由演出层唯一提供——双层同时显示会重影（真机回归实证）。
    @Published public private(set) var isPageStripActive = false

    /// 纸带演出层开关（PanelController 在搭 band / 清场时同步）。
    public func setPageStripActive(_ active: Bool) {
        isPageStripActive = active
    }

    public private(set) var columns: Int = 7
    private var records: [AppRecord] = []
    private var inflightIcons = Set<String>()

    // App 层注入
    public init() {}

    public var onLaunch: ((AppRecord) -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onShouldClose: (() -> Void)?
    public var onRescan: (() -> Void)?
    /// 退出应用（面板左下角电源角标；菜单栏图标移除后的唯一退出入口）。
    public var onQuit: (() -> Void)?

    public var isSearching: Bool { !query.isEmpty }

    /// 控制器在唤起时标记来源（先于 isPanelVisible = true，同拍生效）。
    public func markOpenSource(_ source: SourceKind) {
        openSource = source
    }

    /// 搜索框未聚焦时（捏合唤起）的裸键入：字符直接并入 query 并请求聚焦，
    /// 后续按键走正常文本链（IME 组字从聚焦起自然衔接；首字符按拼音/英文
    /// 直接匹配——SearchEngine 本就支持拼音，首键不走输入法也不丢）。
    public func injectSearchText(_ text: String) {
        query += text
        searchFocusPulse += 1
    }

    // MARK: - 数据装配

    /// 索引/布局变化时重建页面（保持当前页尽量不动）。
    public func install(records: [AppRecord], layout: LayoutDocument) {
        self.records = records
        self.columns = min(9, max(5, layout.grid.columns))

        var byId: [String: AppRecord] = [:]
        for r in records { byId[r.bundleId] = r }

        var pages: [[GridEntry]] = []
        for page in layout.pages {
            // 按 slot 摆放（空洞保留为 nil 占位，避免错位）
            let cap = LayoutBuilder.capacity(columns: columns)
            var cells = [GridEntry?](repeating: nil, count: cap)
            var overflow: [GridEntry] = []
            for item in page.items {
                guard let record = byId[item.bundleId] else { continue }  // 防御：索引未跟上布局
                let cell = GridEntry.app(record)
                if item.slot < cap, cells[item.slot] == nil {
                    cells[item.slot] = cell
                } else {
                    overflow.append(cell)
                }
            }
            var pageItems = cells.compactMap { $0 }
            pageItems.append(contentsOf: overflow)
            pages.append(pageItems)
        }
        if pages.isEmpty, !records.isEmpty {
            pages = [records.map { GridEntry.app($0) }]   // 布局空文档兜底：单页全量直排
        }
        self.pages = pages

        if currentPage >= pages.count { currentPage = max(0, pages.count - 1) }
        clampSelection()
    }

    // MARK: - 翻页（US-G1 三途径：滑动/←→越界/页码点）

    public func goToPage(_ index: Int) {
        let clamped = min(max(0, index), max(0, pages.count - 1))
        guard clamped != currentPage else { return }
        currentPage = clamped
        selection = nil   // 翻页清除选中态（Launchpad 习惯）
    }

    public func pageDelta(_ delta: Int) {
        goToPage(currentPage + delta)
    }

    public var pageCount: Int { pages.count }

    // MARK: - 搜索（FR-S1..S3）

    private func recomputeSearch() {
        guard isSearching else {
            searchResults = []
            searchSelection = nil
            return
        }
        searchResults = SearchEngine.search(query, in: records)
        searchSelection = searchResults.isEmpty ? nil : 0
    }

    // MARK: - 键盘（FR-G3 / FR-S4 / US-T4）

    public enum Arrow { case left, right, up, down }

    /// Esc 链：先清搜索，再由调用方关面板（US-T4 AC1）。
    /// - Returns: true = 已消费（清空了搜索）。
    public func escAction() -> Bool {
        if !query.isEmpty {
            query = ""
            return true
        }
        return false
    }

    public func handleArrow(_ arrow: Arrow) {
        guard isSearching else { navigateGrid(arrow); return }

        // 搜索态：结果与页面同口径列优先排布（↓↑ 沿列 ±1，←→ 换列 ±行数）
        guard !searchResults.isEmpty else { return }
        let current = searchSelection ?? 0
        let next: Int
        switch arrow {
        case .down: next = current + 1
        case .up: next = current - 1
        case .right: next = current + LayoutBuilder.rows
        case .left: next = current - LayoutBuilder.rows
        }
        searchSelection = min(max(0, next), searchResults.count - 1)
    }

    /// 网格为列优先排布（逻辑序号 k 落位 行=k%rows、列=k/rows）：
    /// ↓↑ = ±1（同列换行），←→ = ±rows（同行换列）。
    private func navigateGrid(_ arrow: Arrow) {
        guard !pages.isEmpty else { return }
        let count = pages[currentPage].count
        let rows = LayoutBuilder.rows

        // 无选中时首次按方向键：从首格出发
        let current = selection ?? 0
        selection = current
        var page = currentPage
        var index = current

        switch arrow {
        case .right:
            let next = index + rows
            if next < count { index = next }
            else if page < pages.count - 1 {
                page += 1
                index = min(index % rows, pages[page].count - 1)   // 越页保持行位
            }
        case .left:
            let next = index - rows
            if next >= 0 { index = next }
            else if page > 0 {
                page -= 1
                let prevCount = pages[page].count
                let lastCol = (prevCount - 1) / rows
                index = min(lastCol * rows + index % rows, prevCount - 1)   // 上一页同行最右列
            }
        case .down:
            let next = index + 1
            if next < count { index = next }
            else if page < pages.count - 1 {
                page += 1
                index = min(max(0, next - count), pages[page].count - 1)
            }
        case .up:
            let next = index - 1
            if next >= 0 { index = next }
            else if page > 0 {
                page -= 1
                index = pages[page].count - 1   // 上一页最末（右下角）
            }
        }
        goToPage(page)   // 越页时经统一入口（含页码钳制与选中清理）
        selection = index
    }

    /// Enter：搜索态启动（首个/所选）候选；网格态启动所选格（US-S2 / FR-S4）。
    public func activateSelected() {
        if isSearching {
            guard !searchResults.isEmpty else { return }
            let index = searchSelection ?? 0
            launch(searchResults[index])
            return
        }
        guard let index = selection, index < pages[currentPage].count,
              case .app(let record) = pages[currentPage][index] else { return }
        launch(record)
    }

    public func clickItem(_ item: GridEntry) {
        guard case .app(let record) = item else { return }
        launch(record)
    }

    private func launch(_ record: AppRecord) {
        onLaunch?(record)
    }

    /// 面板关闭后清理瞬时态（currentPage 一并归零——翻页状态不跨会话保留，
    /// 每次唤起恒显第一页；唤起路径在 openPanel/预览处另有归零双保险）。
    public func resetTransient() {
        query = ""
        selection = nil
        searchSelection = nil
        goToPage(0)
        inflightIcons.removeAll()
    }

    // MARK: - 图标（US-I4：占位→异步替换）

    /// 命中内存缓存则返回，否则发起异步加载并返回 nil（调用方先画占位）。
    public func icon(for item: GridEntry) -> NSImage? {
        guard case .app(let record) = item else { return nil }
        if let hit = iconImages[record.bundleId] { return hit }
        requestIcon(record)
        return nil
    }

    private func requestIcon(_ record: AppRecord) {
        guard !inflightIcons.contains(record.bundleId) else { return }
        inflightIcons.insert(record.bundleId)
        IconCache.shared.image(for: record) { [weak self] image in
            guard let self else { return }
            self.inflightIcons.remove(record.bundleId)
            self.iconImages[record.bundleId] = image
        }
    }

    private func clampSelection() {
        guard !pages.isEmpty else { selection = nil; return }
        if let index = selection, index >= pages[currentPage].count {
            selection = nil
        }
    }
}
