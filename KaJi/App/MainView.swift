//
//  MainView.swift
//  KaJi — 卡迹 · Mac 原生卡片笔记
//
//  主视图：macOS 15 原生两栏布局。
//  - 左侧边栏：导航入口（新建、卡片类型、标签、回收站）
//  - 右侧详情：卡片展示区 + 右上角搜索（类 Finder 工具栏搜索）
//

import SwiftUI

struct MainView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: $appState.sidebarColumnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 400)
        } detail: {
            DetailView()
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - 右侧详情区

private struct DetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
                .ignoresSafeArea()

            // 内容区：点击空白处关闭搜索栏
            Group {
                if appState.searchKeyword.isEmpty {
                    CardPlaceholderView()
                } else {
                    SearchResultsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                if appState.isSearchActive {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        appState.isSearchActive = false
                    }
                }
            }

            // 右上角可展开搜索：直接 overlay 定位，不依赖 toolbar placement
            ExpandableSearchControl()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 10)
                .padding(.trailing, 16)
                .ignoresSafeArea(.container, edges: .top)
        }
    }
}

// MARK: 右上角可展开搜索

private struct ExpandableSearchControl: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var searchFocused: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if appState.isSearchActive {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextField("搜索卡片...", text: $appState.searchKeyword)
                        .textFieldStyle(.plain)
                        .frame(width: 280)
                        .focused($searchFocused)

                    if !appState.searchKeyword.isEmpty {
                        Button {
                            appState.searchKeyword = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
                .transition(.move(edge: .trailing).combined(with: .opacity))

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        appState.isSearchActive = false
                    }
                    appState.searchKeyword = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(Color(nsColor: .controlColor).opacity(0.12))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        appState.isSearchActive = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        searchFocused = true
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(isHovering ? Color(white: 0.88) : .white)
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("搜索卡片")
                .transition(.scale.combined(with: .opacity))
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHovering = hovering
                    }
                }
            }
        }
        .onChange(of: searchFocused) { _, focused in
            // 点击搜索框外部导致失焦时，自动关闭搜索栏
            if !focused && appState.isSearchActive {
                withAnimation(.easeInOut(duration: 0.15)) {
                    appState.isSearchActive = false
                }
            }
        }
    }
}

// MARK: - 左侧边栏

private struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        // 预计算统计：避免在 List 行闭包里反复读库
        let typeCounts = typeCountsSnapshot
        let tagCounts = tagCountsSnapshot

        List {
            newCardSection
            cardTypesSection(typeCounts: typeCounts)
            tagsSection(tagCounts: tagCounts)
            trashSection
        }
        .listStyle(.sidebar)
    }

    // MARK: Snapshots

    private var typeCountsSnapshot: [CardType: Int] {
        Dictionary(
            uniqueKeysWithValues: CardType.allCases.map { type in
                (type, appState.cardsCount(of: type))
            }
        )
    }

    private var tagCountsSnapshot: [(String, Int)] {
        // AppState.tagCounts() 已按字典聚合（天然去重），并按使用次数倒序。
        // 侧栏只展示最常用的前 10 个，避免列表过长。
        Array(appState.tagCounts().prefix(10))
    }

    // MARK: Sections

    private var newCardSection: some View {
        Section {
            Button {
                appState.startNewCard(type: .free)
            } label: {
                Label("新建卡片", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .listRowSeparator(.hidden)
    }

    private func cardTypesSection(typeCounts: [CardType: Int]) -> some View {
        Section("卡片类型") {
            ForEach(CardType.allCases) { type in
                let selected = appState.filterType == type

                SidebarRow(
                    title: type.rawValue,
                    icon: "circle.fill",
                    iconColor: type.color,
                    count: typeCounts[type, default: 0],
                    isSelected: selected
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        appState.filterType = selected ? nil : type
                    }
                }
            }
        }
    }

    private func tagsSection(tagCounts: [(String, Int)]) -> some View {
        Section("标签") {
            if tagCounts.isEmpty {
                Text("暂无标签")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tagCounts, id: \.0) { tag, count in
                    let selected = appState.filterTags.contains(tag)

                    SidebarRow(
                        title: tag,
                        icon: "tag.fill",
                        iconColor: .secondary,
                        count: count,
                        isSelected: selected
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            if selected {
                                appState.filterTags.removeAll { $0 == tag }
                            } else {
                                appState.filterTags.append(tag)
                            }
                        }
                    }
                }
            }
        }
    }

    private var trashSection: some View {
        Section {
            SidebarRow(
                title: "回收站",
                icon: "trash",
                iconColor: .secondary,
                count: 0,
                isSelected: appState.showingTrash
            )
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.12)) {
                    appState.showingTrash.toggle()
                }
            }
        }
    }
}

// MARK: - 侧边栏行

private struct SidebarRow: View {
    let title: String
    let icon: String
    let iconColor: Color
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 18, alignment: .center)

            Text(title)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
    }
}

// MARK: 卡片占位（等待卡片样式确定后替换）

private struct CardPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "doc.text")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)

            Text("卡片展示区域")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("后续在这里渲染卡片内容")
                .font(.callout)
                .foregroundStyle(.tertiary)

            Spacer()
        }
    }
}

// MARK: 搜索结果（临时列表，后续按卡片样式渲染）

private struct SearchResultsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let results = appState.search(appState.searchKeyword)

        VStack(spacing: 0) {
            HStack {
                Text("\(results.count) 张卡片")
                    .font(.headline)
                Spacer()
            }
            .padding()

            if results.isEmpty {
                ContentUnavailableView {
                    Label("未找到卡片", systemImage: "magnifyingglass")
                } description: {
                    Text("尝试更换关键词")
                }
            } else {
                List(results) { card in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.title.isEmpty ? "无标题" : card.title)
                            .font(.body.weight(.medium))
                        Text(card.cardType.rawValue)
                            .font(.caption)
                            .foregroundStyle(card.cardType.color)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Preview

#Preview("Two Column") {
    MainView()
        .environmentObject(AppState())
        .frame(width: 1400, height: 900)
}
