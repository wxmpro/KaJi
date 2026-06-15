//
//  CardListView.swift
//  KaJi
//
//  卡片列表视图（侧栏点击类型/标签/回收站时占用右栏）。
//

import SwiftUI

struct CardListView: View {
    @EnvironmentObject var listState: ListState
    @EnvironmentObject var editorState: EditorState

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
                List(selection: Binding(
                    get: { editorState.currentCard?.id },
                    set: { newID in
                        guard let id = newID,
                              let card = cards.first(where: { $0.id == id }) else { return }
                        listState.openCardFromList(card, editorState: editorState)
                    }
                )) {
                    ForEach(cards) { card in
                        CardListRow(card: card)
                            .tag(card.id)
                    }
                }
                .listStyle(.plain)
                .padding(.horizontal, KaJiLayout.contentHorizontalPadding)
            }
        }
    }
}
