//
//  SidebarRow.swift
//  KaJi
//
//  侧边栏统一行组件。
//

import SwiftUI

struct SidebarRow: View {
    enum Style { case large, small }

    // v1.3.3 PATCH：editorState 注入移除。data 已是 EnvironmentObject。
    @EnvironmentObject var data: EditorDataState
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let icon: String
    let iconColor: Color
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
            // v1.3.3 PATCH：editorState 注入移除，data 直连
            Button("新建卡片") {
                data.startNewCard(type: .free)
            }
        }
    }
}
