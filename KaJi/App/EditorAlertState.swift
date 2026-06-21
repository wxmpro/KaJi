//
//  EditorAlertState.swift
//  KaJi
//
//  告警/弹窗状态层。
//

import SwiftUI

@Observable
@MainActor
final class EditorAlertState {
    // MARK: - 类型切换弹窗
    var showingTypeChangeAlert: Bool = false
    var pendingCardType: String? = nil

    // MARK: - 错误告警
    var saveError: String?

    /// 数据库是否处于 in-memory 模式（fallback）。启动后不变。
    @ObservationIgnored
    var isInMemoryDB: Bool = false
}
