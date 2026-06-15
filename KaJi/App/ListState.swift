//
//  ListState.swift
//  KaJi
//
//  列表与右栏模式状态。
//  负责列表筛选、右栏 editor/list 切换、当前 filter 下卡片缓存。
//

import SwiftUI

@MainActor
final class ListState: ObservableObject {
    // MARK: - 右栏模式
    // .editor = 当前编辑的卡（NotesEditor）
    // .list   = 卡片列表（CardListView），由侧栏类型/标签/回收站触发
    enum RightPaneMode: Equatable {
        case editor
        case list
    }

    @Published var rightPaneMode: RightPaneMode = .editor

    // 列表筛选来源（独立模型：Models/ListFilter.swift）
    @Published var listFilter: ListFilter? = nil

    // 当前筛选条件下的卡片缓存：避免 SwiftUI 每次重绘都重新 filter + sort
    @Published private(set) var cachedFilteredCards: [Card] = []

    // 列表筛选对应的展示标题（用于顶部条）
    var listFilterTitle: String { listFilter?.title ?? "" }

    private let statsState: StatsState
    private let cardService = CardService.shared

    init(statsState: StatsState) {
        self.statsState = statsState
    }

    /// 进入列表模式（侧栏点击类型/标签/回收站时调用）
    func showList(_ filter: ListFilter) {
        listFilter = filter
        refreshFilteredCards()
        rightPaneMode = .list
    }

    /// 列表行点击 → 进入编辑
    func openCardFromList(_ card: Card, editorState: EditorState) {
        editorState.openCard(card)
        withAnimation(.easeInOut(duration: 0.18)) {
            rightPaneMode = .editor
        }
    }

    /// 重新计算并缓存当前筛选条件下的卡片
    /// v1.3.0 P0-5 配套修复：值相等时**不**触发 objectWillChange，避免 CardListView.body
    /// 在数据无变化时被无谓重建（同 StatsState.update 的修复理由）。
    func refreshFilteredCards() {
        let new = cardService.filteredCards(from: statsState.cachedCards, matching: listFilter)
        if new != cachedFilteredCards { cachedFilteredCards = new }
    }
}
