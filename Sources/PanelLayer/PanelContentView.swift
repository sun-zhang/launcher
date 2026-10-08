import AppKit
import Core
import SwiftUI

/// 面板内容骨架尺寸的单一事实源：实时面板（真实搜索条/页点）与翻页纸带 band
/// （等尺寸占位复刻）共用——两套网格纵向逐像素同位是纸带换页无重影的前提。
/// 改动搜索条/页点/边距尺寸时只改这里，两侧自动同步。
enum PanelSkeleton {
    static func topInset(height: CGFloat) -> CGFloat { height * 0.055 }
    static let searchBarSize = CGSize(width: 240, height: 30)
    /// 搜索条 → 网格的固定间距（呼吸隙 32 + 上弹性隙 16）：网格自顶排布，
    /// 未满页从网格区顶部起纵向填充，剩余空隙全部落到网格下方。
    static let gridTopGap: CGFloat = 48
    static let pageDotSize: CGFloat = 7
    static let bottomInset: CGFloat = 46
}

/// 面板内容（SwiftUI）：搜索条 + 网格分页 + 页码点 + 空态（X5）。
/// 窗口与事件层在 AppKit（PanelController / PanelRootView）。
struct PanelContentView: View {

    @ObservedObject var model: PanelViewModel
    @FocusState private var searchFocused: Bool
    @State private var settingsHovered = false
    @State private var quitHovered = false

