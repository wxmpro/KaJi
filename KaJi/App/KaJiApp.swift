//
//  KaJiApp.swift
//  KaJi — 卡迹 · Mac 原生卡片笔记
//
//  macOS 26 原生窗口设计：
//  - WindowGroup + .windowToolbarStyle(.unifiedCompact) 实现统一工具栏
//  - NavigationSplitView 侧栏自动延伸到 titlebar，traffic-lights 视觉上落在侧栏顶部
//  - .searchable(placement: .toolbar) 提供原生 NSSearchToolbarItem 搜索
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
                .environment(UpdaterService.shared)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        .defaultPosition(.center)
        .commands {
            // MARK: File Menu
            CommandGroup(replacing: .newItem) {
                Button("新建卡片") {
                    appDelegate.data.startNewDraft(typeId: "自由卡")
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
                .environment(UpdaterService.shared)
        }
        .defaultSize(width: 640, height: 460)
    }
}

/// AppDelegate：接管启动期职责（reconcile + purge + 首卡初始化 + UpdaterService start）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let statsState: StatsState
    let listState: ListState
    let alertState: EditorAlertState
    let data: EditorDataState
    let ui: EditorUIState
    let updater: UpdaterService

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
        self.updater = UpdaterService.shared
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        SettingsService.restoreThemeOnLaunch()
        configureWindows()
        bootstrap()
        updater.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 退出走 .terminateLater + 同步 drain 锚点 + flush .md 队列
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
                // 1. 关键对账（恢复 .md 有但 DB 无的卡，影响首屏完整性）— 同步等
                let reconcileResult = try await CardService.shared.bootstrapCritical()
                if reconcileResult.failedCount > 0 {
                    self.alertState.saveError = "从 .md 恢复了 \(reconcileResult.restoredCount) 张，但 \(reconcileResult.failedCount) 张失败（首张：\(reconcileResult.failedIDs.first ?? "?")，原因：\(reconcileResult.firstErrorDescription ?? "未知")）。如果 .md 来自旧版本，请升级后重试。"
                }
                // 2. 首屏数据加载 — 启动 StatsState 的观察者
                self.statsState.startObservingStats()
                // initial list observation is started when Sidebar first selects an item, or we can force it here
                self.listState.showList(.all)
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
        // 消除 toolbar 下方那条 1px 分隔线
        window.toolbar?.showsBaselineSeparator = false
        // 让 titlebar 透明 + content view 延伸至 titlebar 区域，
        // 让 sidebar 玻璃背景透到 traffic-lights 区域
        // （与 Apple Podcast / Freeform 视觉一致）
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
    }
}
