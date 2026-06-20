//
//  KaJiApp.swift
//  KaJi — 卡迹 · Mac 原生卡片笔记
//
//  macOS 26 原生窗口设计：
//  - WindowGroup + .windowToolbarStyle(.unifiedCompact) 实现统一工具栏
//  - NavigationSplitView 侧栏自动延伸到 titlebar，traffic-lights 视觉上落在侧栏顶部
//  - .searchable(placement: .toolbar) 提供原生 NSSearchToolbarItem 搜索
//
//  v1.3.1：保留 toolbar 范式；那条 1px 分隔线在 AppDelegate.configure 中
//  通过 window.toolbar?.showsBaselineSeparator = false 消除。
//
//  v1.4.0：
//  - @EnvironmentObject → @Environment（@Observable 细粒度订阅）
//  - 删 EditorState 中间层，AppDelegate 直接持有 5 个 state
//  - 命令组直接走 appDelegate.data / appDelegate.ui
//

import SwiftUI
import AppKit

@main
struct KaJiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(appDelegate.data)
                .environment(appDelegate.ui)
                .environment(appDelegate.alertState)
                .environment(appDelegate.listState)
                .environment(appDelegate.statsState)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        .defaultPosition(.center)
        .commands {
            // MARK: File Menu
            CommandGroup(replacing: .newItem) {
                Button("新建卡片") {
                    appDelegate.data.startNewDraft(type: .free)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .importExport) {
                Button("导出当前卡片") {
                    guard let card = appDelegate.data.currentCard else { return }
                    ExportService.exportCard(card)
                }
                .keyboardShortcut("e", modifiers: .command)

                Button("导出全部卡片") {
                    ExportService.exportAll()
                }
                .keyboardShortcut("E", modifiers: [.command, .shift])
            }

            // MARK: Edit Menu
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") {
                    appDelegate.data.undoManager?.undo()
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("重做") {
                    appDelegate.data.undoManager?.redo()
                }
                .keyboardShortcut("Z", modifiers: [.command, .shift])
            }

            CommandGroup(after: .pasteboard) {
                Divider()

                Button("删除") {
                    appDelegate.data.softDeleteDraft()
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }

            // MARK: View Menu
            CommandGroup(after: .sidebar) {
                Button("切换侧栏") {
                    appDelegate.ui.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }

            // MARK: Help Menu
            CommandGroup(replacing: .help) {
                Button("KaJi 帮助") {
                    guard let url = URL(string: "https://github.com/xinmin/kaji") else { return }
                    NSWorkspace.shared.open(url)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

/// AppDelegate
/// v1.4.0：接管原 EditorState 的启动期职责（reconcile + purge + 首卡初始化）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // v1.4.0：直接持有 5 个 state，无中间层
    let statsState: StatsState
    let listState: ListState
    let alertState: EditorAlertState
    let data: EditorDataState
    let ui: EditorUIState

    override init() {
        self.statsState = StatsState()
        self.listState = ListState(statsState: statsState)
        self.alertState = EditorAlertState()
        self.ui = EditorUIState()
        self.data = EditorDataState(
            statsState: statsState,
            listState: listState,
            alert: alertState
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        SettingsService.restoreThemeOnLaunch()
        configureWindows()
        bootstrap()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // v1.6.1：退出走 .terminateLater + 同步 drain 锚点 + flush .md 队列
        // 不变量 I（写即持久）：anchor 先同步落地，.md 由 actor flush 保证不丢
        Task { @MainActor in
            CardService.shared.cancelPendingSave()
            _ = await data.commitDraft()
            await MarkdownWriteQueue.shared.flush()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - 启动期 bootstrap

    private func bootstrap() {
        alertState.isInMemoryDB = AppDatabase.shared.isInMemory
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // v1.6.0（批次5/群5）：
                // 1. 关键对账（恢复 .md 有但 DB 无的卡，影响首屏完整性）— 同步等
                let reconcileResult = try await CardService.shared.bootstrapCritical()
                if reconcileResult.failedCount > 0 {
                    self.alertState.saveError = "从 .md 恢复了 \(reconcileResult.restoredCount) 张，但 \(reconcileResult.failedCount) 张失败（首张：\(reconcileResult.failedIDs.first ?? "?")，原因：\(reconcileResult.firstErrorDescription ?? "未知")）。如果这是 v1.6.1 之前的旧 .md，请升级后重试。"
                }
                // 2. 首屏数据加载 — 完成即清 loading 态，列表/侧栏立即可用
                let stats = try await CardService.shared.refreshStats()
                self.statsState.update(with: stats)
                self.statsState.isBootstrapping = false
                self.data.draft = .empty()
                // 3. 延迟对账（纯 .md 修复 + 全量 mdVersion 扫描 + purge）—
                //    移出首屏关键路径，后台低优先级跑，不阻塞用户
                Task.detached(priority: .utility) {
                    do {
                        try await CardService.shared.bootstrapDeferred(
                            retentionDays: await SettingsService.trashRetentionDays
                        )
                    } catch {
                        await MainActor.run {
                            self.alertState.saveError = "后台对账失败：\(error.localizedDescription)"
                        }
                    }
                }
            } catch {
                self.alertState.saveError = "启动失败：\(error.localizedDescription)"
                self.statsState.isBootstrapping = false
                self.data.draft = .empty()
            }
        }
    }

    // MARK: - 窗口 chrome 配置

    private func configureWindows() {
        NSApp.windows.forEach(configure)
    }

    private func configure(window: NSWindow) {
        window.title = ""
        window.titlebarSeparatorStyle = .none
        // v1.3.1 P0 关键修复：消除 toolbar 下方那条 1px 分隔线
        window.toolbar?.showsBaselineSeparator = false
        // v1.7.0：让 titlebar 透明 + content view 延伸至 titlebar 区域，
        // 让 sidebar Liquid Glass 玻璃背景透到 traffic-lights 区域
        // （与 Apple Podcast / Freeform 视觉一致：traffic-lights 落在 sidebar 同色/玻璃背景里）
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
    }
}
