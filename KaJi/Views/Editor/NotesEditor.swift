//
//  NotesEditor.swift
//  KaJi
//
//  表单化编辑器容器：顶部导航条 + FormEditor + 类型切换确认弹窗。
//

import SwiftUI

struct NotesEditor: View {
    // v1.3.3 PATCH：editorState 注入移除。告警态订阅 alert，业务方法（copyAllContentToPasteboard / confirmPendingCardTypeChange）走 data 直连。
    @EnvironmentObject var data: EditorDataState
    @EnvironmentObject var alert: EditorAlertState
    @State private var showingTypePicker = false
    @State private var newTagText = ""
    @State private var isAddingTag = false

    var body: some View {
        VStack(spacing: 0) {
            // v1.2.6+ UI 重构：删除 NavigationHeader 顶部导航条
            // 返回键已移到 toolbar 区域（MainView 的 .cancellationAction）

            FormEditor(
                showingTypePicker: $showingTypePicker,
                newTagText: $newTagText,
                isAddingTag: $isAddingTag
            )
            .padding(.horizontal, KaJiLayout.contentHorizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, KaJiLayout.headerTopPadding)  // 保留顶部 padding 平衡视觉
        }
        .alert("切换卡片类型", isPresented: $alert.showingTypeChangeAlert) {
            // v1.3.3 PATCH：data 直连（editorState 注入已移除）
            Button("复制全部并切换", role: .none) {
                data.copyAllContentToPasteboard()
                data.confirmPendingCardTypeChange()
            }
            .keyboardShortcut(.defaultAction)
            Button("直接切换", role: .destructive) {
                data.confirmPendingCardTypeChange()
            }
            Button("取消", role: .cancel) {
                alert.pendingCardType = nil
            }
            .keyboardShortcut(.cancelAction)
        } message: {
            Text("当前卡片已有内容，切换类型会清空字段结构。建议先复制全部内容。")
        }
    }
}
