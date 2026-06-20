//
//  MarkdownError.swift
//  KaJi
//
//  独立的 .md 文件读写错误类型，从 DatabaseError 拆出。
//  DatabaseError 是 SQLite 层错误，MarkdownError 是字节层错误（文件 I/O + 解析器）。
//  拆分后调用方可拿到精确位置（如 unknownField 的 line）。
//
//  不变量：所有 case 都带 (line, column) 或精确上下文，便于在 .md 中定位错误。
//

import Foundation

enum MarkdownError: LocalizedError {
    /// 解析失败，附带精确位置
    case parseFailed(line: Int, column: Int, reason: String)
    /// 缺少 frontmatter 起始标记 `---`
    case missingFrontmatter
    /// 缺少 frontmatter 结束标记（定位到搜索失败的位置）
    case missingFrontmatterEnd(line: Int)
    /// 字段名不在已知集合内（防止 `## 误识别` 静默丢失内容）
    case unknownField(name: String, line: Int)
    /// 字段不变量违反（如 tags 为空但 schema 要求至少 1 个）
    case invariantViolation(field: String, reason: String)
    /// .md 文件写入失败
    case writeFailed(cardId: String, underlying: Error)
    /// 卡片 ID 不合法（非 17 位纯数字）
    case invalidID(id: String)

    var errorDescription: String? {
        switch self {
        case .parseFailed(let line, let col, let reason):
            return ".md 解析失败（第 \(line) 行第 \(col) 列）：\(reason)"
        case .missingFrontmatter:
            return ".md 文件缺少 frontmatter 起始标记 `---`"
        case .missingFrontmatterEnd(let line):
            return ".md 文件缺少 frontmatter 结束标记（搜索到第 \(line) 行未找到）"
        case .unknownField(let name, let line):
            return "未知字段 `\(name)`（第 \(line) 行）— 字段名必须在 CardType schema 定义的合法集合内"
        case .invariantViolation(let field, let reason):
            return ".md 不变量违反：字段 `\(field)` \(reason)"
        case .writeFailed(let id, let err):
            return ".md 写入失败 (\(id))：\(err.localizedDescription)"
        case .invalidID(let id):
            return "卡片 ID 不合法（\(id)）：必须是 17 位纯数字"
        }
    }
}