//
//  SidebarView.swift
//  KaJi
//
//  左侧边栏：导航入口（新建、卡片类型、标签、回收站）。
//

import SwiftUI

struct SidebarView: View {
    // v1.4.0：@EnvironmentObject → @Environment（@Observable 细粒度订阅）
    @Environment(EditorDataState.self) private var data
    @Environment(ListState.self) private var listState
    @Environment(StatsState.self) private var statsState
    @Environment(\.colorScheme) private var colorScheme

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
        // List 自身背景透出，让 Liquid Glass 玻璃透到 List 行
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        // macOS 26 Liquid Glass 背景层：
        // 用 .background { ... } 让 Liquid Glass 占据整个 List frame，
        // .ignoresSafeArea() 让玻璃延伸到 titlebar 顶部（含 traffic-lights 区域），
        // 使 traffic-lights 视觉上落在 sidebar Liquid Glass 玻璃背景里（与 Podcast/Freeform 一致）
        .background {
            Rectangle()
                .fill(Color.clear)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 0))
                .ignoresSafeArea()
        }
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
                icon: "plus.square.fill",
                iconColor: .primary,
                count: nil,
                isSelected: false,
                style: .large
            ) {
                // v1.4.0：data.startNewDraft
                data.startNewDraft(type: .free)
            }
        }
        .listRowSeparator(.hidden)
    }

    private var cardsAndTypesSection: some View {
        Section {
            SidebarRow(
                title: "卡片",
                icon: "rectangle.stack.fill",
                iconColor: .primary,
                count: nil,
                isSelected: listState.rightPaneMode == .list && listState.listFilter == .all,
                style: .large
            ) {
                withAnimation(KaJiAnimation.modeSwitch) {
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
                    withAnimation(KaJiAnimation.modeSwitch) {
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
                        icon: "tag.fill",
                        iconColor: .secondary,
                        count: nil,
                        isSelected: selected,
                        style: .small
                    ) {
                        withAnimation(KaJiAnimation.modeSwitch) {
                            listState.showList(.tag(tag))
                        }
                    }
                }
            }
        } header: {
            HStack(spacing: 10) {
                Image(systemName: "tag.square.fill")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 22, alignment: .center)
                Text("标签")
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)
        }
    }

    private var trashSection: some View {
        Section {
            let selected = listState.rightPaneMode == .list
                && listState.listFilter == .trash
            let trashCount = statsState.cachedSummaries.filter { $0.deletedAt != nil }.count
            let trashIcon = trashCount > 0 ? "arrow.up.trash.fill" : "arrow.up.trash"

            SidebarRow(
                title: "回收站",
                icon: trashIcon,
                iconColor: .primary,
                count: nil,
                isSelected: selected,
                style: .large
            ) {
                withAnimation(KaJiAnimation.modeSwitch) {
                    listState.showList(.trash)
                }
            }
        }
    }
}
