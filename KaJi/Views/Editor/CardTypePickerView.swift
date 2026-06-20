//
//  CardTypePickerView.swift
//  KaJi
//
//  卡片类型选择器（内联浮动层）。
//

import SwiftUI

struct CardTypePickerView: View {
    let selectedType: CardType
    let onSelect: (CardType) -> Void

    var body: some View {
        // 横向 ScrollView：水平方向可压缩，不再以固有宽度（N×46pt）撑破宿主卡片。
        // 窗口变窄时类型条贴合卡片宽度、靠左排列，溢出部分横向滑动可见。
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CardType.allCases) { type in
                        Button {
                            onSelect(type)
                        } label: {
                            VStack(spacing: 4) {
                                Circle()
                                    .fill(type.color)
                                    .frame(width: 7, height: 7)
                                Text(type.rawValue)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .frame(width: 46, height: 42)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selectedType == type ? KaJiColor.systemSelected : Color.clear)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .id(type)
                    }
                }
                // 选中态圆角背景不被 ScrollView 边缘裁切
                .padding(.horizontal, 2)
            }
            // 打开时滚动到当前选中类型，保证窄窗口下高亮项可见
            .onAppear {
                proxy.scrollTo(selectedType, anchor: .center)
            }
        }
    }
}
