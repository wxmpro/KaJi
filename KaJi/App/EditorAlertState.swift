//
//  EditorAlertState.swift
//  KaJi
//
//  告警/弹窗状态层。
//  v1.2.9 T2 改造：原 EditorState 中跨"数据/UI/告警"三类的 11 个 @Published
//  按生命周期拆分到 3 个独立 ObservableObject。本文件承载：
//    - 类型切换确认弹窗（showingTypeChangeAlert / pendingCardType）
//    - 数据层告警（saveError / lastSavedAt / isInMemoryDB）
//
//  不影响视觉和交互；View 改用 @EnvironmentObject var alert 订阅后，
//  编辑器输入字符时不再触发告警相关的视图重绘。
//

import SwiftUI

@MainActor
final class EditorAlertState: ObservableObject {
    // MARK: - 类型切换弹窗
    @Published var showingTypeChangeAlert: Bool = false
    @Published var pendingCardType: CardType? = nil

    // MARK: - 数据层告警
    @Published var saveError: String?
    @Published var lastSavedAt: Date?

    /// 数据库是否处于 in-memory 模式（fallback）。启动后不变，用普通 var
    /// 节省一次 objectWillChange 通知。
    var isInMemoryDB: Bool = false
}
