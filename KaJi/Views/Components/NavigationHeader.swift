//
//  NavigationHeader.swift
//  KaJi
//
//  通用顶部导航条：仅保留返回按钮。
//  列表页返回 → 新建卡片；卡片详情页返回 → 对应列表。
//

import SwiftUI

struct NavigationHeader: View {
    @EnvironmentObject var listState: ListState
    @EnvironmentObject var editorState: EditorState

    var body: some View {
        HStack(spacing: 14) {
            backButton
            Spacer()
        }
    }

    private var backButton: some View {
        Button {
            if listState.rightPaneMode == .list {
                // 在列表页：返回新建卡片
                editorState.startNewCard(type: .free)
            } else {
                // 在卡片详情页：返回进入详情前的列表
                // v1.2.5 P0 修复：去掉 withAnimation(.easeInOut(duration: 0.18))。
                // 原因：0.18s 动画期间 SwiftUI 反复重算 DetailView 子树 6 帧，每帧创建/销毁
                // NotesEditor（含 FormEditor/GeometryReader/Canvas）和 CardListView（含 N×CardListRow）。
                // 0.18s 视觉差异肉眼难辨，删除后主线程被绑时间从 ~180ms 降到 ~30ms。
                // 注意：SidebarView 内"点击类型/标签/回收站"仍保留 0.18s 动画，
                // 因为侧栏点击的子树是 SidebarView 自己，不涉及 FormEditor 这种重子树。
                listState.rightPaneMode = .list
            }
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .help("返回")
        .kajiHover(cornerRadius: 16, restingBackground: .clear)
    }
}
