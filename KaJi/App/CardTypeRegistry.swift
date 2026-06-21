//
//  CardTypeRegistry.swift
//  KaJi
//
//  卡片类型运行期注册表。
//  阶段1：从 CardType enum 硬编码生成 12 个内置类型 + 1 个兜底类型。
//  阶段2：接入 DB，合并出厂默认 + override + 自定义类型。
//

import SwiftUI
import Observation
import GRDB

/// 运行期类型注册表。
/// 所有 UI/Service/Repository 不再直接引用 `CardType` enum，而通过本注册表按 `typeId: String` 查询定义。
@Observable
final class CardTypeRegistry: @unchecked Sendable {
    static let shared = CardTypeRegistry()

    /// 兜底类型：找不到定义时安全回退
    let fallback: CardTypeDef

    /// 所有类型定义（已按 sortOrder 排序，含 fallback）
    private(set) var all: [CardTypeDef]

    /// 侧栏可见的类型 id 集合
    private(set) var visibleTypeIds: Set<String>

    /// 按 sortOrder 排序后的全部类型（含自定义类型与 fallback）
    var ordered: [CardTypeDef] { all }

    /// 侧栏应展示的类型集合。
    /// 阶段4：按用户设置的可见性过滤，并保持全局排序。
    var sidebarVisible: [CardTypeDef] {
        all.filter { visibleTypeIds.contains($0.id) }
    }

    private init() {
        self.fallback = CardTypeRegistry.makeFallback()
        let loaded = CardTypeRegistry.loadFromDatabase()
        self.all = loaded.defs
        self.visibleTypeIds = loaded.visibleIds
    }

    /// 重新加载（阶段3/4 设置 UI 修改类型定义或顺序/可见性后调用）
    func reload() {
        let loaded = Self.loadFromDatabase()
        all = loaded.defs
        visibleTypeIds = loaded.visibleIds
    }

    /// 按 id 查询类型定义，找不到时回退兜底类型
    func def(for id: String) -> CardTypeDef {
        all.first { $0.id == id } ?? fallback
    }

    /// 按 id 查询类型名称，找不到时回退兜底名称
    func name(for id: String) -> String {
        def(for: id).name
    }

    /// 按 id 查询类型颜色，找不到时回退兜底颜色
    func color(for id: String) -> Color {
        def(for: id).color
    }

    /// 按 id 查询内容字段名（不含标题、参考），找不到时回退兜底字段
    func fieldNames(for id: String) -> [String] {
        def(for: id).fieldNames
    }

    /// 按 id 查询完整字段（标题 + 内容 + 参考）
    /// 标题恒在首位，参考恒在末位
    func allFields(for id: String) -> [String] {
        def(for: id).allFields
    }
}

// MARK: - 内置类型工厂

private extension CardTypeRegistry {
    static func makeFallback() -> CardTypeDef {
        CardTypeDef(
            id: "builtin:fallback",
            name: "其他类型",
            colorRaw: CardType.Tint.gray.rawValue,
            fieldNames: ["字段 1", "字段 2", "字段 3", "字段 4", "字段 5"],
            isBuiltin: true,
            sortOrder: Int.max
        )
    }

    static func makeBuiltinDefs() -> [CardTypeDef] {
        CardType.allCases.enumerated().map { index, type in
            // CardType.fields 末位固定为 "参考"，CardTypeDef.fieldNames 不含 "参考"
            let contentFields = Array(type.fields.dropLast())
            return CardTypeDef(
                id: type.rawValue,
                name: type.rawValue,
                colorRaw: type.tint.rawValue,
                fieldNames: contentFields,
                isBuiltin: true,
                sortOrder: index
            )
        }
    }
}

// MARK: - DB 加载

