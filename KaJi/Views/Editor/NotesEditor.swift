//
//  NotesEditor.swift
//  KaJi
//
//  表单化编辑器容器：顶部导航条 + FormEditor + 类型切换确认弹窗。
//

import SwiftUI

struct NotesEditor: View {
    @EnvironmentObject var editorState: EditorState
    @State private var showingTypePicker = false
    @State private var newTagText = ""
    @State private var isAddingTag = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航条
            NavigationHeader()
                .padding(.horizontal, KaJiLayout.contentHorizontalPadding)
                .padding(.top, KaJiLayout.headerTopPadding)
                .padding(.bottom, KaJiLayout.headerBottomPadding)
                .offset(y: KaJiLayout.headerTopOffset)

            FormEditor(
                showingTypePicker: $showingTypePicker,
                newTagText: $newTagText,
                isAddingTag: $isAddingTag
            )
            .padding(.horizontal, KaJiLayout.contentHorizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .alert("切换卡片类型", isPresented: $editorState.showingTypeChangeAlert) {
            Button("复制全部并切换", role: .none) {
                editorState.copyAllContentToPasteboard()
                editorState.confirmPendingCardTypeChange()
            }
            .keyboardShortcut(.defaultAction)
            Button("直接切换", role: .destructive) {
                editorState.confirmPendingCardTypeChange()
            }
            Button("取消", role: .cancel) {
                editorState.pendingCardType = nil
            }
            .keyboardShortcut(.cancelAction)
        } message: {
            Text("当前卡片已有内容，切换类型会清空字段结构。建议先复制全部内容。")
        }
    }
}
