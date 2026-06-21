//
//  CardTypeSettingsView.swift
//  KaJi
//
//  设置 → 卡片类型 Tab：管理内置/自定义卡片类型。
//

import SwiftUI
import os

struct CardTypeSettingsView: View {
    @State private var registry = CardTypeRegistry.shared
    @State private var editingDef: CardTypeDef? = nil
    @State private var showingDeleteAlert = false
    @State private var typeToDelete: CardTypeDef? = nil
    @State private var errorMessage: String? = nil
    @Environment(\.undoManager) private var undoManager

    /// 侧栏当前已勾选数量（上限 12）
    private var visibleCount: Int {
        registry.sidebarVisible.count
    }

    var body: some View {
        VStack(spacing: 0) {
            typeList
            bottomBar
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 36)
        .sheet(item: $editingDef) { def in
                CardTypeEditorSheet(
                    def: def,
                    onSave: { save(def: def, name: $0, colorRaw: $1, fieldNames: $2) },
                    onCancel: { editingDef = nil }
                )
            }
            .alert("删除自定义类型", isPresented: $showingDeleteAlert) {
                Button("转为「其他类型」", role: .cancel) {
                    deleteType(preserveCards: true)
                }
                Button("连卡一起删", role: .destructive) {
                    deleteType(preserveCards: false)
                }
                Button("取消", role: .cancel) { }
            } message: {
                if let def = typeToDelete {
                    Text("「\(def.name)」下已有卡片。请选择：保留卡片并转为「其他类型」，或一并删除进入回收站。")
                } else {
                    Text("")
                }
            }
            .alert("错误", isPresented: .constant(errorMessage != nil)) {
                Button("确定") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    // MARK: - 列表

    private var typeList: some View {
        VStack(spacing: 0) {
            headerRow
            List {
                ForEach(registry.ordered) { def in
                    typeRow(for: def)
                }
                .onMove(perform: moveType)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerRow: some View {
        HStack {
            HStack(spacing: 8) {
                Text("")
                    .frame(width: 12, alignment: .center)
                Text("类型")
            }
            Spacer()
            Text("字段")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }

    private func typeRow(for def: CardTypeDef) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.horizontal.3")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 12, alignment: .center)

            Circle()
                .fill(def.color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(def.name)
                    .font(.system(size: 13))
                HStack(spacing: 6) {
                    if def.isBuiltin {
                        Text("内置")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if def.id == "builtin:fallback" {
                        Text("兜底")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if def.isBuiltin && isBuiltinModified(def) {
                        Text("已修改")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            Text("\(def.fieldNames.count)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)

            HStack(spacing: 8) {
                if def.id == "builtin:fallback" {
                    EmptyView()
                } else if def.isBuiltin {
                    if isBuiltinModified(def) {
                        Button("恢复默认") {
                            restoreBuiltin(def: def)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                } else {
                    Button("编辑") {
                        editingDef = def
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)

                    Button("删除") {
                        promptDelete(def: def)
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            Toggle("", isOn: isVisibleBinding(for: def))
                .toggleStyle(.checkbox)
                .frame(width: 18, alignment: .center)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }

    private func isBuiltinModified(_ def: CardTypeDef) -> Bool {
        // 与出厂默认比较：名称、字段、颜色任一不同即视为已修改
        guard let builtin = CardType.allCases.first(where: { $0.rawValue == def.id }) else { return false }
        let builtinFields = Array(builtin.fields.dropLast())
        let builtinColor = builtin.tint.rawValue
        return def.name != builtin.rawValue
            || def.fieldNames != builtinFields
            || def.colorRaw != builtinColor
    }

    // MARK: - 底部栏

    private var bottomBar: some View {
        HStack {
            Text("侧栏展示 \(visibleCount) / 12")
                .font(.system(size: 12))
                .foregroundStyle(visibleCount >= 12 ? .orange : .secondary)

            Spacer()

            Button {
                editingDef = CardTypeDef(
                    id: "",
                    name: "",
                    colorRaw: CardType.Tint.gray.rawValue,
                    fieldNames: ["字段 1"],
                    isBuiltin: false,
                    sortOrder: 0
                )
            } label: {
                Label("新建类型", systemImage: "plus")
            }
            .controlSize(.regular)
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    // MARK: - 操作

    private func isVisibleBinding(for def: CardTypeDef) -> Binding<Bool> {
        Binding(
            get: { registry.visibleTypeIds.contains(def.id) },
            set: { newValue in
                toggleVisibility(for: def, isVisible: newValue)
            }
        )
    }

    private func toggleVisibility(for def: CardTypeDef, isVisible: Bool) {
        if isVisible && visibleCount >= 12 {
            errorMessage = "侧栏最多展示 12 个类型，请先取消一个"
            return
        }
        do {
            try CardTypeDefPersistenceService.shared.setTypeVisible(def.id, isVisible: isVisible)
            registry.reload()
        } catch {
            errorMessage = "保存可见性失败：\(error.localizedDescription)"
        }
    }

    private func moveType(from source: IndexSet, to destination: Int) {
        var reordered = registry.ordered
        reordered.move(fromOffsets: source, toOffset: destination)
        let orderedIds = reordered.map { $0.id }
        do {
            try CardTypeDefPersistenceService.shared.saveTypeOrder(orderedIds)
            registry.reload()
        } catch {
            errorMessage = "保存排序失败：\(error.localizedDescription)"
        }
    }

    private func save(def: CardTypeDef, name: String, colorRaw: String, fieldNames: [String]) {
        do {
            if def.id.isEmpty {
                // 新建
                let customCount = registry.ordered.filter { !$0.isBuiltin && $0.id != "builtin:fallback" }.count
                guard customCount < 12 else {
                    errorMessage = "自定义类型最多 12 个，请先删除不再使用的类型"
                    return
                }
                guard !(try CardTypeDefPersistenceService.shared.isNameTaken(name, excluding: nil)) else {
                    errorMessage = "类型名称「\(name)」已存在"
                    return
                }
                _ = try CardTypeDefPersistenceService.shared.saveCustomType(
                    name: name,
                    colorRaw: colorRaw,
                    fieldNames: fieldNames
                )
            } else if def.isBuiltin {
                // 内置 override
                try CardTypeDefPersistenceService.shared.saveBuiltinOverride(
                    id: def.id,
                    name: name,
                    colorRaw: colorRaw,
                    fieldNames: fieldNames
                )
                let snapshot = try CardTypeFieldMigrationService.shared.migrate(typeId: def.id, to: fieldNames)
                registerUndo(restoring: def, snapshot: snapshot)
            } else {
                // 自定义类型编辑：名称查重
                guard !(try CardTypeDefPersistenceService.shared.isNameTaken(name, excluding: def.id)) else {
                    errorMessage = "类型名称「\(name)」已存在"
                    return
                }
                try CardTypeDefPersistenceService.shared.saveCustomType(
                    id: def.id,
                    name: name,
                    colorRaw: colorRaw,
                    fieldNames: fieldNames
                )
                let snapshot = try CardTypeFieldMigrationService.shared.migrate(typeId: def.id, to: fieldNames)
                registerUndo(restoring: def, snapshot: snapshot)
            }
            registry.reload()
            editingDef = nil
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func registerUndo(restoring def: CardTypeDef, snapshot: MigrationSnapshot) {
        guard !snapshot.isEmpty else { return }
        undoManager?.registerUndo(withTarget: CardTypeFieldMigrationService.shared) { _ in
            do {
                if def.isBuiltin {
                    try CardTypeDefPersistenceService.shared.saveBuiltinOverride(
                        id: def.id,
                        name: def.name,
                        colorRaw: def.colorRaw,
                        fieldNames: def.fieldNames
                    )
                } else {
                    try CardTypeDefPersistenceService.shared.saveCustomType(
                        id: def.id,
                        name: def.name,
                        colorRaw: def.colorRaw,
                        fieldNames: def.fieldNames
                    )
                }
                try CardTypeFieldMigrationService.shared.restoreDeletedFields(snapshot)
                CardTypeRegistry.shared.reload()
            } catch {
                os_log("撤销减少字段失败: %{public}@", error.localizedDescription)
            }
        }
        undoManager?.setActionName("减少字段")
    }

    private func restoreBuiltin(def: CardTypeDef) {
        do {
            try CardTypeDefPersistenceService.shared.restoreBuiltinDefault(id: def.id)
            registry.reload()
        } catch {
            errorMessage = "恢复默认失败：\(error.localizedDescription)"
        }
    }

    private func promptDelete(def: CardTypeDef) {
        typeToDelete = def
        do {
            let count = try CardTypeDefPersistenceService.shared.cardCount(for: def.id)
            if count > 0 {
                showingDeleteAlert = true
            } else {
                // 无卡直接删除
                deleteType(preserveCards: true)
            }
        } catch {
            errorMessage = "检查卡片数失败：\(error.localizedDescription)"
        }
    }

    private func deleteType(preserveCards: Bool) {
        guard let def = typeToDelete else { return }
        do {
            if preserveCards {
                _ = try CardTypeFieldMigrationService.shared.migrateToFallback(typeId: def.id)
            }
            _ = try CardTypeDefPersistenceService.shared.deleteCustomType(
                id: def.id,
                preserveCards: preserveCards
            )
            registry.reload()
            typeToDelete = nil
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 类型编辑器 Sheet

struct CardTypeEditorSheet: View {
    let def: CardTypeDef
    let onSave: (String, String, [String]) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var colorRaw: String = ""
    @State private var fields: [String] = []
    @FocusState private var focusedField: Int?

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Form {
                Section {
                    TextField("类型名称", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                Section {
                    ColorPicker("颜色", selection: colorBinding)
                }

                Section {
                    ForEach(fields.indices, id: \.self) { index in
                        HStack {
                            Text("字段 \(index + 1)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .leading)
                            TextField("字段名", text: $fields[index])
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: index)
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            guard fields.count < 5 else { return }
                            fields.append("字段 \(fields.count + 1)")
                        } label: {
                            Label("添加字段", systemImage: "plus")
                        }
                        .disabled(fields.count >= 5)

                        Button {
                            guard fields.count > 1 else { return }
                            fields.removeLast()
                        } label: {
                            Label("删除末尾字段", systemImage: "minus")
                        }
                        .disabled(fields.count <= 1)
                    }
                    .padding(.top, 4)
                } header: {
                    Text("内容字段（1–5 个）")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .formStyle(.grouped)
            .padding(.top, 8)
        }
        .frame(width: 420, height: 360)
        .onAppear {
            name = def.name
            colorRaw = def.colorRaw
            fields = def.fieldNames.isEmpty ? ["字段 1"] : def.fieldNames
        }
    }

    private var sheetHeader: some View {
        HStack {
            Button("取消") { onCancel() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Text(def.id.isEmpty ? "新建类型" : "编辑类型")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button("保存") {
                onSave(name, colorRaw, fields)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .disabled(name.isEmpty || fields.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: colorRaw) ?? Color.gray },
            set: { newColor in
                colorRaw = newColor.toHex() ?? "gray"
            }
        )
    }
}

// MARK: - Color HEX 扩展

private extension Color {
    init?(hex: String) {
        // 优先匹配内置 tint 名
        if CardType.Tint(rawValue: hex) != nil {
            // 这里需要解析成实际 Color，复用 CardTypeDef.resolveColor
            let def = CardTypeDef(
                id: "", name: "", colorRaw: hex,
                fieldNames: [], isBuiltin: true, sortOrder: 0
            )
            self = def.color
            return
        }

        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 || hexSanitized.count == 8 else { return nil }

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r, g, b, a: Double
        if hexSanitized.count == 6 {
            r = Double((rgb & 0xFF0000) >> 16) / 255.0
            g = Double((rgb & 0x00FF00) >> 8) / 255.0
            b = Double(rgb & 0x0000FF) / 255.0
            a = 1.0
        } else {
            r = Double((rgb & 0xFF000000) >> 24) / 255.0
            g = Double((rgb & 0x00FF0000) >> 16) / 255.0
            b = Double((rgb & 0x0000FF00) >> 8) / 255.0
            a = Double(rgb & 0x000000FF) / 255.0
        }

        self.init(red: r, green: g, blue: b, opacity: a)
    }

    func toHex() -> String? {
        // 简化实现：从 NSColor 取 components
        #if canImport(AppKit)
        let nsColor = NSColor(self)
        guard let converted = nsColor.usingColorSpace(.sRGB) else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        converted.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int(round(r * 255))
        let gi = Int(round(g * 255))
        let bi = Int(round(b * 255))
        return String(format: "%02X%02X%02X", ri, gi, bi)
        #else
        return nil
        #endif
    }
}