private extension CardTypeRegistry {
    static func loadFromDatabase() -> (defs: [CardTypeDef], visibleIds: Set<String>) {
        let db = AppDatabase.shared.dbWriter
        do {
            return try db.write { grdb -> (defs: [CardTypeDef], visibleIds: Set<String>) in
                // 首次启动：typeOrder 为空时，用出厂默认顺序初始化
                let existingOrderCount = try TypeOrderRecord.fetchCount(grdb)
                if existingOrderCount == 0 {
                    try seedTypeOrderAndVisibility(in: grdb)
                }

                // 读取顺序
                let orderRecs = try TypeOrderRecord.fetchAll(grdb)
                let orderedIds = orderRecs
                    .sorted { $0.orderIndex < $1.orderIndex }
                    .map { $0.typeId }

                // 读取可见性
                let visibilityRecs = try TypeVisibilityRecord.fetchAll(grdb)
                let visibleIds = Set(visibilityRecs.filter { $0.isVisible }.map { $0.typeId })

                // 读取类型定义与字段
                let dbDefs = try CardTypeDefRecord.fetchAll(grdb)
                let dbFields = try CardTypeFieldRecord.fetchAll(grdb)
                var fieldsByType: [String: [CardTypeFieldRecord]] = [:]
                for f in dbFields {
                    fieldsByType[f.typeId, default: []].append(f)
                }

                // 合并：出厂默认 + override + 自定义
                var result: [CardTypeDef] = []

                for builtin in makeBuiltinDefs() {
                    if let override = dbDefs.first(where: { $0.id == builtin.id }) {
                        let contentFields = fieldsByType[override.id]?
                            .sorted { $0.fieldOrder < $1.fieldOrder }
                            .map { $0.fieldName } ?? []
                        result.append(CardTypeDef(
                            id: override.id,
                            name: override.name,
                            colorRaw: override.colorRaw,
                            fieldNames: contentFields.isEmpty ? builtin.fieldNames : contentFields,
                            isBuiltin: true,
                            sortOrder: builtin.sortOrder
                        ))
                    } else {
                        result.append(builtin)
                    }
                }

                // 自定义类型（排除已删除但回收站仍有卡的占位记录）
                for rec in dbDefs where rec.id.hasPrefix("custom:") && !rec.isDeleted {
                    let contentFields = fieldsByType[rec.id]?
                        .sorted { $0.fieldOrder < $1.fieldOrder }
                        .map { $0.fieldName } ?? []
                    result.append(CardTypeDef(
                        id: rec.id,
                        name: rec.name,
                        colorRaw: rec.colorRaw,
                        fieldNames: contentFields,
                        isBuiltin: false,
                        sortOrder: rec.sortOrder
                    ))
                }

                // 兜底类型：参与排序与可见性，但字段/名称不可编辑
                let fallbackDef = makeFallback()
                result.append(fallbackDef)

                // 按 orderedIds 排序；未知 id 放到末尾
                let orderMap = Dictionary(uniqueKeysWithValues: orderedIds.enumerated().map { ($1, $0) })
                result.sort {
                    let lhs = orderMap[$0.id] ?? Int.max
                    let rhs = orderMap[$1.id] ?? Int.max
                    return lhs < rhs
                }

                return (defs: result, visibleIds: visibleIds)
            }
        } catch {
            // DB 读取失败时回退到出厂默认 + fallback，保证 App 不崩
            return (defs: makeBuiltinDefs() + [makeFallback()], visibleIds: Set(makeBuiltinDefs().map { $0.id }))
        }
    }

    static func seedTypeOrderAndVisibility(in grdb: Database) throws {
        let builtinDefs = makeBuiltinDefs()
        for (index, def) in builtinDefs.enumerated() {
            var orderRec = TypeOrderRecord(orderIndex: index, typeId: def.id)
            try orderRec.insert(grdb)
            var visibilityRec = TypeVisibilityRecord(typeId: def.id, isVisible: true)
            try visibilityRec.insert(grdb)
        }
        // 兜底类型也写入顺序末尾和不可见
        let fallback = makeFallback()
        var fallbackOrderRec = TypeOrderRecord(orderIndex: builtinDefs.count, typeId: fallback.id)
        try fallbackOrderRec.insert(grdb)
        var fallbackVisibilityRec = TypeVisibilityRecord(typeId: fallback.id, isVisible: false)
        try fallbackVisibilityRec.insert(grdb)
    }
}
