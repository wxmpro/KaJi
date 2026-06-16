//
//  KaJiError.swift
//  KaJi
//
//  v1.3.2 引入：顶层统一 error 类型。包 database / markdown / appLifecycle / unknown 四大子域。
//
//  设计原则：
//  - ViewModel / Service 抛 KaJiError（不直接抛 DatabaseError / MarkdownError）
//  - UI 层 `.alert(item: $alert.kaJiError)` 统一捕获，自动解析 errorDescription
//  - 避免在 UI 层写 `switch error` 处理几十个子类型
//
//  长期视角：
//  - 新增子域只需加 case，不影响现有 UI
//  - 测试可对每个子域独立 mock
//

import Foundation

enum KaJiError: LocalizedError {
    /// SQLite 层面错误（事务、约束、迁移、记录不存在等）
    case database(DatabaseError)
    /// .md 字节层面错误（解析、序列化、字段校验等）
    case markdown(MarkdownError)
    /// 应用生命周期错误（启动失败、窗口创建失败、undoManager 不可用等）
    case appLifecycle(AppLifecycleError)
    /// 未分类的底层错误（兜底）
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .database(let e):  return e.errorDescription
        case .markdown(let e):  return e.errorDescription
        case .appLifecycle(let e): return e.errorDescription
        case .unknown(let e):   return e.localizedDescription
        }
    }
}

/// 应用生命周期错误 — 启动 / 关闭 / 窗口 / undoManager 等
enum AppLifecycleError: LocalizedError {
    case bootstrapFailed(underlying: Error)
    case windowCreationFailed(reason: String)
    case undoManagerUnavailable
    case stateContainerMissing(name: String)

    var errorDescription: String? {
        switch self {
        case .bootstrapFailed(let err):
            return "应用启动失败：\(err.localizedDescription)"
        case .windowCreationFailed(let reason):
            return "窗口创建失败：\(reason)"
        case .undoManagerUnavailable:
            return "UndoManager 不可用（窗口未挂载或 .onAppear 未触发）"
        case .stateContainerMissing(let name):
            return "状态容器 `\(name)` 未找到（请检查 .environmentObject 链）"
        }
    }
}