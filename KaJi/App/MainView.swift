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

// MARK: - 卡片列表视图（侧栏点击类型/标签/回收站时占用右栏）

private struct CardListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        let cards = appState.filteredCards()
        VStack(spacing: 0) {
            NavigationHeader()
                .padding(.horizontal, 50)
                .padding(.top, 5)
                .padding(.bottom, 4)
                .offset(y: -10)

            // 列表标题（放在列表区域上方，更清晰）
            ListFilterTitle()
                .padding(.leading, 50)
                .padding(.trailing, 62)
                .padding(.bottom, 8)
                .offset(y: -6)

            if cards.isEmpty {
                ContentUnavailableView {
                    Label("暂无卡片", systemImage: "rectangle.stack")
                } description: {
                    Text("在「\(appState.listFilterTitle)」下没有卡片")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { appState.currentCard?.id },
                    set: { newID in
                        guard let id = newID,
                              let card = cards.first(where: { $0.id == id }) else { return }
                        appState.openCardFromList(card)
                    }
                )) {
                    ForEach(cards) { card in
                        CardListRow(card: card)
                            .tag(card.id)
                    }
                }
                .listStyle(.plain)
                .padding(.horizontal, 50)
            }
        }
    }
}

/// 通用顶部导航条：仅保留 back / forward
private struct NavigationHeader: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            navPill
            Spacer()
        }
    }

    private var navPill: some View {
        HStack(spacing: 0) {
            navButton(systemName: "chevron.left", isEnabled: appState.canGoBack) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    appState.goBack()
                }
            }
            .help("返回上一张卡片")

            // 细分隔线（Finder 风格）
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(width: 0.5, height: 16)

            navButton(systemName: "chevron.right", isEnabled: appState.canGoForward) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    appState.goForward()
                }
            }
            .help("前进到下一张卡片")
        }
        .padding(3)
        .background(
            Capsule().fill(pillBackgroundColor)
        )
        .overlay(
            Capsule().stroke(
                Color(nsColor: .separatorColor).opacity(0.45),
                lineWidth: 0.5
            )
        )
    }

    private var pillBackgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: .windowBackgroundColor)
            : Color(white: 0.94)
    }

    /// pill 内部单个圆形按钮
    /// - 启用：hover 时浮现 controlColor 圆
    /// - 禁用：透明
    @ViewBuilder
    private func navButton(
        systemName: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.45))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .kajiHover(cornerRadius: 16, restingBackground: .clear)
    }
}

/// 列表区域上方的筛选标题
/// 布局：标题大字在左、数量小字在右，同一 baseline 对齐
private struct ListFilterTitle: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(appState.listFilterTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.primary)

            Spacer()

            Text("\(appState.filteredCards().count) 张卡片")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

private struct CardListRow: View {
    let card: Card

    var body: some View {
        HStack(spacing: 0) {
            // 左侧垂直彩色条
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(card.cardType.color)
                .frame(width: 4)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                // 标题
                Text(card.title.isEmpty ? "无标题" : card.title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(card.title.isEmpty ? .secondary : .primary)

                // 元信息行：类型 + 标签
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(card.cardType.color)
                            .frame(width: 6, height: 6)
                        Text(card.cardType.rawValue)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if !card.tags.isEmpty {
                        ForEach(card.tags.prefix(5), id: \.self) { tag in
                            TagPill(tag: tag)
                        }
                    }
                }
            }
            .padding(.leading, 12)

            Spacer(minLength: 16)

            // 右侧：14 位显示 ID
            Text(card.displayID)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}

private struct TagPill: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                Capsule()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
            )
    }
}

// MARK: - 右侧详情区

private struct DetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            // 窗口背景色，覆盖 titlebar 区域防止全屏黑条
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea(.all)

            // 主体：根据 rightPaneMode 切换
            switch appState.rightPaneMode {
            case .editor:
                NotesEditor()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .list:
                CardListView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 右上角搜索浮层（editor + list 两种模式都显示）
            SearchOverlay()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 5)
                .padding(.trailing, 46)
                .offset(y: -10)
        }
    }
}

// MARK: - macOS Notes 风格编辑器

private struct NotesEditor: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        // 白卡片：圆角 + 浅阴影，浮在背景上
        VStack(spacing: 0) {
            // 顶部导航条：back / forward
            NavigationHeader()
                .padding(.horizontal, 50)
                .padding(.top, 5)
                .padding(.bottom, 4)
                .offset(y: -10)

            // 单 NSTextView 编辑器：纯用户输入，无字段名，无字段分隔
            SingleEditor(text: Binding(
                get: { appState.currentCard?.title ?? "" },
                set: { newValue in
                    guard var card = appState.currentCard else { return }
                    card.title = newValue
                    appState.currentCard = card
                    appState.saveImmediately()
                }
            ))
            .padding(.horizontal, 50)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer()
        }
    }
}

