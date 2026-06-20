//
//  SidebarView.swift
//  KaJi
//
//  左侧边栏：导航入口（新建、卡片类型、标签、回收站）。
//
//  v1.7.2 性能优化：把 4 个 section 拆为独立 View struct，
//  每个 section 独立 @Environment 订阅自己需要的 state，
//  避免 sidebar 整体重建（25 个 row 反复创建）。
//
//  - NewCardSection：只订阅 EditorDataState
//  - CardsAndTypesSection：只订阅 ListState（rightPaneMode + listFilter）
//  - TagsAndItemsSection：订阅 ListState + StatsState（tagCounts）
//  - TrashSection：订阅 ListState + StatsState（trashCount）
//
//  效果：点"新建卡片"只有 NewCardSection 重建；点卡片类型只有
//  CardsAndTypesSection 重建；stats 加载只触发 Tags/Trash 重建。
//

import SwiftUI

// MARK: - 顶层 SidebarView

struct SidebarView: View {
    var body: some View {
        List {
            NewCardSection()
            CardsAndTypesSection()
            TagsAndItemsSection()
            TrashSection()
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
}

// MARK: - Section 1: 新建卡片（只订阅 EditorDataState）

private struct NewCardSection: View {
    @Environment(EditorDataState.self) private var data

    var body: some View {
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
}

// MARK: - Section 2: 卡片 + 12 种类型（只订阅 ListState）

private struct CardsAndTypesSection: View {
    @Environment(ListState.self) private var listState

    var body: some View {
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
}

// MARK: - Section 3: 标签 section header + top 10 tags（订阅 ListState + StatsState）

private struct TagsAndItemsSection: View {
    @Environment(ListState.self) private var listState
    @Environment(StatsState.self) private var statsState

    var body: some View {
        // StatsState.tagCounts() 已按字典聚合（天然去重），并按使用次数倒序。
        // 侧栏只展示最常用的前 10 个，避免列表过长。
        let tagCounts = Array(statsState.tagCounts().prefix(10))

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
}

// MARK: - Section 4: 回收站（订阅 ListState + StatsState）

private struct TrashSection: View {
    @Environment(ListState.self) private var listState
    @Environment(StatsState.self) private var statsState

    var body: some View {
        let selected = listState.rightPaneMode == .list
            && listState.listFilter == .trash
        let trashCount = statsState.cachedSummaries.filter { $0.deletedAt != nil }.count
        let trashIcon = trashCount > 0 ? "arrow.up.trash.fill" : "arrow.up.trash"

        Section {
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