//
//  FormEditor.swift
//  KaJi
//
//  表单化编辑器：左标签栏 + 右输入区。
//

import SwiftUI

struct FormEditor: View {
    @EnvironmentObject var editorState: EditorState
    @Binding var showingTypePicker: Bool
    @Binding var newTagText: String
    @Binding var isAddingTag: Bool
    @Environment(\.colorScheme) var colorScheme

    private let labelWidth: CGFloat = 56
    private let lineHeight: CGFloat = 24
    private let contentFontSize: CGFloat = 16

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(nsColor: .textBackgroundColor)
            : Color.white
    }

    private var lineStrokeColor: Color {
        colorScheme == .dark ? .white.opacity(0.55) : .black
    }

    private var shadowCardColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.gray.opacity(0.30)
    }

    private var borderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.15)
            : Color.gray.opacity(0.35)
    }

    var body: some View {
        ZStack {
            // 下层卡片（向右+上偏移 4pt，露出主卡片的"上+右"边）
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(shadowCardColor)
                .offset(x: 4, y: -4)

            // 上层主卡片
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(borderColor, lineWidth: 0.5)
                )

            // 内容：左侧标签栏 + 右侧输入区（横线只在右侧）
            HStack(spacing: 0) {
                // 左侧标签栏
                VStack(spacing: 0) {
                    labelView("标题")
                    ForEach(editorState.currentCardType.fields, id: \.self) { field in
                        labelView(field)
                    }
                    Spacer()
                    typeButton
                }
                .frame(width: labelWidth)
                .padding(.leading, 12)

                // 右侧输入区
                ZStack(alignment: .topLeading) {
                    ruledPaper
                    inputsColumn
                }
                .padding(.trailing, 12)
            }
            .padding(.top, 30)
            .padding(.bottom, 12)

            // 卡片类型选择浮动层
            if showingTypePicker {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showingTypePicker = false
                    }

                VStack {
                    Spacer()
                    CardTypePickerView(selectedType: editorState.currentCardType) { type in
                        editorState.requestCardTypeChange(to: type)
                        showingTypePicker = false
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(borderColor, lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 10, x: 0, y: -3)
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 44)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func labelView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(height: lineHeight, alignment: .topTrailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 10)
    }

    private var typeButton: some View {
        Button {
            showingTypePicker = true
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(editorState.currentCardType.color)
                    .frame(width: 6, height: 6)
                Text(editorState.currentCardType.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(height: lineHeight)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 10)
        }
        .buttonStyle(.plain)
    }

    private var ruledPaper: some View {
        GeometryReader { _ in
            Canvas { context, size in
                guard size.height > 40 else { return }
                let firstY: CGFloat = lineHeight
                let lastY: CGFloat = size.height - 8
                var y = firstY
                while y <= lastY {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(lineStrokeColor), lineWidth: 0.8)
                    y += lineHeight
                }
            }
        }
    }

    private var inputsColumn: some View {
        VStack(spacing: 0) {
            // 标题输入
            fieldEditor(text: titleBinding)

            // 动态字段
            ForEach(editorState.currentCardType.fields, id: \.self) { fieldName in
                fieldEditor(text: fieldBinding(for: fieldName))
            }

            Spacer()

            // 底部行：标签 + UUID
            bottomMetaRow
        }
    }

    private func fieldEditor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: contentFontSize))
            .lineSpacing(6)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .frame(minHeight: lineHeight * 3, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var bottomMetaRow: some View {
        HStack(spacing: 8) {
            // 标签区
            HStack(spacing: 4) {
                ForEach(editorState.currentCardTags, id: \.self) { tag in
                    TagPill(tag: tag)
                        .contextMenu {
                            Button("删除标签", role: .destructive) {
                                removeTag(tag)
                            }
                        }
                }
                if isAddingTag {
                    TextField("标签", text: $newTagText)
                        .textFieldStyle(.plain)
                        .frame(width: 80)
                        .onSubmit {
                            addTag()
                        }
                } else {
                    Button {
                        isAddingTag = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .kajiHover(cornerRadius: 9, restingBackground: .clear)
                }
            }

            Spacer()

            Text(editorState.currentCard?.displayID ?? "")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(height: lineHeight)
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { editorState.currentCard?.title ?? "" },
            set: { newValue in
                guard var card = editorState.currentCard else { return }
                card.title = newValue
                editorState.currentCard = card
                editorState.saveImmediately()
            }
        )
    }

    private func fieldBinding(for fieldName: String) -> Binding<String> {
        Binding(
            get: {
                editorState.currentCard?.value(ofField: fieldName) ?? ""
            },
            set: { newValue in
                guard var card = editorState.currentCard else { return }
                if let idx = card.fields.firstIndex(where: { $0.fieldName == fieldName }) {
                    card.fields[idx].fieldValue = newValue
                } else {
                    let order = card.fields.count
                    card.fields.append(
                        CardField(cardId: card.id, fieldName: fieldName, fieldValue: newValue, fieldOrder: order)
                    )
                }
                editorState.currentCard = card
                editorState.saveImmediately()
            }
        )
    }

    private func addTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            isAddingTag = false
            newTagText = ""
            return
        }
        editorState.currentCardTags.append(trimmed)
        if var card = editorState.currentCard {
            card.tags = editorState.currentCardTags
            editorState.currentCard = card
            editorState.saveImmediately()
        }
        newTagText = ""
        isAddingTag = false
    }

    private func removeTag(_ tag: String) {
        editorState.currentCardTags.removeAll { $0 == tag }
        if var card = editorState.currentCard {
            card.tags = editorState.currentCardTags
            editorState.currentCard = card
            editorState.saveImmediately()
        }
    }
}
