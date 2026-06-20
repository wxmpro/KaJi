//
//  SearchToolbarField.swift
//  KaJi
//
//  顶部工具栏居中搜索框。
//  用 NSSearchField 包装为 NSViewRepresentable，放入 toolbar 的 .principal
//  位置，实现「返回-左 / 搜索-中 / 删除-右」布局。
//

import SwiftUI

struct SearchToolbarField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.bezelStyle = .roundedBezel
        field.isBordered = true
        field.focusRingType = .default

        // 固定搜索框高度，避免太扁
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.heightAnchor.constraint(equalToConstant: 28)
        ])

        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String
        let onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self._text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            text = field.stringValue
        }

        @objc func submit(_ sender: NSSearchField) {
            onSubmit()
        }
    }
}
