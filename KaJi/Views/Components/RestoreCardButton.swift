//
//  RestoreCardButton.swift
//  KaJi
//
//  Toolbar 恢复按钮：仅在回收站上下文可用。
//  点击后恢复当前卡片并返回列表，不进入编辑态。
//

import SwiftUI

struct RestoreCardButton: View {
    @Environment(EditorDataState.self) private var data
    @Environment(ListState.self) private var listState

    /// 当前是否处于回收站上下文
    private var isTrashContext: Bool {
        switch listState.rightPaneMode {
        case .list:
            return listState.listFilter == .trash
        case .editor:
            return data.draft.isTrashOnly
        }
    }

    var body: some View {
        Button {
            guard isTrashContext else { return }
            data.restoreFromTrash(data.draft.card)
            withAnimation(KaJiAnimation.modeSwitch) {
                listState.rightPaneMode = .list
            }
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isTrashContext ? Color.primary : Color.secondary.opacity(0.5))
                .frame(width: 32, height: 32)
        }
        .help(isTrashContext ? "恢复卡片" : "仅在回收站可用")
        .kajiHover(cornerRadius: 16)
    }
}
