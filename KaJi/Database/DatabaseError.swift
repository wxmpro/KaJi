//
//  DatabaseError.swift
//  KaJi
//
//  v1.3.0 引入：结构化数据库错误，替换散落的 NSError。
//
//  之前散落在 CardRepository / AppDatabase / CardFileIO 里的 NSError 各自带
//  domain + code，调用方只能拿到 localizedDescription，结构化信息丢失。
//  本枚举统一所有数据库/文件 IO 错误场景，保留原始 underlying error 链
//  便于 debug log。
//

import Foundation

enum DatabaseError: LocalizedError {
    case applicationSupportUnavailable
    case deletedCardSaveAttempt(cardId: String)
    case cardNotFound(id: String)
    case corruptedRecord(id: String, reason: String)
    case tagRecordMissingId
    case tagInsertMissingId
    case tagJoinParseFailed
    case bootstrapFailed(underlying: Error)
    case migrationFailed(version: String, underlying: Error)
    case idConflict(cardId: String)
    case markdownWriteFailed(cardId: String, underlying: Error)
    case markdownParseFailed(reason: String)
    case markdownNoFrontmatter
    case markdownNoFrontmatterEnd
    case reconcileFailed(stage: String, underlying: Error)
    case trashCutoffDateUnavailable
    case databaseUnavailable(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "无法获取 Application Support 目录（沙盒/MDM 限制下可能触发）"
        case .deletedCardSaveAttempt(let id):
            return "拒绝保存已删除的卡片 (\(id))"
        case .cardNotFound(let id):
            return "找不到卡片 (\(id))"
        case .corruptedRecord(let id, let reason):
            return "损坏的数据库记录 (\(id)): \(reason)"
        case .tagRecordMissingId:
            return "标签记录缺少 id"
        case .tagInsertMissingId:
            return "插入标签后未能获取 id"
        case .tagJoinParseFailed:
            return "标签关联解析失败"
        case .bootstrapFailed(let err):
            return "数据库启动失败：\(err.localizedDescription)"
        case .migrationFailed(let v, let err):
            return "数据库迁移失败 (v\(v))：\(err.localizedDescription)"
        case .idConflict(let id):
            return "ID 冲突 (\(id))"
        case .markdownWriteFailed(let id, let err):
            return ".md 写入失败 (\(id))：\(err.localizedDescription)"
        case .markdownParseFailed(let reason):
            return ".md 解析失败：\(reason)"
        case .markdownNoFrontmatter:
            return "无 frontmatter"
        case .markdownNoFrontmatterEnd:
            return "无 frontmatter 结束标记"
        case .reconcileFailed(let stage, let err):
            return "对账失败 (\(stage))：\(err.localizedDescription)"
        case .trashCutoffDateUnavailable:
            return "无法计算回收站清理截止日期"
        case .databaseUnavailable(let err):
            return "数据库不可用：\(err.localizedDescription)"
        }
    }
}
