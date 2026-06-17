//
//  BackButton.swift
//  KaJi — 卡迹 · Mac 原生卡片笔记
//
//  v1.2.6+ UI 重构：返回键从主内容顶部 NavigationHeader 移到 toolbar 区域。
//  v1.3.4：离场前 flush，保证 debounce 内未 fire 的编辑/空卡检测立即执行。
//  v1.4.0：@EnvironmentObject → @Environment；startNewCard → startNewDraft
//

import SwiftUI

struct BackButton: View {
    @Environment(ListState.self) private var listState
    @Environment(EditorDataState.self) private var data

    var body: some View {
        Button {
            if listState.rightPaneMode == .list {
                // 在列表页：返回 → 开新空白卡
                data.startNewDraft(type: .free)
            } else {
                // 在卡片详情页：返回 → 回到列表
                // v1.4.0：触发 commitDraft 立即持久化
                Task { @MainActor in
                    _ = await data.commitDraft { _ in }
                }
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
