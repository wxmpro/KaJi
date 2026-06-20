//
//  MainView.swift
//  KaJi
//
//  主视图：macOS 26 原生两栏布局入口。
//  使用 .windowToolbarStyle(.unifiedCompact) + .searchable(placement: .toolbar)
//  实现 traffic-lights 视觉上落在侧栏顶部 + 原生 toolbar 搜索。
//
//  那 1px 分隔线由 NSToolbar.showsBaselineSeparator 控制。
//

import SwiftUI

struct MainView: View {
    @Environment(ListState.self) private var listState
    @Environment(EditorDataState.self) private var data
    @Environment(EditorUIState.self) private var ui
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var ui = ui  // 子 view 持 @Bindable（根 view 不持 @Bindable）
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
            ToolbarItem(placement: .destructiveAction) {
                DeleteCardButton()
            }
            ToolbarItem(placement: .cancellationAction) {
                BackButton()
            }
        }
        // macOS 26 Liquid Glass：让 toolbar 背景可见 + 颜色跟随系统，
        // 使 sidebar 视觉上延伸到 titlebar（与 Podcast/Freeform 一致）
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(nil, for: .windowToolbar)
        .onSubmit(of: .search) {
            let keyword = ui.searchKeyword.trimmingCharacters(in: .whitespaces)
            if keyword.isEmpty {
                listState.showList(.all)
            } else {
                listState.showList(.search(keyword))
            }
        }
        .onAppear {
            data.undoManager = undoManager
        }
        .onDisappear {
            data.undoManager = nil
        }
    }
}
