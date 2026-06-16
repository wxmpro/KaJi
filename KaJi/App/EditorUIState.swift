//
//  EditorUIState.swift
//  KaJi
//
//  UI/搜索状态层。
//  v1.2.9 T2 改造：原 EditorState 中跨"数据/UI/告警"三类的 11 个 @Published
//  按生命周期拆分到 3 个独立 ObservableObject。本文件承载：
//    - NavigationSplitView 侧栏显隐（sidebarColumnVisibility）
//    - toolbar 搜索（searchKeyword / isSearchActive）
//
//  View 改用 @EnvironmentObject var ui 订阅后，编辑器输入字符时不会触发
//  NavigationSplitView 重绘。
//

import SwiftUI

@MainActor
final class EditorUIState: ObservableObject {
    // MARK: - 侧栏
    @Published var sidebarColumnVisibility: NavigationSplitViewVisibility = .all

    func toggleSidebar() {
        // v1.3.2：动画时长统一走 KaJiAnimation.modeSwitch
        withAnimation(KaJiAnimation.modeSwitch) {
            sidebarColumnVisibility = (sidebarColumnVisibility == .all) ? .detailOnly : .all
        }
    }

    // MARK: - 搜索
    @Published var searchKeyword: String = ""
    @Published var isSearchActive: Bool = false
}
