//
//  ModelSelectView.swift
//  WanWo
//
//  【dsh Web UI 原件移植 · M3 T2.2】composer 模型挡位（T2.2 派单项 11）。
//  出处（packages/client/ui-model-selection/src/client/ModelSelect.tsx）：
//    - :1-13 头注 —— composer 的命名模型座位（conversation.input.model）；
//      figma 496:26454 两级 MenuDropdown：根菜单 = Model / Effort 行对各钻入
//      自己的列表；触发器显示模型名（+ effort 说明字号）。
//    - 数据与提交走与 /model 弹层同一 per-session ModelDirectory（:8-9）——
//      WanWo 对应 = EndpointStore（单一直一源）；拒绝选择以 Toast 宣告（:12）。
//  T2.2 派单注记：Effort 级可后置 → 根菜单仅模型列表一级（二级钻入缺席，
//  形态偏差登记）；WanWo 目录 = 启用端点集，选择 = setActive（下一请求即用，
//  AgentLoop makeAdapter 按调用时 activeEndpoint 取用）。
//

import SwiftUI

/// composer 模型挡位（触发器 = 模型名 + chevron；菜单 = 启用端点列表）。
struct ModelSelectView: View {
    @ObservedObject var store: EndpointStore
    /// 选择回传（VM 更新标签；下一请求起生效）。
    let onSelect: (EndpointConfig) -> Void

    @State private var open = false

    private var active: EndpointConfig? { store.activeEndpoint() }

    var body: some View {
        Menu {
            // 模型列表（dsh provider-grouped：以端点 name 为组——WanWo 组 = 端点）。
            ForEach(store.endpoints.filter(\.isEnabled)) { endpoint in
                Button {
                    onSelect(endpoint)
                } label: {
                    HStack {
                        Text("\(endpoint.name) · \(endpoint.model)")
                        if endpoint.id == active?.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            // 触发器：模型名 + chevron（effort 说明字号caption——Effort 后置）。
            HStack(spacing: 4) {
                Text(active?.model ?? "未选择模型")
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(.tertiarySystemFill))
            .clipShape(Capsule())
        }
        .accessibilityLabel("模型选择，当前：\(active?.model ?? "未选择")")
    }
}
