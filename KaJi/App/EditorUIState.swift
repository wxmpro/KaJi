//
//  EditorUIState.swift
//  KaJi
//
//  UI/搜索状态层。
//  v1.2.9 T2 改造：原 EditorState 中跨"数据/UI/告警"三类的 11 个 @Published
//  按生命周期拆分到 3 个独立 ObservableObject。
//  v1.4.0：迁移到 @Observable（macOS 14+ 原生细粒度订阅）。
//

import SwiftUI

@Observable
@MainActor
final class EditorUIState {
    // MARK: - 侧栏
    var sidebarColumnVisibility: NavigationSplitViewVisibility = .all

    // MARK: - 搜索
    var searchKeyword: String = ""
    var isSearchActive: Bool = false

    // MARK: - 侧栏切换

    func toggleSidebar() {
        withAnimation(KaJiAnimation.modeSwitch) {
            sidebarColumnVisibility = (sidebarColumnVisibility == .all) ? .detailOnly : .all
        }
    }
}
