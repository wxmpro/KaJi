//
//  SidebarView.swift
//  KaJi
//
//  左侧边栏：导航入口（新建、卡片类型、标签、回收站）。
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var editorState: EditorState
    @EnvironmentObject var listState: ListState
    @EnvironmentObject var statsState: StatsState

    var body: some View {
        // 预计算标签统计：避免在 List 行闭包里反复读库
        let tagCounts = tagCountsSnapshot

        List {
            newCardSection
            cardsAndTypesSection
            tagsAndItemsSection(tagCounts: tagCounts)
            trashSection
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 22)
        .listRowInsets(EdgeInsets())
    }

    // MARK: Snapshots

    private var tagCountsSnapshot: [(String, Int)] {
        // StatsState.tagCounts() 已按字典聚合（天然去重），并按使用次数倒序。
        // 侧栏只展示最常用的前 10 个，避免列表过长。
        Array(statsState.tagCounts().prefix(10))
    }

    // MARK: Sections

    private var newCardSection: some View {
        Section {
            SidebarRow(
                title: "新建卡片",
                icon: "plus.square",
                iconColor: .primary,
                count: nil,
                isSelected: false,
                style: .large
            ) {
                editorState.startNewCard(type: .free)
            }
        }
        .listRowSeparator(.hidden)
    }

    private var cardsAndTypesSection: some View {
        Section {
            SidebarRow(
                title: "卡片",
                icon: "rectangle.stack",
                iconColor: .primary,
                count: nil,
                isSelected: listState.rightPaneMode == .list && listState.listFilter == .all,
                style: .large
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    listState.showList(.all)
                }
            }
            .padding(.top, -6)

            ForEach(CardType.allCases) { type in
                let selected = listState.rightPaneMode == .list
                    && listState.listFilter == .type(type)

                SidebarRow(
                    title: type.rawValue,
                    icon: "circle.fill",
                    iconColor: type.color,
                    count: nil,
                    isSelected: selected,
                    style: .small
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        listState.showList(.type(type))
                    }
                }
            }
        }
    }

    private func tagsAndItemsSection(tagCounts: [(String, Int)]) -> some View {
        Section {
            if tagCounts.isEmpty {
                Text("暂无标签")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tagCounts, id: \.0) { tag, _ in
                    let selected = listState.rightPaneMode == .list
                        && listState.listFilter == .tag(tag)

                    SidebarRow(
                        title: tag,
                        icon: "tag",
                        iconColor: .secondary,
                        count: nil,
                        isSelected: selected,
                        style: .small
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            listState.showList(.tag(tag))
                        }
                    }
                }
            }
        } header: {
            Text("标签")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.leading, 6)
                .padding(.top, 20)
        }
    }

    private var trashSection: some View {
        Section {
            let selected = listState.rightPaneMode == .list
                && listState.listFilter == .trash

            SidebarRow(
                title: "回收站",
                icon: "trash",
                iconColor: .primary,
                count: nil,
                isSelected: selected,
                style: .large
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    listState.showList(.trash)
                }
            }
        }
    }
}
