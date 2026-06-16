//
//  MainView.swift
//  KaJi
//
//  主视图：macOS 26 原生两栏布局入口。
//  使用 .windowToolbarStyle(.unifiedCompact) + .searchable(placement: .toolbar)
//  实现 traffic-lights 视觉上落在侧栏顶部 + 原生 toolbar 搜索。
//
//  v1.3.1：那 1px 分隔线由 NSToolbar.showsBaselineSeparator 控制，
//  在 AppDelegate.configure 中设为 false 即可消除。
//

import SwiftUI

struct MainView: View {
    // v1.3.3 PATCH：editorState 注入移除。undoManager 桥改由 data 承载（data 已是 EnvironmentObject）。
    // UI 态（sidebarColumnVisibility / searchKeyword）订阅 ui；数据态业务方法走 data。
    @EnvironmentObject var listState: ListState
    @EnvironmentObject var data: EditorDataState
    @EnvironmentObject var ui: EditorUIState
    @Environment(\.undoManager) var undoManager

    var body: some View {
        NavigationSplitView(columnVisibility: $ui.sidebarColumnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 400)
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(
            text: $ui.searchKeyword,
            placement: .toolbar,
            prompt: "搜索卡片..."
        )
        .toolbar {
            // v1.2.6+ UI 重构：返回键从主内容顶部 NavigationHeader 移到 toolbar 右侧
            // .cancellationAction placement 会把按钮放在 searchable 右侧
            // (toolbar 最右),跟 macOS 原生习惯一致
            ToolbarItem(placement: .cancellationAction) {
                BackButton()
            }
        }
        .onSubmit(of: .search) {
            let keyword = ui.searchKeyword.trimmingCharacters(in: .whitespaces)
            if keyword.isEmpty {
                // v1.2.9 T8 修复：清空搜索框按回车，回到"全部卡片"列表
                listState.showList(.all)
            } else {
                listState.showList(.search(keyword))
            }
        }
        .onAppear {
            // v1.3.3 PATCH：undoManager 桥挂在 data 上，KaJiApp 顶层菜单通过 appDelegate.data 访问
            data.undoManager = undoManager
            configureWindowChrome()
        }
        .onDisappear {
            data.undoManager = nil
        }
    }

    /// 配置窗口 chrome：移除 titlebar 底部横线、清空标题，实现更干净的原生外观。
    private func configureWindowChrome() {
        NSApp.windows.forEach { window in
            window.title = ""
            window.titlebarSeparatorStyle = .none
        }
    }
}
