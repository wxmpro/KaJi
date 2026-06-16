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
            }
        }
    }
}
