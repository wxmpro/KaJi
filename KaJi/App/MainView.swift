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
            NavigationHeader(showsFilterTitle: true)
                .padding(.horizontal, 50)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .ignoresSafeArea(.container, edges: .top)

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
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 50)
            }
        }
    }
}

/// 通用顶部导航条：← / → + 右侧可选标题
/// - 列表模式：`showsFilterTitle = true` → 显示「自由卡 · 12 张」
/// - 编辑器模式：`showsFilterTitle = false` → 右侧留白
///
/// 视觉规范：back/forward 是 Finder 风格的「胶囊 + 两个圆形按钮」整体。
/// pill 永远显示（controlBackgroundColor 底 + 0.5pt 描边），可点的按钮
/// 默认就是实心灰圆（不依赖 hover 出现）。
private struct NavigationHeader: View {
    @EnvironmentObject var appState: AppState
    let showsFilterTitle: Bool

    var body: some View {
        HStack(spacing: 14) {
            navPill

            Spacer()

            if showsFilterTitle {
                Text("\(appState.listFilterTitle) · \(appState.filteredCards().count) 张")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
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
            Capsule().fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            Capsule().stroke(
                Color(nsColor: .separatorColor).opacity(0.45),
                lineWidth: 0.5
            )
        )
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

private struct CardListRow: View {
    let card: Card

    private var relativeTime: String {
        let now = Date()
        let interval = now.timeIntervalSince(card.updatedAt)
        let day: TimeInterval = 24 * 3600
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < day { return "\(Int(interval / 3600)) 小时前" }
        if interval < day * 2 { return "昨天" }
        if interval < day * 7 { return "\(Int(interval / day)) 天前" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f.string(from: card.updatedAt)
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(card.cardType.color)
                .frame(width: 8, height: 8)

            Text(card.title.isEmpty ? "无标题" : card.title)
                .font(.system(size: 14))
                .lineLimit(1)
                .foregroundStyle(card.title.isEmpty ? .secondary : .primary)

            Spacer(minLength: 12)

            Text(relativeTime)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}

// MARK: - 右侧详情区

private struct DetailView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            // 浅色背景，让白卡片浮起来有阴影对比
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

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
                .padding(.top, 10)
                .padding(.trailing, 46)
                .ignoresSafeArea(.container, edges: .top)
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
            NavigationHeader(showsFilterTitle: false)
                .padding(.horizontal, 50)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .ignoresSafeArea(.container, edges: .top)

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
        SingleTextView(text: $text, isFocused: $isFocused)
            .frame(minHeight: 500, maxHeight: .infinity)
            .padding(.top, 4)
    }
}

private struct SingleTextView: NSViewRepresentable {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
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
        textView.textColor = .black
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.string = text

        context.coordinator.text = text
        DispatchQueue.main.async {
            isFocused.wrappedValue = true
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        // 只有外部值真的变了才重写（用户输入时不重复写）
        if context.coordinator.text != text {
            textView.string = text
            context.coordinator.text = text
        }
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

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering ? Color(nsColor: .controlColor) : restingBackground)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                isHovering = hovering
            }
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
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if appState.isSearchActive {
                searchFieldView
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            magnifierButton
        }
        .onAppear { installClickMonitor() }
        .onDisappear { removeClickMonitor() }
    }

    // MARK: - 全局点击监听

    private func installClickMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard appState.isSearchActive else { return event }
            guard let window = event.window, let contentView = window.contentView else { return event }

            // 搜索浮层在窗口 contentView 内的位置
            // 折叠：x = contentWidth - 16 - 32, y = 10, w = 32, h = 32
            // 展开：x = contentWidth - 16 - 280, y = 10, w = 280, h = 32
            let expanded: CGFloat = appState.isSearchActive ? 280 : 32
            let hitWidth: CGFloat = max(expanded, 32)
            let hitFrame = NSRect(
                x: contentView.bounds.width - 16 - hitWidth,
                y: 10,
                width: hitWidth,
                height: 44
            )
            let clickPoint = contentView.convert(event.locationInWindow, from: nil)
            if hitFrame.contains(clickPoint) {
                return event
            }
            // 点击在搜索区外 → 关闭
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.15)) {
                    appState.isSearchActive = false
                }
            }
            return event
        }
    }

    private func removeClickMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
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
                    NotificationCenter.default.post(name: .kajiSearchSubmitted, object: appState.searchKeyword)
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
        .kajiHover(cornerRadius: 16, restingBackground: Color(nsColor: .windowBackgroundColor))
        .overlay(
            Circle()
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        )
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
                let selected = appState.rightPaneMode == .list
                    && appState.listFilter == .type(type)

                SidebarRow(
                    title: type.rawValue,
                    icon: "circle.fill",
                    iconColor: type.color,
                    count: typeCounts[type, default: 0],
                    isSelected: selected
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        appState.showList(.type(type))
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
                    let selected = appState.rightPaneMode == .list
                        && appState.listFilter == .tag(tag)

                    SidebarRow(
                        title: tag,
                        icon: "tag.fill",
                        iconColor: .secondary,
                        count: count,
                        isSelected: selected
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            appState.showList(.tag(tag))
                        }
                    }
                }
            }
        }
    }

    private var trashSection: some View {
        Section {
            let selected = appState.rightPaneMode == .list
                && appState.listFilter == .trash

            SidebarRow(
                title: "回收站",
                icon: "trash",
                iconColor: .secondary,
                count: 0,
                isSelected: selected
            )
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    appState.showList(.trash)
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
