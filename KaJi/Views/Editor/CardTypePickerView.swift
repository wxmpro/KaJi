//
//  CardTypePickerView.swift
//  KaJi
//
//  卡片类型选择器（内联浮动层）。
//

import SwiftUI

struct CardTypePickerView: View {
    let selectedTypeId: String
    let onSelect: (String) -> Void

    var body: some View {
        // 横向 ScrollView：水平方向可压缩，不再以固有宽度（N×46pt）撑破宿主卡片。
        // 窗口变窄时类型条贴合卡片宽度、靠左排列，溢出部分横向滑动可见。
        // 类型集合与侧栏展示集合 `registry.sidebarVisible` 保持一致（数量、顺序相同）。
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CardTypeRegistry.shared.sidebarVisible) { typeDef in
                        Button {
                            onSelect(typeDef.id)
                        } label: {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(typeDef.color)
                                    .frame(width: 7, height: 7)
                                Text(typeDef.name)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .frame(width: 46, height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedTypeId == typeDef.id ? KaJiColor.systemSelected : Color.clear)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .id(typeDef.id)
                    }
                }
                // 选中态圆角背景不被 ScrollView 边缘裁切
                .padding(.horizontal, 2)
            }
            // 打开时滚动到当前选中类型，保证窄窗口下高亮项可见
            .onAppear {
                proxy.scrollTo(selectedTypeId, anchor: .center)
            }
        }
    }
}
