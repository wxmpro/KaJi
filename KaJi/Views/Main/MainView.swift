//
//  MainView.swift
//  KaJi
//
//  主视图：macOS 26 原生两栏布局入口。
//  使用 .windowToolbarStyle(.unifiedCompact) + .searchable(placement: .toolbar)
//  实现 traffic-lights 视觉上落在侧栏顶部 + 原生 toolbar 搜索。
//
//  v1.3.1：那 1px 分隔线由 NSToolbar.showsBaselineSeparator 控制。
//  v1.4.0：@EnvironmentObject → @Environment（@Observable 细粒度订阅）
//

import SwiftUI

struct MainView: View {
    // v1.4.0：@Environment(Type.self) 注入（@Observable 自动追踪）
    @Environment(ListState.self) private var listState
    @Environment(EditorDataState.self) private var data
    @Environment(EditorUIState.self) private var ui
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var ui = ui  // 子 view 持 @Bindable（按 v1.3.1 教训：根 view 不持 @Bindable）
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
            configureWindowChrome()
        }
        .onDisappear {
            data.undoManager = nil
        }
    }

    private func configureWindowChrome() {
        NSApp.windows.forEach { window in
            window.title = ""
            window.titlebarSeparatorStyle = .none
        }
    }
}
