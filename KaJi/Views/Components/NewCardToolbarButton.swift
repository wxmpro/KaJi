//
//  NewCardToolbarButton.swift
//  KaJi
//
//  Toolbar 新建按钮：根据当前上下文智能选择卡片类型。
//  - 编辑器模式且可编辑：使用当前卡片类型
//  - 列表模式且处于某类型筛选：使用该类型
//  - 其他情况（全部/标签/搜索/回收站）：自由卡
//  - 回收站内：显示但禁用，点击无反应
//

import SwiftUI

struct NewCardToolbarButton: View {
    @Environment(EditorDataState.self) private var data
    @Environment(ListState.self) private var listState

    /// 根据当前上下文推断要新建的卡片类型
    private var targetType: CardType {
        switch listState.rightPaneMode {
        case .editor:
            // 编辑器内：若当前卡可编辑，则沿用其类型；回收站只读态 fallback 自由卡
            return data.draft.canEdit ? data.currentCardType : .free
        case .list:
            if case .type(let type) = listState.listFilter {
                return type
            }
            return .free
        }
    }

    /// 当前是否处于回收站上下文（新建按钮在此无效）
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
            guard !isTrashContext else { return }
            data.startNewDraft(type: targetType)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isTrashContext ? Color.secondary.opacity(0.5) : Color.primary)
                .frame(width: 32, height: 32)
        }
        .help(isTrashContext ? "回收站内无法新建" : "新建\(targetType.rawValue)")
        .kajiHover(cornerRadius: 16)
    }
}
