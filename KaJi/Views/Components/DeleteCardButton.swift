//
//  DeleteCardButton.swift
//  KaJi
//
//  编辑器 toolbar 删除按钮。可用性走 DraftState.canSoftDelete（单一来源）。
//

import SwiftUI

struct DeleteCardButton: View {
    @Environment(EditorDataState.self) private var data

    var body: some View {
        Button {
            data.softDeleteDraft()
        } label: {
            Image(systemName: "arrow.up.trash.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 32, height: 32)
        }
        .help("移到回收站")
        .disabled(!data.draft.canSoftDelete)
    }
}