// MARK: - 单编辑器：一个纯 NSTextView，无任何字段概念

private struct SingleEditor: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            // 下层卡片（向右+上偏移 4pt，露出主卡片的"上+右"灰色边）
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.30))
                .offset(x: 4, y: -4)

            // 上层主卡片
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.gray.opacity(0.35), lineWidth: 0.5)
                )

            // 横线层
            // Canvas 高度跟 NSTextView 文字内容高度一致（通过 sizeThatFits 实现）
            // 第一行底 y=32（textContainerInset.top 8 + 行高 24），最后一条 = size.height - 8
            Canvas { context, size in
                guard size.height > 40 else { return }
                let lineHeight: CGFloat = 24
                let firstY: CGFloat = 32
                let lastY: CGFloat = size.height - 8
                var y = firstY
                while y <= lastY {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(.black), lineWidth: 0.8)
                    y += lineHeight
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(30)  // 编辑区和圆角矩形之间的 30pt 间隙

            // 文字层
            SingleTextView(text: $text, isFocused: $isFocused)
                .padding(30)  // 文字层也在内
        }
    }
}

/// 普通 NSTextView（横线由 SwiftUI Canvas 在背景层画，不在这里画）
typealias LinedTextView = NSTextView

private struct SingleTextView: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        // 必须先创建 textContainer 传给 NSTextView，否则 layoutManager / textStorage 不会自动建立
        // 这是导致之前 NSTextView 完全不能编辑的根因
        let textContainer = (scrollView.documentView as? NSTextView)?.textContainer
            ?? NSTextContainer(size: NSSize(width: 100, height: 100))
        let textView = LinedTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), textContainer: textContainer)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        // macOS Notes 风格滚动条：默认隐藏，内容溢出时自动出现（浮层灰色）
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        if #available(macOS 11.0, *) {
            scrollView.scrollerStyle = .overlay
        }
        scrollView.verticalScroller?.controlSize = .small

        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 17)
        textView.textColor = .textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false

        // 行间距 + 段落最小/最大行高（24pt 紧凑）
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 6
        paragraphStyle.minimumLineHeight = 24
        paragraphStyle.maximumLineHeight = 24
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 17),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraphStyle
        ]

        textView.string = text

        context.coordinator.text = text

        // 强制 NSTextView 立即重绘（让自定义横线在第一次显示时就画出来）
        textView.needsDisplay = true
        scrollView.needsDisplay = true

        DispatchQueue.main.async {
            isFocused.wrappedValue = true
            // 二次触发重绘（layoutManager 第一次完成布局后再画）
            textView.needsDisplay = true
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        // 外部值变化才重写文本
        if context.coordinator.text != text {
            textView.string = text
            context.coordinator.text = text
        }
        // 每次 SwiftUI 重绘都强制 NSTextView 重绘
        textView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: String = ""

        func controlTextDidChange(_ obj: Notification) {
            guard let textView = obj.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

private extension View {
    func padding(topPadding: CGFloat) -> some View {
        self.padding(.top, topPadding)
    }
}

// MARK: - 统一按钮 hover 样式
//
// macOS 原生应用（Finder / Mail / Pages）的所有按钮 hover 体感都是
// 「光标移上去时背景浮现一个浅灰」。这里统一用 `controlColor`（系统控件
// hover 灰），并提供一致的 resting / hover / pressed 三态。

private struct KajiHoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat
    var restingBackground: Color

    init(cornerRadius: CGFloat = 6, restingBackground: Color = .clear) {
        self.cornerRadius = cornerRadius
        self.restingBackground = restingBackground
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor(isPressed: configuration.isPressed))
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func fillColor(isPressed: Bool) -> Color {
        if isPressed { return Color(nsColor: .controlColor).opacity(0.80) }
        return restingBackground
    }
}

/// 支持 hover 状态浮现的包装修饰符
/// 作用：在 Button 的 label 外层包一个透明背景，hover 时换成 controlColor。
private struct KajiHoverBackground: ViewModifier {
    var cornerRadius: CGFloat
    var restingBackground: Color
    @State private var isHovering = false
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering ? hoverColor : restingBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                isHovering = hovering
            }
    }

    private var hoverColor: Color {
        colorScheme == .dark
            ? Color(nsColor: .controlColor)
            : Color(white: 0.84)
    }
}

private extension View {
    func kajiHover(cornerRadius: CGFloat = 6, restingBackground: Color = .clear) -> some View {
        modifier(KajiHoverBackground(cornerRadius: cornerRadius, restingBackground: restingBackground))
    }
}


// MARK: - 右上角搜索浮层

