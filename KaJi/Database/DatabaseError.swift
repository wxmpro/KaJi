//
//  DatabaseError.swift
//  KaJi
//
//  结构化数据库错误。统一所有数据库/文件 IO 错误场景，
//  保留原始 underlying error 链便于 debug log。
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
    case idConflictExhausted(attempts: Int)
    case transactionRollback(reason: String, underlying: Error?)
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
        case .idConflictExhausted(let attempts):
            return "跨进程 ID 冲突：连续 \(attempts) 次重试仍冲突，请检查是否有其他 KaJi 实例异常占用"
        case .transactionRollback(let reason, let err):
            let suffix = err.map { "：\($0.localizedDescription)" } ?? ""
            return "数据库事务回滚 (\(reason))\(suffix)"
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
