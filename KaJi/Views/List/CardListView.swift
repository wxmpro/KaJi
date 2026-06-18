//
//  CardListView.swift
//  KaJi
//
//  卡片列表视图（侧栏点击类型/标签/回收站时占用右栏）。
//  v1.3.1 弃用 SwiftUI List(selection:)，改用 ScrollView + LazyVStack。
//  v1.4.0：@EnvironmentObject → @Environment
//

import SwiftUI

struct CardListView: View {
    @Environment(ListState.self) private var listState
    @Environment(EditorDataState.self) private var data
    @Environment(StatsState.self) private var statsState

    var body: some View {
        let cards = listState.cachedFilteredCards
        VStack(spacing: 0) {
            ListFilterTitle()
                .padding(.leading, KaJiLayout.contentHorizontalPadding)
                .padding(.trailing, KaJiLayout.listTitleTrailingPadding)
                .padding(.bottom, KaJiLayout.listTitleBottomPadding)
                .offset(y: KaJiLayout.listTitleTopOffset)
                .padding(.top, KaJiLayout.headerTopPadding)

            if statsState.isBootstrapping {
                // v1.6.0（批次5/群5）：启动加载态，避免空白窗口被误认为卡死
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在加载卡片库...")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cards.isEmpty {
                let isTrash = listState.listFilter == .trash
                ContentUnavailableView {
                    Label(isTrash ? "回收站为空" : "暂无卡片",
                          systemImage: isTrash ? "trash" : "rectangle.stack")
                } description: {
                    Text(isTrash
                         ? "没有已删除的卡片"
                         : "在「\(listState.listFilterTitle)」下没有卡片")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
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
