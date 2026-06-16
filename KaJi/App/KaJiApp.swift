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

import SwiftUI
import AppKit

@main
struct KaJiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainView()
                // v1.3.3 PATCH：editorState 注入移除（7 View 已不订阅它）
                // v1.2.9 T2：注入细粒度子 state，View 可独立订阅对应 @Published。
                .environmentObject(appDelegate.editorState.data)
                .environmentObject(appDelegate.editorState.ui)
                .environmentObject(appDelegate.editorState.alert)
                .environmentObject(appDelegate.listState)
                .environmentObject(appDelegate.statsState)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        .defaultPosition(.center)
        .commands {
            // MARK: File Menu
            // 用 `replacing: .newItem` 替换 WindowGroup 默认的"新建窗口"项，
            // 让 ⌘N 唯一作用是"新建卡片"（不开新窗口）。
            // 之前用 `after: .newItem` 时，WindowGroup 的默认 New 仍然存在，
            // 旧版 `startNewCard` 同步阻塞主线程，Button handler 跑完前 SwiftUI
            // 不会触发默认 New；改成 async 后 handler 立刻返回，SwiftUI fallback
            // 到默认 New，结果每次 ⌘N 都开新窗口。
            // v1.3.0：直连 data.startNewCard（删 facade 后）
            // v1.3.3 PATCH：editorState 间接层移除，依赖链 4 → 3 层
            CommandGroup(replacing: .newItem) {
                Button("新建卡片") {
                    appDelegate.data.startNewCard(type: .free)
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
            // v1.3.3 PATCH：undoManager 桥已迁移到 data，菜单走 appDelegate.data.undoManager
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
                    guard let card = appDelegate.data.currentCard else { return }
                    appDelegate.data.softDeleteCard(card)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }

            // MARK: View Menu
            // v1.3.0：直连 ui.toggleSidebar（删 facade 后）
            // v1.3.3 PATCH：editorState 间接层移除，依赖链 4 → 3 层
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
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var statsState = StatsState()
    private(set) lazy var listState = ListState(statsState: statsState)
    private(set) lazy var editorState = EditorState(statsState: statsState, listState: listState)

    // v1.3.3 PATCH：editorState 间接层移除，3 层访问器暴露给 KaJiApp 菜单
    var data: EditorDataState { editorState.data }
    var ui: EditorUIState { editorState.ui }

    override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        SettingsService.restoreThemeOnLaunch()
        configureWindows()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // v1.3.0：直连 data.flushSave（删 facade 后）
        // v1.3.3 PATCH：依赖链 4 → 3 层
        data.flushSave()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - 窗口 chrome 配置
    // v1.3.1：加 window.toolbar?.showsBaselineSeparator = false 消除那条 1px 分隔线
    // 这是 NSToolbar 自带的 baseline line，与 unified toolbar 无关
    // 之前错误归因到 .windowToolbarStyle(.unifiedCompact)，实际是 NSWindow API 控制

    private func configureWindows() {
        NSApp.windows.forEach(configure)
    }

    private func configure(window: NSWindow) {
        window.title = ""
        window.titlebarSeparatorStyle = .none
        // v1.3.1 P0 关键修复：消除 toolbar 下方那条 1px 分隔线
        // 用户反馈的"侧栏和右栏内容区分开的那条线"就是 NSToolbar 的 baseline separator
        window.toolbar?.showsBaselineSeparator = false
    }
}
