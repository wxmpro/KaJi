//
//  FormEditor.swift
//  KaJi
//
//  v1.4.0 状态机彻底重构（局部 @State + onChange 模式）：
//  - title / fieldValues / tags 改用本地 @State
//  - 通过 scheduleSave 同步到 data（首次立即 / 后续 800ms debounce）
//
//  v1.4.0 Bug 修复：
//  - Bug 2: buildFields 保留原 card.fields 的 fieldOrder
//  - Bug 8: scheduleSave 串行化（saveToken 防并发 commitDraft）
//

import SwiftUI

struct FormEditor: View {
    @Environment(EditorDataState.self) private var data

    // 本地 @State
    @State private var title: String = ""
    @State private var fieldValues: [String: String] = [:]
    @State private var tags: [String] = []

    // 同步任务（Bug 8 修复：saveToken 串行化）
    @State private var saveTask: Task<Void, Never>?
    @State private var saveToken: Int = 0  // 每次 scheduleSave 递增；旧 Task 检查 token 后退出
    @State private var lastSyncedCardID: String? = nil

    @Binding var showingTypePicker: Bool
    @Binding var newTagText: String
    @Binding var isAddingTag: Bool
    @Environment(\.colorScheme) private var colorScheme

    // 派生
    private var card: Card { data.draft.card }
    private var isReadOnly: Bool { data.draft.isReadOnly }
    private var currentFields: [String] { card.cardType.fields }
    private var displayID: String {
        card.isPlaceholder ? "" : card.displayID
    }

