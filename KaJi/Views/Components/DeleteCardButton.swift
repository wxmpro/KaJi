//
//  DeleteCardButton.swift
//  KaJi
//
//  编辑器 toolbar 删除按钮。
//  v1.4.0：data.draft.canSoftDelete 替代 data.currentCard == nil || deletedAt != nil 双重判断
//

import SwiftUI

struct DeleteCardButton: View {
    @Environment(EditorDataState.self) private var data

    var body: some View {
        Button {
            data.softDeleteDraft()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 32, height: 32)
        }
        .help("移到回收站")
        // 单一来源：DraftState.canSoftDelete
        .disabled(!data.draft.canSoftDelete)
    }
}
