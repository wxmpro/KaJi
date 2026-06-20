//
//  SidebarRow.swift
//  KaJi
//
//  侧边栏统一行组件。
//

import SwiftUI

struct SidebarRow: View {
    enum Style { case large, small }

    @Environment(EditorDataState.self) private var data
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let icon: String
    let iconColor: Color
    var symbolRenderingMode: SymbolRenderingMode? = nil
    let count: Int?
    let isSelected: Bool
    var style: Style = .large
    var action: () -> Void

    private var iconSize: CGFloat { style == .large ? 16 : 9 }
    private var iconWeight: Font.Weight { style == .large ? .regular : .semibold }
    private var fontSize: CGFloat   { style == .large ? 15 : 13 }
    private var hSpacing: CGFloat   { style == .large ? 10 : 8 }
    private var vPadding: CGFloat   { style == .large ? 6 : 4 }
    private var hPadding: CGFloat   { 16 }
    private var iconFrame: CGFloat  { style == .large ? 22 : 18 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: hSpacing) {
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: iconWeight))
                    .symbolRenderingMode(symbolRenderingMode)
                    .foregroundStyle(iconColor)
                    .frame(width: iconFrame, alignment: .center)

                Text(title)
                    .font(.system(size: fontSize))
                    .lineLimit(1)

                if let count {
                    Spacer(minLength: 8)

                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, vPadding)
            .padding(.horizontal, hPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(colorScheme: colorScheme))
        .contextMenu {
            Button("新建卡片") {
                data.startNewDraft(type: .free)
            }
        }
    }
}
