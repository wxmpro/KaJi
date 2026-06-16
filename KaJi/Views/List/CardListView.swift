//
//  CardListView.swift
//  KaJi
//
//  卡片列表视图（侧栏点击类型/标签/回收站时占用右栏）。
//
//  v1.3.1 改造：弃用 SwiftUI List(selection:) 的蓝色选中高亮（accentColor），
//  改用 ScrollView + LazyVStack + 每行 Button，selected 由 data.selectedCardID
//  单一数据源控制，渲染走 KaJiListRowButtonStyle，深浅模式视觉与侧栏完全统一。
//

import SwiftUI

struct CardListView: View {
    @EnvironmentObject var listState: ListState
    @EnvironmentObject var editorState: EditorState
    // v1.2.9 T2：selection 走 data（数据态）。
    // v1.2.9 T3：改用独立 selectedCardID（String?），不再订阅 currentCard
    // 避免输入字符触发 List 重建导致高亮漂移。
    @EnvironmentObject var data: EditorDataState

    var body: some View {
        let cards = listState.cachedFilteredCards
        VStack(spacing: 0) {
            // v1.2.6+ UI 重构：删除 NavigationHeader 顶部导航条
            // 返回键已移到 toolbar 区域（MainView 的 .cancellationAction）

            // 列表标题（放在列表区域上方，更清晰）
            ListFilterTitle()
                .padding(.leading, KaJiLayout.contentHorizontalPadding)
                .padding(.trailing, KaJiLayout.listTitleTrailingPadding)
                .padding(.bottom, KaJiLayout.listTitleBottomPadding)
                .offset(y: KaJiLayout.listTitleTopOffset)
                .padding(.top, KaJiLayout.headerTopPadding)  // 保留顶部 padding 平衡视觉

            if cards.isEmpty {
                ContentUnavailableView {
                    Label("暂无卡片", systemImage: "rectangle.stack")
                } description: {
                    Text("在「\(listState.listFilterTitle)」下没有卡片")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // v1.3.1：弃用 List(selection:)。改用 ScrollView + LazyVStack，
                // 每行 Button 用 KaJiListRowButtonStyle 自定义选中色（深灰），
                // 与侧栏 SidebarRowButtonStyle 视觉同源。
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(cards) { card in
                            CardListRow(card: card)
                        }
                    }
                    .padding(.horizontal, KaJiLayout.contentHorizontalPadding)
                    .padding(.vertical, 4)
                }
            }
        }
    }
}