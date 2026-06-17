//
//  NotesEditor.swift
//  KaJi
//
//  表单化编辑器容器：顶部导航条 + FormEditor + 类型切换确认弹窗。
//  v1.4.0：@EnvironmentObject → @Environment
//

import SwiftUI

struct NotesEditor: View {
    @Environment(EditorDataState.self) private var data
    @Environment(EditorAlertState.self) private var alert
    @State private var showingTypePicker = false
    @State private var newTagText = ""
    @State private var isAddingTag = false

    var body: some View {
        @Bindable var alert = alert  // 子 view 持 @Bindable
        VStack(spacing: 0) {
            FormEditor(
                showingTypePicker: $showingTypePicker,
                newTagText: $newTagText,
                isAddingTag: $isAddingTag
            )
            .padding(.horizontal, KaJiLayout.contentHorizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, KaJiLayout.headerTopPadding)
        }
        .alert("切换卡片类型", isPresented: $alert.showingTypeChangeAlert) {
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
