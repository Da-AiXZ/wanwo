//
//  TurnNavigatorRailView.swift
//  WanWo
//
//  【批3 C⑧ 新写】轮次导航轨道（dsh ui TurnNavigator.tsx——审计矩阵 §3 语义）：
//    · 右缘刻度轨道：每轮（user 消息起轮）一枚刻度；TURN_SPACING_PX=10 固定
//      间距、RAIL_INSET_PX=6 内缩（TurnNavigator.tsx 常量锚点；FADE_PX=24 渐隐
//      形态随触屏省略不落）；
//    · 点按刻度跳轮（iPad 触屏=点按；悬停预览 previewTurn 降级省略——触屏
//      无 hover，登记报告）；
//    · 轮锚解析 = TurnNavigator.turnAnchors 纯函数（单测直呼，简报 D）。
//

import SwiftUI

/// 轮锚（一轮 = 一次 user 消息起头；锚点 bubble id 供 ScrollViewReader.scrollTo）。
struct TurnAnchor: Equatable {
    /// 轮序号（0 起——dsh turn 下标口径）。
    let turn: Int
    /// 该轮起始 user 气泡 id（滚动锚）。
    let bubbleID: String
}

enum TurnNavigator {
    /// 轨道可见性（≥2 轮才出轨道——单轮无导航价值）。
    nonisolated static func shouldShowRail(anchorCount: Int) -> Bool {
        anchorCount >= 2
    }

    /// 纯函数：平铺 bubbles → 轮锚序列（每枚 user 气泡开启新一轮——dsh
    /// TurnNavigator.tsx turn 划分语义；marker 包装消息不渲染用户气泡，
    /// 防御性双滤）。
    nonisolated static func turnAnchors(
        in bubbles: [ConversationProjector.Bubble]) -> [TurnAnchor] {
        var anchors: [TurnAnchor] = []
        var turn = 0
        for bubble in bubbles {
            if case .user(let text, _) = bubble.kind,
               !ConversationProjector.isMarkerMessage(text) {
                anchors.append(TurnAnchor(turn: turn, bubbleID: bubble.id))
                turn += 1
            }
        }
        return anchors
    }
}

/// 右缘轮次导航轨道（批3 C⑧；挂 ChatView 消息流 ScrollView trailing overlay）。
struct TurnNavigatorRailView: View {
    let anchors: [TurnAnchor]
    /// 点按跳轮回调（ChatView 内接 ScrollViewReader.proxy.scrollTo）。
    let onJump: (TurnAnchor) -> Void

    var body: some View {
        if TurnNavigator.shouldShowRail(anchorCount: anchors.count) {
            // dsh TurnNavigator.tsx：TURN_SPACING_PX=10 / RAIL_INSET_PX=6。
            VStack(spacing: 10) {
                ForEach(anchors, id: \.bubbleID) { anchor in
                    Button {
                        onJump(anchor)
                    } label: {
                        Capsule()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 14, height: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                    .accessibilityLabel("跳到第 \(anchor.turn + 1) 轮")
                }
            }
            .padding(.vertical, 8)
            .transition(.opacity)
        }
    }
}
