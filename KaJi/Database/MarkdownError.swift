//
//  MarkdownError.swift
//  KaJi
//
//  v1.3.2 引入：独立的 .md 文件读写错误类型，从 DatabaseError 拆出。
//
//  为什么独立：
//  - DatabaseError 是 SQLite 层面错误（行 89-123 等事务上下文）
//  - MarkdownError 是字节层面错误（文件 I/O + 解析器上下文）
//  - 混在一起调用方无法精确分类（同样的 DatabaseError.markdownParseFailed 在哪个层抛？不清楚）
//  - 拆分后调用方写 `catch MarkdownError.unknownField(let name, let line)` 可以拿到精确位置
//
//  不变量：
//  - 所有 case 都带 (line, column) 或精确上下文，便于用户在 .md 文件中定位错误
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
        }
    }
}