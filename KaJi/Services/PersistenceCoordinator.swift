//
//  PersistenceCoordinator.swift
//  KaJi
//
//  自动保存调度：负责 debounce / flush / cancel。
//  真正的写盘与统计刷新委托给 CardService，这里只管理时间窗口。
//

import Foundation

@MainActor
final class PersistenceCoordinator {
    private var saveWorkItem: DispatchWorkItem?
    private static let saveDebounceInterval: TimeInterval = 0.8

    /// 防抖保存：取消上一个 pending 任务，延迟 interval 后执行
    func debounce(action: @escaping () -> Void) {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { action() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounceInterval, execute: work)
    }

    /// 立即落库：取消 pending 并立刻执行
    func flush(action: @escaping () -> Void) {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        action()
    }
}
