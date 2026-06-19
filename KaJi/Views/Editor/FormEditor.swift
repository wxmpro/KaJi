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

    // 标签输入框焦点：失焦即提交待定文本（与字段同级，无需按 Enter）
    @FocusState private var tagFieldFocused: Bool

    // 群4 #29：placeholder 首次 commit 再入锁，防止快速输入生成重复卡。
    // isCreatingCard 在首次 commit 期间为 true；needsResaveAfterCreate 记录
    // 创建期间又有新输入，创建完成后补存一次，保证输入不丢。
    @State private var isCreatingCard = false
    @State private var needsResaveAfterCreate = false

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
    private let cardMaxWidth: CGFloat = 700
    private let cardMaxHeight: CGFloat = 560
    private let cardSideMargin: CGFloat = 40
    private let cardVerticalMargin: CGFloat = 40

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
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
                        Color.clear
                            .frame(width: labelWidth)
                            .padding(.leading, 12)

                        VStack(spacing: 0) {
                            ZStack(alignment: .topLeading) {
                                ruledPaper
                                inputsColumn
                            }
                            typeButton
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
                .frame(maxWidth: cardMaxWidth, maxHeight: cardMaxHeight)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, cardSideMargin)
        .padding(.vertical, cardVerticalMargin)
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
            // 首次输入：创建 UUID + 持久化（群4 #29：经再入锁，防重复卡）
            createCardFromLocalState()
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

    /// 群4 #29：placeholder 首次落地的唯一入口，带再入锁。
    /// 快速连续输入时，char1 的 commitDraft 还在 await CardIDGenerator（异步）
    /// 期间，char2 看到 isPlaceholder 仍为 true 会再起一次 commit → 生成两张
    /// ID 不同的重复卡。用 isCreatingCard 锁住：创建进行中只标记 needsResave，
    /// 创建完成后（draft 已非 placeholder）补存一次，保证期间输入不丢。
    private func createCardFromLocalState() {
        guard !isCreatingCard else {
            needsResaveAfterCreate = true
            return
        }
        isCreatingCard = true
        saveTask?.cancel()
        saveTask = nil
        Task { @MainActor in
            _ = await data.commitDraft { draft in
                draft.title = title
                draft.fields = buildFieldsPreservingOrder(for: draft)
                draft.tags = tags
            }
            isCreatingCard = false
            if needsResaveAfterCreate {
                needsResaveAfterCreate = false
                scheduleSave()   // 此时 draft 已非 placeholder → 走 debounce 补存最新输入
            }
        }
    }

    /// 立即同步本地 state → draft 并持久化（不走 debounce）。
    /// 用于标签增删这类离散、低频操作：用户点一下就要立刻落库，
    /// 否则「加标签 → 800ms 内点返回」会因 debounce task 被取消而丢标签。
    /// 同时取消 pending 的打字 debounce，把当前本地全量 state 一次性提交，
    /// 避免与后续 commit 竞争（saveToken 递增使旧 task 自动失效）。
    private func flushNow() {
        guard !isReadOnly else { return }
        if card.isPlaceholder {
            // 新卡首次落地：标签随首次 commit 一起持久化（同走再入锁入口）
            createCardFromLocalState()
            return
        }
        saveToken += 1
        let token = saveToken
        saveTask?.cancel()
        saveTask = nil
        Task { @MainActor in
            guard token == saveToken else { return }
            data.updateDraft { draft in
                draft.title = title
                draft.fields = buildFieldsPreservingOrder(for: draft)
                draft.tags = tags
            }
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
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                fieldRow(name: "标题", text: $title, onChange: { _, new in
                    title = new
                    scheduleSave()
                })

                ForEach(currentFields, id: \.self) { fieldName in
                    fieldRow(
                        name: fieldName,
                        text: bindingForField(fieldName),
                        onChange: { _, _ in
                            scheduleSave()
                        }
                    )
                }

                bottomMetaRow
            }
        }
    }

    private func fieldRow(
        name: String,
        text: Binding<String>,
        onChange: @escaping (String, String) -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
                .padding(.trailing, 10)

            fieldEditor(text: text, onChange: onChange)
        }
    }

    @ViewBuilder
    private func fieldEditor(
        text: Binding<String>,
        onChange: @escaping (String, String) -> Void
    ) -> some View {
        if isReadOnly {
            Text(text.wrappedValue.isEmpty ? "（空）" : text.wrappedValue)
                .font(.system(size: contentFontSize))
                .lineSpacing(6)
                .foregroundStyle(text.wrappedValue.isEmpty ? .tertiary : .primary)
                .frame(maxWidth: .infinity, minHeight: lineHeight, alignment: .topLeading)
                .textSelection(.enabled)
        } else {
            TextEditor(text: text)
                .font(.system(size: contentFontSize))
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .frame(minHeight: lineHeight, alignment: .topLeading)
                .onChange(of: text.wrappedValue) { old, new in
                    onChange(old, new)
                }
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
                            .focused($tagFieldFocused)
                            .onSubmit { addTag() }
                            // 标签与字段同级：失焦即提交，无需按 Enter。
                            // 点返回 / 点别处都会让输入框失焦 → 把待定文本落为标签。
                            .onChange(of: tagFieldFocused) { _, focused in
                                if !focused { addTag() }
                            }
                            .onAppear { tagFieldFocused = true }
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
        flushNow()
    }

    private func removeTag(_ tag: String) {
        guard !isReadOnly else { return }
        tags.removeAll { $0 == tag }
        flushNow()
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