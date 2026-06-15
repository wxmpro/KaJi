//
//  MainView.swift
//  KaJi
//
//  主视图：macOS 26 原生两栏布局入口。
//  使用 .windowToolbarStyle(.unifiedCompact) + .searchable(placement: .toolbar)
//  实现 traffic-lights 视觉上落在侧栏顶部 + 原生 toolbar 搜索。
//

import SwiftUI

struct MainView: View {
    @EnvironmentObject var editorState: EditorState
    @EnvironmentObject var listState: ListState
    @Environment(\.undoManager) var undoManager

    var body: some View {
        NavigationSplitView(columnVisibility: $editorState.sidebarColumnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 400)
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(
            text: $editorState.searchKeyword,
            placement: .toolbar,
            prompt: "搜索卡片..."
        )
        .onSubmit(of: .search) {
            let keyword = editorState.searchKeyword.trimmingCharacters(in: .whitespaces)
            guard !keyword.isEmpty else { return }
            listState.showList(.search(keyword))
        }
        .onAppear {
            editorState.undoManager = undoManager
            configureWindowChrome()
        }
        .onDisappear {
            editorState.undoManager = nil
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
