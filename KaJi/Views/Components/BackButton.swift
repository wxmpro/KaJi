//
//  BackButton.swift
//  KaJi — 卡迹 · Mac 原生卡片笔记
//
//  v1.2.6+ UI 重构：返回键从主内容顶部 NavigationHeader 移到 toolbar 区域
//  （.cancellationAction placement，在搜索栏右侧），跟 searchable 同一水平线。
//  行为完全保留：
//    - 列表页点返回 → 开新空白卡（startNewCard）
//    - 详情页点返回 → 回到列表（rightPaneMode = .list）
//
//  v1.3.1：删 .buttonStyle(.plain) + .kajiHover()，
//  让 SwiftUI 用系统 toolbar item 默认 hover 表现，与 NavigationSplitView
//  系统生成的"切换侧栏"按钮完全一致。
//

import SwiftUI

struct BackButton: View {
    @EnvironmentObject var listState: ListState
    // v1.3.3 PATCH：editorState 注入移除，data 已是 EnvironmentObject。
    @EnvironmentObject var data: EditorDataState

    var body: some View {
        Button {
            if listState.rightPaneMode == .list {
                // 在列表页：返回 → 新建卡片
                // v1.3.3 PATCH：data 直连（editorState 注入已移除）
                data.startNewCard(type: .free)
            } else {
                // 在卡片详情页：返回 → 回到列表
                withAnimation(KaJiAnimation.modeSwitch) {
                    listState.rightPaneMode = .list
                }
            }
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 32, height: 32)
        }
        .help("返回")
    }
}
