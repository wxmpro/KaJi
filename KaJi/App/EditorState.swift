//
//  EditorState.swift
//  KaJi
//
//  编辑器与当前卡片状态 — 启动期容器。
//
//  v1.2.9 T2 改造：原 11 个 @Published + 12 个方法全挤在一个类里，导致输入时
//  整棵 SwiftUI 视图树重建。按生命周期拆为 3 个独立 ObservableObject：
//    - EditorDataState    数据态（currentCard / currentCardType / currentCardTags / 业务方法）
//    - EditorUIState      UI 态（sidebarColumnVisibility / searchKeyword / isSearchActive）
//    - EditorAlertState   告警态（showingTypeChangeAlert / pendingCardType / saveError / ...）
//
//  v1.3.0：删除 v1.2.9 临时加的 11 个 facade 转发方法；调用方已全部迁到
//  data / ui / alert 子 state 直连。
//
//  v1.3.3 PATCH：进一步瘦身为"启动期编排容器"。
//    - 删 undoManager 字段（已迁移到 EditorDataState 持有，由 MainView.onAppear 注入）
//    - 删 cardService 字段（直接调 CardService.shared）
//    - 容器唯一职责：①持有 3 个子 state 强引用 ②init 期构造顺序编排 ③bootstrap 跨 state 启动
//    - 7 个 View 不再注入本容器；KaJiApp 顶层菜单走 data/ui 3 层链
//    - EditorState 仍为 ObservableObject（保证 API 兼容），但无 @Published 不触发 objectWillChange
//

import SwiftUI
import AppKit

@MainActor
final class EditorState: ObservableObject {
    // MARK: - 子 state（强引用）
    let data: EditorDataState
    let ui: EditorUIState
    let alert: EditorAlertState

    init(statsState: StatsState, listState: ListState) {
        // 1. 初始化子 state（顺序敏感：alert 先于 data，data 用 weak 引用 alert）
        self.alert = EditorAlertState()
        self.data = EditorDataState(statsState: statsState, listState: listState, alert: alert)
        self.ui = EditorUIState()
        alert.isInMemoryDB = AppDatabase.shared.isInMemory

        // 2. 启动 bootstrap（reconcile + purgeOldTrash + 生成首卡）
        //    v1.2.8 串行化逻辑保留：reconcile 完成后才 generateNewCard，避免同一毫秒 ID 冲突。
        //    0 UI 视觉变化：用户感知的是"启动后首卡出现"，不是"启动后立刻看到"。
        //    v1.3.0：bootstrap 改 async（reconcile 走 MarkdownWriteQueue）
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await CardService.shared.bootstrap(retentionDays: SettingsService.trashRetentionDays)
                statsState.rebuildStats()
                // v1.3.4 PATCH：启动后不生成带 UUID 的卡，显示无 UUID 自由卡草稿
                self.data.currentCard = nil
                self.data.currentCardType = .free
                self.data.currentCardTags = []
            } catch {
                self.alert.saveError = "启动失败：\(error.localizedDescription)"
                self.data.currentCard = nil
                self.data.currentCardType = .free
                self.data.currentCardTags = []
            }
        }
    }
}
