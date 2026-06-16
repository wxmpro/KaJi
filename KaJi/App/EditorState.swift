//
//  EditorState.swift
//  KaJi
//
//  编辑器与当前卡片状态 — 容器层。
//
//  v1.2.9 T2 改造：原 11 个 @Published + 12 个方法全挤在一个类里，导致输入时
//  整棵 SwiftUI 视图树重建。按生命周期拆为 3 个独立 ObservableObject：
//    - EditorDataState    数据态（currentCard / currentCardType / currentCardTags / 业务方法）
//    - EditorUIState      UI 态（sidebarColumnVisibility / searchKeyword / isSearchActive）
//    - EditorAlertState   告警态（showingTypeChangeAlert / pendingCardType / saveError / ...）
//
//  v1.3.0：删除 v1.2.9 临时加的 11 个 facade 转发方法；调用方已全部迁到
//  data / ui / alert 子 state 直连。本容器现在只负责：
//    - 持有 3 个子 state（强引用）
//    - bootstrap（reconcile + purgeOldTrash + 生成首卡）
//    - undoManager（由 MainView.onAppear 注入，Undo 菜单仍走 editorState.undoManager）
//
//  EditorState 仍为 ObservableObject（让 @EnvironmentObject var editorState 仍能注入），
//  不暴露任何 @Published，因此不会触发 objectWillChange。
//

import SwiftUI
import AppKit

@MainActor
final class EditorState: ObservableObject {
    // MARK: - 子 state（强引用）
    let data: EditorDataState
    let ui: EditorUIState
    let alert: EditorAlertState

    // MARK: - 依赖
    private let cardService = CardService.shared

    // MARK: - 容器持状态
    /// UndoManager 由 SwiftUI 环境注入（MainView.onAppear 设置）
    /// 保留在容器中：KaJiApp 顶层菜单的撤销/重做走 editorState.undoManager
    var undoManager: UndoManager?

    init(statsState: StatsState, listState: ListState) {
        // 1. 初始化子 state
        self.alert = EditorAlertState()
        self.data = EditorDataState(statsState: statsState, listState: listState, alert: alert)
        self.ui = EditorUIState()

        // 2. 同步初始 isInMemoryDB
        alert.isInMemoryDB = AppDatabase.shared.isInMemory

        // 3. 启动 bootstrap（reconcile + purgeOldTrash + 生成首卡）
        //    v1.2.8 串行化逻辑保留：reconcile 完成后才 generateNewCard，避免同一毫秒 ID 冲突。
        //    0 UI 视觉变化：用户感知的是"启动后首卡出现"，不是"启动后立刻看到"。
        //    v1.3.0：bootstrap 改 async（reconcile 走 MarkdownWriteQueue）
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await self.cardService.bootstrap(retentionDays: SettingsService.trashRetentionDays)
                statsState.rebuildStats()
                let card = try await self.cardService.generateNewCard(type: .free)
                self.data.currentCard = card
                self.data.currentCardType = .free
                self.data.currentCardTags = []
            } catch {
                self.alert.saveError = "无法生成新卡编码：\(error.localizedDescription)"
                self.data.currentCard = nil
                self.data.currentCardType = .free
                self.data.currentCardTags = []
            }
        }
    }
}
