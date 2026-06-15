//
//  KaJiApp.swift
//  KaJi — 卡迹 · Mac 原生卡片笔记
//
//  macOS 原生窗口设计：
//  - .titled + .closable + .miniaturizable + .resizable = 系统画整窗 4 圆角 + traffic-lights + titlebar
//  - titlebar 透明，侧栏顶到 (0, 0)，traffic-lights 自然落在侧栏圆角矩形内
//  - 通过 NSHostingController 注入 EditorState / ListState / StatsState，
//    供全 UI 层 @EnvironmentObject 使用。
//

import SwiftUI
import AppKit

@main
struct KaJiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            // MARK: File Menu
            CommandMenu("文件") {
                Button("新建卡片") {
                    appDelegate.editorState.startNewCard(type: .free)
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("导出当前卡片") {
                    guard let card = appDelegate.editorState.currentCard else { return }
                    ExportService.exportCard(card)
                }
                .keyboardShortcut("e", modifiers: .command)

                Button("导出全部卡片") {
                    ExportService.exportAll()
                }
                .keyboardShortcut("E", modifiers: [.command, .shift])

                Divider()

                Button("关闭窗口") {
                    appDelegate.closeMainWindow()
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            // MARK: Edit Menu
            CommandMenu("编辑") {
                Button("撤销") {
                    appDelegate.editorState.undoManager?.undo()
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("重做") {
                    appDelegate.editorState.undoManager?.redo()
                }
                .keyboardShortcut("Z", modifiers: [.command, .shift])

                Divider()

                Button("剪切") {
                    NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("x", modifiers: .command)

                Button("拷贝") {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("粘贴") {
                    NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: .command)

                Button("全选") {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("a", modifiers: .command)

                Divider()

                Button("删除") {
                    guard let card = appDelegate.editorState.currentCard else { return }
                    appDelegate.editorState.softDeleteCard(card)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }

            // MARK: View Menu
            CommandMenu("显示") {
                Button("切换侧栏") {
                    appDelegate.editorState.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])

                Button("进入全屏幕") {
                    appDelegate.toggleFullScreen()
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
            }

            // MARK: Help Menu
            CommandMenu("帮助") {
                Button("KaJi 帮助") {
                    guard let url = URL(string: "https://github.com/xinmin/kaji") else { return }
                    NSWorkspace.shared.open(url)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}

/// AppDelegate
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?

    private(set) lazy var statsState = StatsState()
    private(set) lazy var listState = ListState(statsState: statsState)
    private(set) lazy var editorState = EditorState(statsState: statsState, listState: listState)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let window = createMainWindow()
        mainWindow = window
        window.makeKeyAndOrderFront(nil)

        SettingsService.restoreThemeOnLaunch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        editorState.flushSave()
        return .terminateNow
    }

    // MARK: - Window Actions (called from SwiftUI .commands)

    func closeMainWindow() {
        editorState.flushSave()
        mainWindow?.close()
    }

    func toggleFullScreen() {
        mainWindow?.toggleFullScreen(nil)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        editorState.flushSave()
    }

    // MARK: - Window Creation

    private func createMainWindow() -> NSWindow {
        guard let screen = NSScreen.main else {
            fatalError("No main screen")
        }

        // macOS 原生应用惯例：
        // 1. 默认尺寸按屏幕可视区域比例计算（而非写死小尺寸）
        // 2. 最小尺寸保证两栏布局可用
        // 3. 通过 autosave 记住用户上次调整的大小
        let screenFrame = screen.visibleFrame
        let defaultSize = defaultWindowSize(for: screenFrame)
        let frame = NSRect(
            x: screenFrame.midX - defaultSize.width / 2,
            y: screenFrame.midY - defaultSize.height / 2,
            width: defaultSize.width,
            height: defaultSize.height
        )

        // macOS 标准窗口（.titled 让系统画圆角 + traffic-lights + titlebar）
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor

        // titlebar 透明 + 文字隐藏（保留 system traffic-lights）
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // 窗口 appearance 跟随用户主题设置
        window.appearance = NSApp.appearance

        // 尺寸约束：最小宽度要保证侧栏 + 详情区都能正常显示
        window.minSize = NSSize(width: 900, height: 600)

        // 记住用户上次调整的窗口大小 / 位置；首次启动用上面算出的默认 frame
        window.setFrameAutosaveName("KaJiMainWindow")

        // content = SwiftUI MainView（NSHostingController）— 注入各状态对象
        // 使用 contentViewController 而非把 NSHostingView 当子视图添加，
        // SwiftUI 才能正确把 NavigationSplitView 的侧边栏延伸到 titlebar 区域，
        // 让 traffic-lights 浮在侧栏内部（macOS 15 原生效果）。
        // 右上角搜索控件由 SwiftUI MainView 内部实现（避免 NSToolbar 撑开 titlebar）
        let mainView = MainView()
            .environmentObject(editorState)
            .environmentObject(listState)
            .environmentObject(statsState)
        let hostingController = NSHostingController(rootView: mainView)
        window.contentViewController = hostingController

        // 关键：titlebar 区域加一个 accessory view，背景填 windowBackgroundColor。
        // 防止 titlebarAppearsTransparent + fullSizeContentView 组合下全屏时露出黑色条。
        // NSTitlebarAccessoryViewController 是 Apple 官方推荐方案，全屏/非全屏都覆盖。
        let titlebarAccessory = NSTitlebarAccessoryViewController()
        let titlebarBackground = NSView()
        titlebarBackground.wantsLayer = true
        titlebarBackground.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        titlebarAccessory.view = titlebarBackground
        titlebarAccessory.layoutAttribute = .left
        // 主题切换时同步 accessory 背景色
        for name in [NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak titlebarBackground] _ in
                Task { @MainActor in
                    titlebarBackground?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
            }
        }
        window.addTitlebarAccessoryViewController(titlebarAccessory)

        // 窗口关闭前 flush 保存
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )

        // 双保险：hostingController.view 背景色
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        return window
    }

    /// 计算默认窗口尺寸：
    /// - 宽度取屏幕可视区域的 78%，但限制在 1440–1680pt 之间
    /// - 高度取屏幕可视区域的 80%，但限制在 900–1100pt 之间
    /// 与 Finder / Mail / 设置等原生应用首次打开的尺寸策略一致。
    private func defaultWindowSize(for screenFrame: NSRect) -> NSSize {
        let width = (screenFrame.width * 0.78)
            .clamped(to: 1440...1680)
        let height = (screenFrame.height * 0.80)
            .clamped(to: 900...1100)
        return NSSize(width: width, height: height)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - 数值裁剪辅助

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
