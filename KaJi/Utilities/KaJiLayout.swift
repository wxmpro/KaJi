//
//  KaJiLayout.swift
//  KaJi
//
//  全局 UI 布局常量。
//  避免 magic number 散落在各 View 中；修改一处即可统一视觉。
//

import CoreGraphics

enum KaJiLayout {
    // MARK: - 内容边距

    /// 主内容区左右边距（编辑器 / 列表与窗口边缘的距离）
    static let contentHorizontalPadding: CGFloat = 50

    /// 列表标题右缩进（为右上角搜索按钮留空）
    static let listTitleTrailingPadding: CGFloat = 62

    // MARK: - 顶部对齐

    /// NavigationHeader / SearchOverlay 向上偏移，与 traffic-lights 同一水平线
    static let headerTopOffset: CGFloat = -10

    /// NavigationHeader 顶部内边距
    static let headerTopPadding: CGFloat = 5

    /// NavigationHeader 底部内边距
    static let headerBottomPadding: CGFloat = 4

    /// 列表标题向下微调，与 header 对齐
    static let listTitleTopOffset: CGFloat = -6

    /// 列表标题底部间距
    static let listTitleBottomPadding: CGFloat = 8

    // MARK: - 通用圆角

    /// 小按钮 / 标签 pill 圆角
    static let smallCornerRadius: CGFloat = 6

    /// 中等卡片 / 浮层圆角
    static let mediumCornerRadius: CGFloat = 10

    /// 大卡片 / picker 圆角
    static let largeCornerRadius: CGFloat = 12

    /// 圆形按钮（返回、搜索放大镜）圆角
    static let circularCornerRadius: CGFloat = 16
}
