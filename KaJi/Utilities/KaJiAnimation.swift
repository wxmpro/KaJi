//
//  KaJiAnimation.swift
//  KaJi
//
//  统一动画时长常量。命名按"角色"（hover / selection / modeSwitch / searchExpand）；
//  后续调整一个常量，全局生效。
//

import SwiftUI

enum KaJiAnimation {
    /// hover 浮现 / 退出（按钮、tag pill 等轻量元素）
    static let hover         = Animation.easeInOut(duration: 0.12)
    /// 列表行选中、卡片选中态等持久化视觉反馈
    static let selection     = Animation.easeInOut(duration: 0.18)
    /// 模式切换 / 侧栏显隐（统一 sidebarToggle 与 editorModeSwitch，避免时长不一致）
    static let modeSwitch    = Animation.easeInOut(duration: 0.20)
    /// 搜索框展开 / 收起
    static let searchExpand  = Animation.easeInOut(duration: 0.15)
    /// 窗口 resize 等粗粒度动画
    static let windowResize  = Animation.easeInOut(duration: 0.25)
}