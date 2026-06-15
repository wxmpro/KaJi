//
//  DetailView.swift
//  KaJi
//
//  右侧详情区：根据 rightPaneMode 切换 editor / list。
//

import SwiftUI

struct DetailView: View {
    @EnvironmentObject var listState: ListState

    var body: some View {
        ZStack {
            // 窗口背景色，覆盖 titlebar 区域防止全屏黑条
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea(.all)

            // 主体
            switch listState.rightPaneMode {
            case .editor:
                NotesEditor()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .list:
                CardListView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 右上角搜索浮层
            SearchOverlay()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, KaJiLayout.headerTopPadding)
                .padding(.trailing, KaJiLayout.searchTrailingPadding)
                .offset(y: KaJiLayout.headerTopOffset)
        }
    }
}
