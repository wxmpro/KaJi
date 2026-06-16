//
//  EditorState.swift
//  KaJi
//
//  编辑器与当前卡片状态 — 容器层（v1.2.9 T2 改造完成）。
//
//  v1.2.9 T2 改造：原 11 个 @Published + 12 个方法全挤在一个类里，导致输入时
//  整棵 SwiftUI 视图树重建。按生命周期拆为 3 个独立 ObservableObject：
//    - EditorDataState    数据态（currentCard / currentCardType / currentCardTags / 业务方法）
//    - EditorUIState      UI 态（sidebarColumnVisibility / searchKeyword / isSearchActive）
//    - EditorAlertState   告警态（showingTypeChangeAlert / pendingCardType / saveError / ...）
//
//  本文件（EditorState）作为容器：
//    - 持有 3 个子 state（强引用）
//    - 持有 listState / statsState（弱引用，由 init 传入）
//    - 持有 undoManager（由 MainView.onAppear 注入）
//    - 业务方法 facade（startNewCard / openCard / softDeleteCard / ...）转发到子 state，
//      保证 KaJiApp 顶层菜单和外部调用方（ListState.openCardFromList 等）API 不变
//    - 保留 ObservableObject 协议让 @EnvironmentObject 仍能注入，但不暴露任何 @Published，
//      因此不会触发 objectWillChange（订阅者不会因为 facade 转发而重建）
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
    private let statsState: StatsState
    private let listState: ListState

    // MARK: - 容器持状态
    /// UndoManager 由 SwiftUI 环境注入（MainView.onAppear 设置）
    var undoManager: UndoManager?

    init(statsState: StatsState, listState: ListState) {
        self.statsState = statsState
        self.listState = listState

        // 1. 初始化子 state
        self.alert = EditorAlertState()
        self.data = EditorDataState(statsState: statsState, listState: listState, alert: alert)
        self.ui = EditorUIState()

        // 2. 同步初始 isInMemoryDB
        alert.isInMemoryDB = AppDatabase.shared.isInMemory

        // 3. 启动 bootstrap（reconcile + purgeOldTrash + 生成首卡）
        //    v1.2.8 串行化逻辑保留：reconcile 完成后才 generateNewCard，避免同一毫秒 ID 冲突。
        //    0 UI 视觉变化：用户感知的是"启动后首卡出现"，不是"启动后立刻看到"。
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                try await self.cardService.bootstrap(retentionDays: SettingsService.trashRetentionDays)
                self.statsState.rebuildStats()
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

    // MARK: - 业务方法 facade（实际实现在 data / ui 子 state）

    /// 切换侧栏显隐
    func toggleSidebar() {
        ui.toggleSidebar()
    }

    /// 开一张新卡（屏 1 用）
    func startNewCard(type: CardType = .free) {
        data.startNewCard(type: type)
    }

    /// 列表行点击后把指定卡片加载进编辑器
    func openCard(_ card: Card) {
        data.openCard(card)
    }

    func requestCardTypeChange(to type: CardType) {
        data.requestCardTypeChange(to: type)
    }

    func confirmPendingCardTypeChange() {
        data.confirmPendingCardTypeChange()
    }

    /// Undo 入口：恢复卡片类型和字段（由 CardTypeChangeService 注册）
    func undoCardTypeChange(to type: CardType, fields: [CardField]) {
        data.undoCardTypeChange(to: type, fields: fields)
    }

    /// 复制当前卡片全部内容到剪贴板（Markdown 格式）
    func copyAllContentToPasteboard() {
        data.copyAllContentToPasteboard()
    }

    // MARK: - 自动保存

    /// 任何字段被编辑都会调用，800ms debounce 后真正落库
    func saveImmediately() {
        data.saveImmediately()
    }

    /// 强制立即落库（失焦 / 退出 / ⌘S 时调用）
    func flushSave() {
        data.flushSave()
    }

    // MARK: - 卡片生命周期

    /// 列表行/菜单删除入口：带 UndoManager 注册
    func softDeleteCard(_ card: Card) {
        data.softDeleteCard(card)
    }

    /// Undo 入口：从回收站恢复卡片
    func restoreCard(_ card: Card) {
        data.restoreCard(card)
    }
}
