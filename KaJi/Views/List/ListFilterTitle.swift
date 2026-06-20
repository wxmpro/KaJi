//
//  ListFilterTitle.swift
//  KaJi
//
//  列表区域上方的筛选标题。
//

import SwiftUI

struct ListFilterTitle: View {
    @Environment(ListState.self) private var listState

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(listState.listFilterTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.primary)

            Spacer()

            Text("\(listState.cachedFilteredCards.count) 张卡片")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
