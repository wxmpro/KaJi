//
//  ListState.swift
//  KaJi
//
//  列表与右栏模式状态。
//  负责列表筛选、右栏 editor/list 切换、当前 filter 下卡片缓存。
//

import SwiftUI
import GRDB

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
    private var listObservationTask: Task<Void, Never>?

    init(statsState: StatsState, cardService: CardService = .shared) {
        self.statsState = statsState
        self.cardService = cardService
    }

    /// 进入列表模式（侧栏点击类型/标签/回收站时调用）
    func showList(_ filter: ListFilter?) {
        listFilter = filter
        if filter != nil {
            rightPaneMode = .list
        }
        startObservingList()
    }

    /// 启动对当前筛选条件的数据库实时监听
    private func startObservingList() {
        listObservationTask?.cancel()
        listObservationTask = Task { @MainActor in
            let filter = self.listFilter
            let observation = ValueObservation.tracking { db in
                try CardRepository.shared.fetchFilteredCards(db: db, filter: filter)
            }
            
            do {
                for try await cards in observation.values(in: AppDatabase.shared.dbWriter) {
                    if Task.isCancelled { break }
                    self.cachedFilteredCards = cards
                }
            } catch {
                // Ignore cancellation or DB errors
            }
        }
    }
}