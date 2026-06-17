//
//  EditorAlertState.swift
//  KaJi
//
//  告警/弹窗状态层。
//  v1.2.9 T2 改造：原 EditorState 中跨"数据/UI/告警"三类的 11 个 @Published
//  按生命周期拆分到 3 个独立 ObservableObject。
//  v1.4.0：
//  - 迁移到 @Observable
//  - 删除 lastSavedAt（v1.3.4 死字段，0 引用）
//  - 重命名注释：仅保留真正的告警字段
//

import SwiftUI

@Observable
@MainActor
final class EditorAlertState {
    // MARK: - 类型切换弹窗
    var showingTypeChangeAlert: Bool = false
    var pendingCardType: CardType? = nil

    // MARK: - 错误告警
    var saveError: String?

    /// 数据库是否处于 in-memory 模式（fallback）。启动后不变。
    @ObservationIgnored
    var isInMemoryDB: Bool = false
}
