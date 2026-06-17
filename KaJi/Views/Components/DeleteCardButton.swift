//
//  DeleteCardButton.swift
//  KaJi
//
//  编辑器 toolbar 删除按钮（macOS 原生 destructive 样式）。
//  v1.3.4 PATCH：修复 Bug④ — 编辑器界面原本没有删除按钮（只有菜单 ⌘Delete）。
//  行为与 CardLifecycleService.softDelete 完全一致：调 data.softDeleteCard(card)
//  → service 走 SQLite softDelete + undoManager.registerUndo(restore) + rebuildStats。
//

import SwiftUI

struct DeleteCardButton: View {
    @EnvironmentObject var data: EditorDataState

    var body: some View {
        Button {
            guard let card = data.currentCard else { return }
            data.softDeleteCard(card)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 32, height: 32)
        }
        .help("移到回收站")
        // v1.3.4 PATCH：无当前卡或当前卡已在回收站时禁用删除按钮
        .disabled(data.currentCard == nil || data.currentCard?.deletedAt != nil)
    }
}