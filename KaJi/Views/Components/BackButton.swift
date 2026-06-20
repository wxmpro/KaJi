//
//  BackButton.swift
//  KaJi — 卡迹 · Mac 原生卡片笔记
//
//  返回键。离场前 flush，保证 debounce 内未 fire 的编辑/空卡检测立即执行。
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
                // 在卡片详情页：返回 → 回到列表（触发 commitDraft 立即持久化）
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
        .kajiHover(cornerRadius: 16)
    }
}
