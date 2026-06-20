//
//  NoScrollTextEditor.swift
//  KaJi
//
//  v1.6.11：替换 SwiftUI TextEditor，强制行高消除横线穿字 bug
//
//  关键设计：
//  1. NSViewRepresentable.sizeThatFits API 精确控制高度（Apple 官方，macOS 13+）
//  2. NSMutableParagraphStyle.minimumLineHeight = maximumLineHeight = 25 强制行高
//  3. isReadOnly: Bool 参数响应 v1.6.4 step6 展示态
//  4. NSTextViewDelegate.textDidChange 同步 Binding（main thread，无需 dispatch）
//

import SwiftUI
import AppKit

@MainActor
struct NoScrollTextEditor: NSViewRepresentable {

    // MARK: - 公开 API（与 SwiftUI TextEditor 行为等价）

    @Binding var text: String
    let isReadOnly: Bool
    let onChange: (String, String) -> Void

    // MARK: - NSViewRepresentable 协议

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let textView = makeTextView(coordinator: context.coordinator)

        scroll.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scroll

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        // 守护：避免循环同步导致光标跳到 0
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = !isReadOnly
        textView.isSelectable = true
    }

    // ★★★ 关键：官方 API 精确控制高度（macOS 13+）★★★
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context: Context
    ) -> CGSize? {
        guard let textView = nsView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else {
            return nil
        }

        // 强制 layoutManager 完成 layout（拿最新内容高度）
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)

        // 宽度：proposal 给具体值就用，否则用 nsView 当前宽度
        // （不能直接用 proposal.width 给 NSTextView，因为 maxWidth:.infinity 会传 .infinity 导致不换行）
        let width: CGFloat
        if let pw = proposal.width, pw > 0, pw < CGFloat.greatestFiniteMagnitude {
            width = pw
        } else {
            width = nsView.frame.width
        }

        // 高度：至少 1 行（空文本兜底），不超过 proposal
        let minHeight = KaJiMetrics.editorLineHeight
        let maxHeight: CGFloat
        if let ph = proposal.height, ph > 0, ph < CGFloat.greatestFiniteMagnitude {
            maxHeight = ph
        } else {
            maxHeight = CGFloat.greatestFiniteMagnitude
        }
        let contentHeight = max(minHeight, min(usedRect.height, maxHeight))

        return CGSize(width: width, height: contentHeight)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - 工厂方法

    private func makeTextView(coordinator: Coordinator) -> NSTextView {
        let textView = NSTextView()

        // —— 尺寸：跟随内容（四个标志位必须同时设，缺一会破）——
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        // —— 文本行为：等价 SwiftUI TextEditor 默认 ——
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = true

        // —— 视觉：透明 + 系统文字色 ——
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.insertionPointColor = .labelColor
        textView.textColor = .labelColor

        // —— 字体 ——
        textView.font = .systemFont(ofSize: 16)

        // —— ★★★ 关键：强制行高 = editorLineHeight pt ★★★ ——
        let paragraphStyle = makeParagraphStyle()
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 16),
            .paragraphStyle: paragraphStyle,
            .foregroundColor: NSColor.labelColor
        ]

        // —— Delegate：同步 binding 回 SwiftUI（main thread，无死循环）——
        textView.delegate = coordinator

        return textView
    }

    private func makeParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = KaJiMetrics.editorLineHeight
        style.maximumLineHeight = KaJiMetrics.editorLineHeight
        style.lineHeightMultiple = 1.0
        style.alignment = .left
        style.lineBreakMode = .byWordWrapping
        return style
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoScrollTextEditor
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        init(_ parent: NoScrollTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            let new = tv.string
            let old = parent.text
            guard new != old else { return }
            // main thread，无需 dispatch；NSTextView 代码设 string 不触发 textDidChange，无死循环
            parent.text = new
            parent.onChange(old, new)
        }
    }
}