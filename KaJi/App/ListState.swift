//
//  ListState.swift
//  KaJi
//
//  列表与右栏模式状态。
//  负责列表筛选、右栏 editor/list 切换、当前 filter 下卡片缓存。
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

    @ObservationIgnored
    private var observerToken: UUID?

    init(statsState: StatsState, cardService: CardService = .shared) {
        self.statsState = statsState
        self.cardService = cardService
        // 用 StatsState 观察者回调替代 objectWillChange 订阅（@Observable 没有 objectWillChange）
        observerToken = statsState.addUpdateObserver { [weak self] in
            self?.refreshFilteredCards()
        }
    }

    /// 进入列表模式（侧栏点击类型/标签/回收站时调用）
    func showList(_ filter: ListFilter) {
        listFilter = filter
        refreshFilteredCards()
        rightPaneMode = .list
    }

    /// 重新计算并缓存当前筛选条件下的卡片。值相等时不更新（避免无谓重渲染）
    func refreshFilteredCards() {
        let new = cardService.filteredCards(from: statsState.cachedSummaries, matching: listFilter)
        if new != cachedFilteredCards { cachedFilteredCards = new }
    }
}