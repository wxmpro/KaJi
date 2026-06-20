//
//  DeleteCardButton.swift
//  KaJi
//
//  编辑器 toolbar 删除按钮。可用性走 DraftState.canSoftDelete（单一来源）。
//

import SwiftUI

struct DeleteCardButton: View {
    @Environment(EditorDataState.self) private var data
    @Environment(ListState.self) private var listState

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
            data.softDeleteDraft()
        } label: {
            Image(systemName: isTrashContext ? "document.on.trash.fill" : "document.on.trash")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 32, height: 32)
        }
        .help(isTrashContext ? "从回收站恢复" : "移到回收站")
        .disabled(!data.draft.canSoftDelete)
    }
}
