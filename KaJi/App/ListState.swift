//
//  ListState.swift
//  KaJi
//
//  列表与右栏模式状态。
//  负责列表筛选、右栏 editor/list 切换、当前 filter 下卡片缓存。
//
//  v1.2.9 T5 改造：cachedFilteredCards: [Card] → [CardSummary]（轻量）
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

    // v1.2.9 T5：当前筛选条件下的轻量卡片缓存
    @Published private(set) var cachedFilteredCards: [CardSummary] = []

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
    /// v1.2.9 T5：从 [CardSummary] 构造轻量 Card 供 openCard 编辑器使用
    /// v1.3.0：直连 editorState.data.openCard（删 facade 后）
    func openCardFromList(_ card: CardSummary, editorState: EditorState) {
        // 打开编辑器前从 SQLite 读完整 Card（含 fields）
        guard let fullCard = try? CardRepository.shared.card(id: card.id) else { return }
        editorState.data.openCard(fullCard)
        // v1.3.2：动画时长统一走 KaJiAnimation.modeSwitch
        withAnimation(KaJiAnimation.modeSwitch) {
            rightPaneMode = .editor
        }
    }

    /// 重新计算并缓存当前筛选条件下的卡片
    /// v1.2.9 T5 配套修复：值相等时**不**触发 objectWillChange
    func refreshFilteredCards() {
        let new = cardService.filteredCards(from: statsState.cachedSummaries, matching: listFilter)
        if new != cachedFilteredCards { cachedFilteredCards = new }
    }
}
