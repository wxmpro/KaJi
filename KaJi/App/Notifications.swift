//
//  Notifications.swift
//  KaJi
//
//  跨模块的 Notification 名称集中定义。
//  用于菜单命令（⌘N / ⌘S）转发到 UI 层。
//

import Foundation

extension Notification.Name {
    static let newCardRequested = Notification.Name("KaJi.newCardRequested")
    static let saveRequested = Notification.Name("KaJi.saveRequested")
    static let focusSearchRequested = Notification.Name("KaJi.focusSearchRequested")
    static let exportCurrentCardRequested = Notification.Name("KaJi.exportCurrentCardRequested")
    static let exportAllCardsRequested = Notification.Name("KaJi.exportAllCardsRequested")
}
