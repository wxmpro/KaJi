//
//  KaJiAnimation.swift
//  KaJi
//
//  v1.3.0 引入：统一动画时长常量。
//
//  命名按"角色"（sidebarToggle / editorModeSwitch / searchResultAppear）；
//  后续调整一个常量，全局生效。
//

import SwiftUI

enum KaJiAnimation {
    /// 侧栏显隐切换
    static let sidebarToggle = Animation.easeInOut(duration: 0.2)
    /// 编辑器 / 列表模式切换
    static let editorModeSwitch = Animation.easeInOut(duration: 0.18)
    /// 搜索结果出现
    static let searchResultAppear = Animation.easeInOut(duration: 0.15)
}
