//
//  ContextMeterView.swift
//  WanWo
//
//  【dsh Web UI 原件移植 · M3 T2.2 / P2-⑦】composer 上下文占用环。
//  出处（packages/client/ui-conversation/src/client/skeleton/ContextMeter.tsx）：
//    - :106-128 —— 14px 触发环：track 底环 + fill 按 percent strokeDasharray
//      （SwiftUI 等义 = Circle().trim(from:0, to:percent)，rotate(-90) 从顶起）；
//      aria =「上下文已用 {percent}%」（locales.ts:49 逐字）。
//    - :130-165 —— 点击面板：header（上下文已用 + N% + ~used/threshold）+
//      breakdown 分解条（:142-150，段宽 = percent × tokens/total，零宽段剔除；
//      total = 0 → 单一整段）+ dl 行（:151-163，swatch + label + ~value）。
//    - ROWS（:28-32）段序 = system / tools / messages；zh 标签逐字
//      （ui-conversation locales.ts:51-53：系统提示词 / 工具 / 对话消息）。
//    - 段色（ContextMeter.module.css:117-127 原值）：system =
//      --dsw-static-neutral-bluish-400 = rgb(173,178,184)；tools =
//      rgb(167,139,250)（design 平台无紫 token，violet-400 字面值）；
//      messages = --dsw-static-blue-450 = rgb(77,147,248)。
//    - :60-64 —— 无压力数据时整体不渲染（context === null → null）。
//  数据：Compactor.PressureInfo（P1-5 窗口占比口径 + P2-⑦ breakdown 三段）。
//

import SwiftUI

/// 上下文占用环 + 构成面板（数据 = Compactor.PressureInfo）。
struct ContextMeterView: View {
    let pressure: Compactor.PressureInfo

    @State private var open = false

    // MARK: - 段表（dsh ContextMeter.tsx:28-32 ROWS + module.css:117-127 色值）

    private struct Row: Identifiable {
        let id: String
        let label: String
        let color: Color
        let tokens: Int
    }

    /// 段序与色值 = dsh ROWS 原件；tokens = breakdown 对应段。
    private var rows: [Row] {
        [
            Row(id: "system", label: "系统提示词",
                color: Color(red: 173 / 255, green: 178 / 255, blue: 184 / 255),
                tokens: pressure.breakdown.systemTokens),
            Row(id: "tools", label: "工具",
                color: Color(red: 167 / 255, green: 139 / 255, blue: 250 / 255),
                tokens: pressure.breakdown.toolsTokens),
            Row(id: "messages", label: "对话消息",
                color: Color(red: 77 / 255, green: 147 / 255, blue: 248 / 255),
                tokens: pressure.breakdown.messageTokens),
        ]
    }

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

    /// 分解段（dsh :98-104：宽 = percent × tokens/total；零宽段剔除；
    /// total = 0 或缺 breakdown → 单一整段占满 percent）。
    private var segments: [(id: String, color: Color?, width: Double)] {
        let rows = rows
        let total = rows.reduce(0) { $0 + $1.tokens }
        guard total > 0 else {
            return [(id: "total", color: nil, width: Double(percent))]
        }
        return rows.map { row in
            (id: row.id, color: row.color,
             width: Double(percent) * Double(row.tokens) / Double(total))
        }.filter { $0.width > 0 }
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
            // 面板（dsh :130-165：header + 分解条 + dl 行）。
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("上下文已用")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("\(percent)%")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(percentColor)
                    Spacer()
                    Text("~\(SessionStatsFold.formatTokens(pressure.usedTokens)) / "
                        + "\(SessionStatsFold.formatTokens(pressure.contextWindow))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                // 分解条（dsh :142-150 .bar：track 底 + 按 percent×构成比例着色段）。
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.tertiarySystemFill))
                        HStack(spacing: 1) {
                            ForEach(segments, id: \.id) { segment in
                                Rectangle()
                                    .fill(segment.color ?? Color(.systemGray4))
                                    .frame(width: max(0, geo.size.width
                                            * segment.width / 100))
                            }
                        }
                        .clipShape(Capsule())
                    }
                }
                .frame(height: 6)
                // dl 行（dsh :151-163：swatch + label + ~value；三行恒在——
                // breakdown 三段=启发式构成（dsh projection.ts:50-57 明示不求和
                // 等于锚定值，只呈现构成近似；头行 used=usage 锚点投影 T2.4 P0-2）。
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(row.color)
                                    .frame(width: 8, height: 8)
                                Text(row.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("~\(SessionStatsFold.formatTokens(row.tokens))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 280, alignment: .leading)
        }
    }
}
