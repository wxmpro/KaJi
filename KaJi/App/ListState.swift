//
//  ListState.swift
//  KaJi
//
//  列表与右栏模式状态。
//  负责列表筛选、右栏 editor/list 切换、当前 filter 下卡片缓存。
//
//  v1.2.9 T5 改造：cachedFilteredCards: [Card] → [CardSummary]（轻量）
//  v1.4.0：迁移到 @Observable；用 StatsState.onUpdate 回调替代 objectWillChange 订阅
//

import SwiftUI

@Observable
@MainActor
final class ListState {
    // MARK: - 右栏模式
    enum RightPaneMode: Equatable {
        case editor
        case list
    }

    // MARK: - 列表筛选来源
    var listFilter: ListFilter? = nil

    // MARK: - 当前筛选条件下的轻量卡片缓存
    var cachedFilteredCards: [CardSummary] = []

    // MARK: - 右栏模式（@Observable 跟踪）
    var rightPaneMode: RightPaneMode = .editor

    /// 列表筛选对应的展示标题
    var listFilterTitle: String { listFilter?.title ?? "" }

    // MARK: - 依赖（@ObservationIgnored）
    @ObservationIgnored
    private let statsState: StatsState

    @ObservationIgnored
    private let cardService: CardService

    init(statsState: StatsState, cardService: CardService = .shared) {
        self.statsState = statsState
        self.cardService = cardService
        // v1.4.0：替代 v1.3.4 的 objectWillChange 订阅（@Observable 没有 objectWillChange）
        // Bug 9 修复：使用 addUpdateObserver 数组化 API，支持多个观察者
        // 用 DispatchQueue.main.async 把刷新推迟到下一个 runloop，确保 cachedSummaries 已更新为新值
        statsState.addUpdateObserver { [weak self] in
            DispatchQueue.main.async {
                self?.refreshFilteredCards()
            }
        }
    }

    /// 进入列表模式（侧栏点击类型/标签/回收站时调用）
    func showList(_ filter: ListFilter) {
        listFilter = filter
        refreshFilteredCards()
        rightPaneMode = .list
    }

    /// 重新计算并缓存当前筛选条件下的卡片
    /// v1.2.9 T5 配套修复：值相等时**不**触发 objectWillChange
    func refreshFilteredCards() {
        let new = cardService.filteredCards(from: statsState.cachedSummaries, matching: listFilter)
        if new != cachedFilteredCards { cachedFilteredCards = new }
    }
}