private struct SearchOverlay: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if appState.isSearchActive {
                searchFieldView
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            magnifierButton
        }
    }

    private var searchFieldView: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索卡片...", text: $appState.searchKeyword)
                .textFieldStyle(.plain)
                .frame(width: 220)
                .focused($searchFocused)
                .onSubmit {
                    let keyword = appState.searchKeyword.trimmingCharacters(in: .whitespaces)
                    guard !keyword.isEmpty else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        appState.showList(.search(keyword))
                    }
                }

            Button {
                appState.searchKeyword = ""
                withAnimation(.easeInOut(duration: 0.15)) {
                    appState.isSearchActive = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("清空并关闭")
            .kajiHover(cornerRadius: 6, restingBackground: .clear)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 1)
    }

    private var magnifierButton: some View {
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
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .help("搜索卡片")
        .kajiHover(cornerRadius: 16, restingBackground: magnifierBackgroundColor)
        .overlay(
            Circle()
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        )
    }

    @Environment(\.colorScheme) private var colorScheme

    private var magnifierBackgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: .windowBackgroundColor)
            : Color(white: 0.94)
    }
}

extension Notification.Name {
    static let kajiSearchSubmitted = Notification.Name("kajiSearchSubmitted")
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
            cardsAndTypesSection
            tagsAndItemsSection(tagCounts: tagCounts)
            trashSection
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 22)
        .listRowInsets(EdgeInsets())
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
            SidebarRow(
                title: "新建卡片",
                icon: "plus.square",
                iconColor: .primary,
                count: nil,
                isSelected: false,
                style: .large
            ) {
                appState.startNewCard(type: .free)
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
                isSelected: appState.rightPaneMode == .list && appState.listFilter == .all,
                style: .large
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    appState.showList(.all)
                }
            }
            .padding(.top, -6)

            ForEach(CardType.allCases) { type in
                let selected = appState.rightPaneMode == .list
                    && appState.listFilter == .type(type)

                SidebarRow(
                    title: type.rawValue,
                    icon: "circle.fill",
                    iconColor: type.color,
                    count: nil,
                    isSelected: selected,
                    style: .small
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        appState.showList(.type(type))
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
                    let selected = appState.rightPaneMode == .list
                        && appState.listFilter == .tag(tag)

                    SidebarRow(
                        title: tag,
                        icon: "tag",
                        iconColor: .secondary,
                        count: nil,
                        isSelected: selected,
                        style: .small
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            appState.showList(.tag(tag))
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
            let selected = appState.rightPaneMode == .list
                && appState.listFilter == .trash

            SidebarRow(
                title: "回收站",
                icon: "trash",
                iconColor: .primary,
                count: nil,
                isSelected: selected,
                style: .large
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    appState.showList(.trash)
                }
            }
        }
        // macOS 上 listSectionMargins 不可用；当前 .sidebar 样式
        // 最后一个 Section 底部有系统默认 padding，我们接受这个现状
    }
}

// MARK: - 侧边栏行

/// 侧栏统一按钮行为：
/// - hover：浅灰长条
/// - 按下：深灰长条
/// - 松开：恢复
/// - 背景条长度占满整行，与文字长短无关
private struct SidebarRow: View {
    enum Style { case large, small }

    let title: String
    let icon: String
    let iconColor: Color
    let count: Int?
    let isSelected: Bool
    var style: Style = .large
    var action: () -> Void

    private var iconSize: CGFloat { style == .large ? 16 : 9 }
    private var iconWeight: Font.Weight { style == .large ? .regular : .semibold }
    private var fontSize: CGFloat   { style == .large ? 15 : 13 }
    private var hSpacing: CGFloat   { style == .large ? 10 : 8 }
    private var vPadding: CGFloat   { style == .large ? 6 : 4 }
    private var hPadding: CGFloat   { 16 }
    private var iconFrame: CGFloat  { style == .large ? 22 : 18 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: hSpacing) {
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: iconWeight))
                    .foregroundStyle(iconColor)
                    .frame(width: iconFrame, alignment: .center)

                Text(title)
                    .font(.system(size: fontSize))
                    .lineLimit(1)

                if let count {
                    Spacer(minLength: 8)

                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, vPadding)
            .padding(.horizontal, hPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
    }
}

private struct SidebarRowButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor(isPressed: configuration.isPressed))
                    .padding(.horizontal, 4)
            )
            .onHover { hovering in
                isHovering = hovering
            }
    }

    private func fillColor(isPressed: Bool) -> Color {
        if colorScheme == .dark {
            if isPressed { return Color(white: 0.22) }
            if isHovering { return Color(white: 0.28) }
        } else {
            if isPressed { return Color(white: 0.85) }
            if isHovering { return Color(white: 0.90) }
        }
        return .clear
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
