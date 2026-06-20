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
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 0) {
                    BackButton()
                    Spacer()
                    SearchToolbarField(
                        text: $ui.searchKeyword,
                        placeholder: "搜索卡片...",
                        onSubmit: {
                            let keyword = ui.searchKeyword.trimmingCharacters(in: .whitespaces)
                            if keyword.isEmpty {
                                listState.showList(.all)
                            } else {
                                listState.showList(.search(keyword))
                            }
                        }
                    )
                    .frame(width: 240)
                    Spacer()
                    DeleteCardButton()
                }
                .frame(maxWidth: .infinity)
            }
        }
        // macOS 26 Liquid Glass：toolbar 背景隐藏，只保留按钮 hover 效果
        // .toolbarBackground(.hidden, for: .windowToolbar)
        // .toolbarColorScheme(nil, for: .windowToolbar)
        .onAppear {
            data.undoManager = undoManager
        }
        .onDisappear {
            data.undoManager = nil
        }
    }
}