    private let labelWidth: CGFloat = 56
    private let lineHeight: CGFloat = 24
    private let contentFontSize: CGFloat = 16

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(shadowCardColor)
                .offset(x: 4, y: -4)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(borderColor, lineWidth: 0.5)
                )

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    labelView("标题")
                    ForEach(currentFields, id: \.self) { field in
                        labelView(field)
                    }
                    Spacer()
                    typeButton
                }
                .frame(width: labelWidth)
                .padding(.leading, 12)

                ZStack(alignment: .topLeading) {
                    ruledPaper
                    inputsColumn
                }
                .padding(.trailing, 12)
            }
            .padding(.top, 30)
            .padding(.bottom, 12)

            if showingTypePicker {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { showingTypePicker = false }

                VStack {
                    Spacer()
                    CardTypePickerView(selectedType: card.cardType) { type in
                        data.requestCardTypeChange(to: type)
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
                            .shadow(color: KaJiColor.cardShadowHover.resolve(for: colorScheme), radius: 10, x: 0, y: -3)
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 44)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 32)
        .onChange(of: data.draft.cardID) { _, newID in
            if newID != lastSyncedCardID {
                initializeLocalState()
            }
        }
        .onAppear { initializeLocalState() }
    }

    private func initializeLocalState() {
        title = card.title
        fieldValues = Dictionary(uniqueKeysWithValues: card.fields.map { ($0.fieldName, $0.fieldValue) })
        tags = card.tags
        lastSyncedCardID = card.id
    }

    /// 同步本地 state → data
    /// Bug 8 修复：saveToken 串行化，避免并发 commitDraft
    /// 防御性守卫：isReadOnly 时拒绝保存（即使 SwiftUI disabled 失效也不会持久化）
    private func scheduleSave() {
        guard !isReadOnly else { return }
        if card.isPlaceholder {
            // 首次输入：立即 commitDraft（创建 UUID + 持久化）
            let token = saveToken
            Task { @MainActor in
                guard token == saveToken else { return }
                _ = await data.commitDraft { draft in
                    draft.title = title
                    draft.fields = buildFieldsPreservingOrder(for: draft)
                    draft.tags = tags
                }
            }
            return
        }

        // 后续输入：800ms debounce
        saveToken += 1
        let token = saveToken
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(SettingsService.autoSaveInterval * 1000)))
            guard !Task.isCancelled, token == saveToken else { return }
            // 先 updateDraft 应用本地 state 到 draft
            data.updateDraft { draft in
                draft.title = title
                draft.fields = buildFieldsPreservingOrder(for: draft)
                draft.tags = tags
            }
            // 再 commit 持久化（nil transform = 直接持久化当前 draft）
            _ = await data.commitDraft()
        }
    }

    /// Bug 2 修复：保留原 card.fields 的 fieldOrder，仅更新 fieldValue
    /// - 如果原 fields 存在：保留其 fieldOrder 和字段值
    /// - 如果原 fields 不存在（如 placeholder）：用 currentFields 枚举生成
    private func buildFieldsPreservingOrder(for draft: Card) -> [CardField] {
        let existingFields = draft.fields
        let existingMap = Dictionary(uniqueKeysWithValues: existingFields.map { ($0.fieldName, $0) })

        // 按 currentFields 顺序（用户看到的字段顺序）生成
        return currentFields.enumerated().map { idx, name in
            let value = fieldValues[name] ?? existingMap[name]?.fieldValue ?? ""
            // 保留原 fieldOrder（如果存在），否则用 currentFields 的 idx
            let order = existingMap[name]?.fieldOrder ?? idx
            return CardField(
                cardId: draft.id,
                fieldName: name,
                fieldValue: value,
                fieldOrder: order
            )
        }
    }

    // MARK: - 子 view

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
            guard !isReadOnly else { return }
            showingTypePicker = true
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(card.cardType.color)
                    .frame(width: 6, height: 6)
                Text(card.cardType.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(height: lineHeight)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 10)
        }
        .buttonStyle(.plain)
        .disabled(isReadOnly)
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
            fieldEditor(text: $title, onChange: { _, new in
                title = new
                scheduleSave()
            })

            ForEach(currentFields, id: \.self) { fieldName in
                fieldEditor(
                    text: bindingForField(fieldName),
                    onChange: { _, _ in
                        scheduleSave()
                    }
                )
            }

            Spacer()

            bottomMetaRow
        }
    }

    private func fieldEditor(
        text: Binding<String>,
        onChange: @escaping (String, String) -> Void
    ) -> some View {
        TextEditor(text: text)
            .font(.system(size: contentFontSize))
            .lineSpacing(6)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .frame(minHeight: lineHeight * 3, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(isReadOnly)
            .onChange(of: text.wrappedValue) { old, new in
                onChange(old, new)
            }
    }

    private var bottomMetaRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    RemovableTagPill(tag: tag, canRemove: !isReadOnly) {
                        removeTag(tag)
                    }
                }
                if !isReadOnly {
                    if isAddingTag {
                        TextField("标签", text: $newTagText)
                            .textFieldStyle(.plain)
                            .frame(width: 80)
                            .onSubmit { addTag() }
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
            }

            Spacer()

            Text(displayID)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(height: lineHeight)
    }

    private func bindingForField(_ fieldName: String) -> Binding<String> {
        Binding(
            get: { fieldValues[fieldName, default: ""] },
            set: { fieldValues[fieldName, default: ""] = $0 }
        )
    }

    private func addTag() {
        guard !isReadOnly else { return }
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            isAddingTag = false
            newTagText = ""
            return
        }
        guard !tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            newTagText = ""
            isAddingTag = false
            return
        }
        tags.append(trimmed)
        newTagText = ""
        isAddingTag = false
        scheduleSave()
    }

    private func removeTag(_ tag: String) {
        guard !isReadOnly else { return }
        tags.removeAll { $0 == tag }
        scheduleSave()
    }

    // MARK: - 颜色

    private var cardBackground: Color {
        KaJiColor.cardBackground.resolve(for: colorScheme)
    }
    private var lineStrokeColor: Color {
        KaJiColor.cardFieldStroke.resolve(for: colorScheme)
    }
    private var shadowCardColor: Color {
        KaJiColor.cardShadow.resolve(for: colorScheme)
    }
    private var borderColor: Color {
        KaJiColor.cardBorder.resolve(for: colorScheme)
    }
}