    // Launchpad 布局比例（参考图实测：视觉网格跨 0.80W、图标 0.066W、视觉列间距 ≈ 0.79×图标宽）
    private let gridSpanRatio: CGFloat = 0.86     // 网格最大跨宽 / 屏宽（列数多时收缩兜底）
    private let iconWidthRatio: CGFloat = 0.068   // 图标宽 / 屏宽
    /// LazyVGrid 的列间距 = 目标视觉间距 − 格内左右留白（0.47×图标），即 0.79−0.47
    private let gapToIconRatio: CGFloat = 0.32

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 空白点击关闭（FR-T4 / US-T4 AC2）
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.onShouldClose?() }

                VStack(spacing: 0) {
                    Spacer().frame(height: PanelSkeleton.topInset(height: geo.size.height))

                    searchBar

                    Spacer().frame(height: PanelSkeleton.gridTopGap)

                    if model.isSearching {
                        searchResultsView(width: geo.size.width, height: geo.size.height)
                    } else if model.pages.isEmpty {
                        emptyState
                    } else if model.isPageStripActive {
                        // 纸带演出中：网格区让位为空——页面视觉由演出层唯一提供，
                        // 双层网格同屏会重影（真机回归实证）；搜索条/页点保持实时。
                        Color.clear
                    } else {
                        pageView(width: geo.size.width, height: geo.size.height)
                    }

                    Spacer()

                    if !model.isSearching && model.pageCount > 1 {
                        pageDots
                    }
                    Spacer().frame(height: PanelSkeleton.bottomInset)
                }
            }
            // 右下角设置角标 + 左下角退出角标（原首页第一格方案废弃）：与页点同一
            // 视觉口径——半透明白 + 轻投影（浅色壁纸上仍可辨），hover 提亮，无底板
            // 与背景融合。纵向与页点线对齐（bottomInset 带内）；设置走 openSettings
            // 链路（面板退场 + 设置置顶），退出为菜单栏图标移除后的唯一应用退出入口。
            .overlay(alignment: .bottomTrailing) {
                if !model.isSearching {
                    cornerBadge(symbol: "gearshape.fill", hovered: settingsHovered) {
                        model.onOpenSettings?()
                    } onHover: { settingsHovered = $0 }
                        .padding(.trailing, 24)
                        .padding(.bottom, 35)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !model.isSearching {
                    cornerBadge(symbol: "power", hovered: quitHovered) {
                        model.onQuit?()
                    } onHover: { quitHovered = $0 }
                        .padding(.leading, 24)
                        .padding(.bottom, 35)
                }
            }
        }
        .onChange(of: model.isPanelVisible) { _, visible in
            // FR-S1 唤出即聚焦——仅键盘类来路；捏合唤起（.gesture）手在触摸板上，
            // 聚焦无意义且焦点样式抢眼（裸键入仍可搜索，经 injectSearchText）
            searchFocused = visible && model.openSource != .gesture
        }
        .onChange(of: model.searchFocusPulse) { _, _ in
            searchFocused = true   // 裸键盘注入后的聚焦请求（见 injectSearchText）
        }
        .onChange(of: searchFocused) { _, focused in
            // 聚焦即抑制 autofill 建议窗闪现（见 PanelController.suppressAutofillSuggestionBurst）
            if focused { PanelController.shared?.suppressAutofillSuggestionBurst() }
        }
    }

    // MARK: - 底部角标（设置 / 退出共用视觉口径）

    /// 半透明图标角标：hover 提亮 + 轻投影，无底板与背景融合。
    private func cornerBadge(symbol: String, hovered: Bool,
                             onTap: @escaping () -> Void,
                             onHover: @escaping (Bool) -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white.opacity(hovered ? 0.9 : 0.38))
            .shadow(color: .black.opacity(0.4), radius: 1.2, y: 0.6)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .onHover { onHover($0) }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }

    // MARK: - 搜索条（FR-S1：顶部居中，键盘类来路唤出即聚焦）
    // 深色半透明胶囊（Launchpad 口径）：浅色壁纸上依然可读，聚焦时描边增强。

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
            TextField("", text: $model.query,
                      prompt: Text("搜索").foregroundColor(.white.opacity(0.45)))
                .textFieldStyle(.plain)
                // 搜索内容为应用名/拼音，本就用不到更正与预测（语义性关闭；
                // 真正的闪框根因与对策见 PanelController.suppressAutofillSuggestionBurst）
                .autocorrectionDisabled(true)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .focused($searchFocused)
                .onSubmit { model.activateSelected() }
            if model.isSearching {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 240, height: 30)
        .background(
            Capsule().fill(Color.black.opacity(searchFocused ? 0.32 : 0.24))
        )
        .overlay(
            Capsule().strokeBorder(
                Color.white.opacity(searchFocused ? 0.35 : 0.12),
                lineWidth: searchFocused ? 1 : 0.5)
        )
        .animation(.easeOut(duration: 0.15), value: searchFocused)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }

    // MARK: - 网格

    private func pageView(width: CGFloat, height: CGFloat) -> some View {
        grid(items: model.pages[model.currentPage], width: width, height: height,
             selectionIndex: model.selection) { item in
            model.clickItem(item)
        }
    }

    private func searchResultsView(width: CGFloat, height: CGFloat) -> some View {
        let items = model.searchResults.prefix(35).map(GridEntry.app)
        if items.isEmpty {
            return AnyView(noResultsState)
        } else {
            return AnyView(
                grid(items: Array(items), width: width, height: height,
                     selectionIndex: model.searchSelection) { item in
                    model.clickItem(item)
                }
                .transition(.opacity)
            )
        }
    }

    /// Launchpad 比例布局：图标/间距/网格跨宽均按屏幕宽度推算，行距按剩余高度均摊；
    /// 矮屏或列数多时先按高度收缩图标，网格超宽时整体等比缩。
    private func grid(items: [GridEntry], width: CGFloat, height: CGFloat, selectionIndex: Int?,
                      onTap: @escaping (GridEntry) -> Void) -> some View {
        PageGridView(items: items, columns: model.columns,
                     width: width, height: height,
                     selectionIndex: selectionIndex,
                     iconProvider: { model.icon(for: $0) },
                     onTap: onTap)
    }

    // MARK: - 页码点（US-G1）

    private var pageDots: some View {
        HStack(spacing: 14) {
            ForEach(0..<model.pageCount, id: \.self) { page in
                Circle()
                    .fill(Color.white.opacity(page == model.currentPage ? 0.95 : 0.30))
                    .frame(width: 7, height: 7)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .onTapGesture { model.goToPage(page) }
            }
        }
    }

    // MARK: - 空态（X5 / FR-D4）

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(.white.opacity(0.5))
            Text("未发现应用")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Text("如果你刚刚迁移了系统或关闭了 Spotlight，可以手动重扫")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.55))
            Button("重扫应用索引") { model.onRescan?() }
                .buttonStyle(.link)
                .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 12) {
            Text("无匹配「\(model.query)」")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
            Text("试试拼音首字母或应用英文名")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 单元格

/// Launchpad 口径：图标占格宽 ~68%，标签至多两行、固定高度（行内图标严格对齐），
/// 图标带轻投影、标签带文字阴影（毛玻璃壁纸上的可读性）。
struct GridCellView: View {
    let item: GridEntry
    let icon: NSImage?
    let isSelected: Bool
    var cellSize: CGFloat = 128

    /// 图标宽 = 格宽 × 比例（网格高度预算反解格子时共用）
    static let iconRatio: CGFloat = 0.68
    /// 两行 12.5pt 文字 ≈ 30pt（低于此 SwiftUI 会退回单行截断）
    private var labelHeight: CGFloat { 30 }
    private var iconSize: CGFloat { (cellSize * Self.iconRatio).rounded() }
    private var selectionRadius: CGFloat { (cellSize * 0.23).rounded() }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: iconSize, height: iconSize)
                        .shadow(color: .black.opacity(0.24), radius: 4, y: 2)
                } else {
                    // 占位（US-I4：图标就位前的浅灰方块）
                    RoundedRectangle(cornerRadius: iconSize * 0.22)
                        .fill(Color.white.opacity(0.10))
                        .frame(width: iconSize, height: iconSize)
                }
            }
            Text(item.displayName)
                .font(.system(size: 12.5))
                .foregroundColor(.white.opacity(0.95))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(width: cellSize - 8, height: labelHeight, alignment: .top)
                .shadow(color: .black.opacity(0.5), radius: 1.2, y: 0.8)
        }
        .padding(.vertical, 2)
        .frame(width: cellSize)
        .background(
            RoundedRectangle(cornerRadius: selectionRadius)
                .fill(isSelected ? Color.white.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: selectionRadius)
                .strokeBorder(Color.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}


/// 独立网格页视图：布局参数显式传入。iconProvider 会触发异步加载并
/// 返回 nil（占位），图标就位后由 model 发布驱动重渲。
struct PageGridView: View {
    let items: [GridEntry]
    let columns: Int
    let width: CGFloat
    let height: CGFloat
    var selectionIndex: Int? = nil
    var iconProvider: (GridEntry) -> NSImage? = { _ in nil }
    var onTap: (GridEntry) -> Void = { _ in }

    // 与 PanelContentView 同源的 Launchpad 布局比例
    private let gridSpanRatio: CGFloat = 0.86
    private let iconWidthRatio: CGFloat = 0.068
    private let gapToIconRatio: CGFloat = 0.32

    var body: some View {
        let cols = CGFloat(columns)
        var icon = width * iconWidthRatio                   // 图标目标宽
        var gapX = max(20, icon * gapToIconRatio)           // 列间距

        // 列优先排布（先从上到下、再从左到右）：逻辑序号 k 落位 (行 k%R, 列 k/R)，
        // R = 页面固定行数；视觉行数 = 最高列高度（≤ R）。未满页沿左侧列填满，
        // 与满页的纵向占位一致，不再是一两行图标悬在网格区中央。
        let rowCount = LayoutBuilder.rows
        let rows = CGFloat(max(1, min(items.count, rowCount)))

        // 高度预算：顶距/搜索条/固定间距(48=32+16)/下弹性隙/页点/底距之外的净空间
        // （网格自顶排布，预算口径与 PanelSkeleton.gridTopGap 分解一致）
        let vBudget = height - height * 0.055 - 30 - 32 - 16 - 16 - 20 - 46
        let cellOverhead: CGFloat = 37                      // spacing 3 + 标签 30 + padding 4
        let maxIconH = (vBudget - (rows - 1) * 18 - rows * cellOverhead) / rows
        if icon > maxIconH { icon = maxIconH }

        var cell = max(96, icon / GridCellView.iconRatio)
        // 网格超宽（列数多）→ 等比收缩
        let span = cols * cell + (cols - 1) * gapX
        let maxSpan = width * gridSpanRatio
        if span > maxSpan {
            let k = maxSpan / span
            cell *= k; gapX *= k
        }
        // 行距 = 高度预算均摊剩余，夹在 Launchpad 观感区间
        let contentH = cell * GridCellView.iconRatio + cellOverhead
        let rowGap = min(40, max(18, (vBudget - rows * contentH) / max(1, rows - 1)))

        // LazyVGrid 按行主序消费数组：按「行→列」扫描生成 (逻辑序号, 格)，
        // 逻辑序号供 selectionIndex 对位（模型侧方向键导航按同一坐标口径）。
        var ordered: [(index: Int, entry: GridEntry)] = []
        ordered.reserveCapacity(items.count)
        for row in 0..<rowCount {
            for col in 0..<columns {
                let k = col * rowCount + row
                if k < items.count { ordered.append((k, items[k])) }
            }
        }

        let gridColumns = Array(
            repeating: GridItem(.flexible(minimum: cell, maximum: cell), spacing: gapX),
            count: columns)
        let gridWidth = cols * cell + (cols - 1) * gapX

        return LazyVGrid(columns: gridColumns, spacing: rowGap) {
            ForEach(ordered, id: \.entry.id) { pair in
                GridCellView(item: pair.entry,
                             icon: iconProvider(pair.entry),
                             isSelected: selectionIndex == pair.index,
                             cellSize: cell)
                    .onTapGesture { onTap(pair.entry) }
            }
        }
        .frame(width: gridWidth)
        .frame(maxWidth: .infinity)
    }
}

/// 翻页纸带单页内容：复刻 PanelContentView 的 VStack 骨架（搜索条/页点用
/// 等尺寸占位），网格纵向位置与实时面板逐像素一致——基准页 band 必须完全
/// 盖住底层实时网格，否则拖拽时两套图标重影（真机回归实证）。
/// 页点占位恒在：纸带只在 pageCount > 1 时活动，与实时面板显点条件一致。
struct PageBandContent: View {
    let items: [GridEntry]
    let columns: Int
    let width: CGFloat
    let height: CGFloat
    var iconProvider: (GridEntry) -> NSImage? = { _ in nil }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: PanelSkeleton.topInset(height: height))
            Color.clear.frame(width: PanelSkeleton.searchBarSize.width,
                              height: PanelSkeleton.searchBarSize.height)
            Spacer().frame(height: PanelSkeleton.gridTopGap)
            PageGridView(items: items, columns: columns, width: width, height: height,
                         iconProvider: iconProvider)
            Spacer()
            Color.clear.frame(width: PanelSkeleton.pageDotSize,
                              height: PanelSkeleton.pageDotSize)
            Spacer().frame(height: PanelSkeleton.bottomInset)
        }
    }
}
