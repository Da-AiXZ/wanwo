//
//  ContextMeterView.swift
//  WanWo
//
//  【dsh Web UI 原件移植 · M3 T2.2】composer 上下文占用环（T2.2 派单项 9）。
//  出处（packages/client/ui-conversation/src/client/skeleton/ContextMeter.tsx）：
//    - :106-128 —— 14px 触发环：track 底环 + fill 按 percent strokeDasharray
//      （SwiftUI 等义 = Circle().trim(from:0, to:percent)，rotate(-90) 从顶起）；
//      aria =「上下文已用 {percent}%」。
//    - :130-165 —— 点击面板：header（上下文已用 + N% + ~used/threshold）+
//      breakdown 分解条；T2.2 派单「点击面板可先只显占比（breakdown 分解可
//      后置）」→ 面板呈现占比 + 用量，分解行缺席。
//    - :60-64 —— 无压力数据时整体不渲染（context === null → null）。
//

import SwiftUI

/// 上下文占用环 + 占比面板（数据 = Compactor.PressureInfo）。
struct ContextMeterView: View {
    let pressure: Compactor.PressureInfo

    @State private var open = false

    /// 占比整数（0-100；dsh contextOccupancy：min(100, round(used/window×100))，
    /// 分母 = 模型上下文窗——Math.round 语义，非截断）。
    private var percent: Int {
        guard pressure.contextWindow > 0 else { return 0 }
        let raw = Double(pressure.usedTokens) / Double(pressure.contextWindow) * 100
        return min(100, Int(raw.rounded()))
    }

    private var percentColor: Color {
        if pressure.contextWindow > 0,
           Double(pressure.usedTokens) / Double(pressure.contextWindow) >= 1 {
            return .red
        }
        return .accentColor
    }

    var body: some View {
        // 触发环（14px；fill 从顶部顺时针——dsh rotate(-90) 语义）。
        Button {
            open.toggle()
        } label: {
            ZStack {
                Circle()
                    .stroke(Color(.tertiarySystemFill), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.01, Double(percent) / 100))
                    .stroke(percentColor, lineWidth: 2)
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("上下文已用 \(percent)%")
        .popover(isPresented: $open, arrowEdge: .top) {
            // 占比面板（breakdown 分解行可后置——T2.2 派单项 9 注记）。
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("上下文已用")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("\(percent)%")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(percentColor)
                }
                Text("~\(SessionStatsFold.formatTokens(pressure.usedTokens)) / "
                    + "\(SessionStatsFold.formatTokens(pressure.contextWindow))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: 260, alignment: .leading)
        }
    }
}
