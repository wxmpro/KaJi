//
//  EditorUIState.swift
//  KaJi
//
//  UI/搜索状态层。
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
