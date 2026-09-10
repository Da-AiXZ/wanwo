//
//  ModelSelectView.swift
//  WanWo
//
//  【dsh Web UI 原件移植 · M3 T2.2 / P2-⑧ / T2.4 P1-3】composer 模型挡位两级菜单。
//  出处（packages/client/ui-model-selection/src/client/ModelSelect.tsx）：
//    - :1-13 头注 —— composer 的命名模型座位（conversation.input.model）；
//      figma 496:26454 两级 MenuDropdown：根菜单 = Model / Effort 行对各钻入
//      自己的列表（:248-263 root pane 两行：label + 当前值 + 右 chevron）；
//      触发器显示模型名（+ effort 说明字号 :235-236）。
//    - model pane（:265-319）—— provider 分组列表（section + groupTitle），
//      选中行 checkmark（menuitemradio）。
//    - effort pane（:321-351）—— effort 等级单选；provider default 行
//      （:92-94 defaultEffort 缺席时首行 = provider default）。
//    - state.current = per-session ModelSelection（:48-51 会话目录快照——
//      T2.4 P1-3：WanWo 对应 = SessionModelSelection 会话级内存态，切会话
//      各归各；App 级缺省 = 活动端点）。
//    - 文案逐字（locales.ts:15-30 zh）：trigger.fallback「选择模型」、
//      menu.model「模型」、menu.effort「推理等级」、
//      effort.providerDefault「Default」（zh 亦为 Default 字面）、
//      empty.models「没有可用的模型。」。
//    - :250-261 root pane 行右 chevron 由 MenuDropdown 组件自带——SwiftUI
//      Menu 嵌套子菜单亦自带指示器，本视图不再自绘（T2.4 P1-③ 双 chevron
//      修复）；触发器 chevron.down 保留（dsh :237 IconChevronDown）。
//  WanWo 偏差登记：
//    1. 两级形态 = SwiftUI Menu 嵌套子菜单，非 dsh 自绘 pane 钻入（P2 登记）。
//    2. effort 词汇 = 部署方 DeepSeek 扩展透传（09 #16：off|low|high|max，
//       ProvidersView 同表）+ provider default；dsh 的 per-model reasoning
//       元数据由 Host 广播——WanWo 无 Host 目录，词汇静态（P2 登记）。
//

import SwiftUI

/// composer 模型挡位（触发器 = 模型名（· effort）；菜单 = 模型 / 推理等级两级）。
struct ModelSelectView: View {
    @ObservedObject var store: EndpointStore
    /// 当前生效端点（会话选择优先，缺省 = 活动端点；VM published 镜像）。
    let current: EndpointConfig?
    /// 当前会话 effort（nil = provider default）。
    let currentEffort: String?
    /// 模型选择回传（会话级选择；下一请求起生效）。
    let onSelect: (EndpointConfig) -> Void
    /// 推理等级选择回传（nil = provider default 不透传）。
    let onEffort: (String?) -> Void

    // MARK: - effort 词汇（09 #16；与 ProvidersView 同表，静态偏差登记）

    /// dsh effortChoices（ModelSelect.tsx:89-100）：provider default 首行 + 等级集。
    private struct EffortChoice {
        let effort: String?
        let label: String
    }

    private static let effortChoices: [EffortChoice] = [
        EffortChoice(effort: nil, label: "Default"),
        EffortChoice(effort: "off", label: "off"),
        EffortChoice(effort: "low", label: "low"),
        EffortChoice(effort: "high", label: "high"),
        EffortChoice(effort: "max", label: "max"),
    ]

    /// effort 展示值（dsh :83-88 effectiveEffort → 名称；无 → providerDefault）。
    private var effortLabel: String {
        guard let effort = currentEffort else { return "Default" }
        return Self.effortChoices.first { $0.effort == effort }?.label ?? effort
    }

    /// 启用端点按 provider（端点 name）分组（dsh :283-313 provider 分组语义）。
    private var groups: [(name: String, endpoints: [EndpointConfig])] {
        let enabled = store.endpoints.filter(\.isEnabled)
        var order: [String] = []
        var buckets: [String: [EndpointConfig]] = [:]
        for endpoint in enabled {
            if buckets[endpoint.name] == nil { order.append(endpoint.name) }
            buckets[endpoint.name, default: []].append(endpoint)
        }
        return order.map { (name: $0, endpoints: buckets[$0] ?? []) }
    }

    var body: some View {
        Menu {
            // 根菜单行 1 =「模型」→ 钻入 provider 分组列表（dsh :250-253；
            // 行右指示器 = Menu 自带，不再自绘——T2.4 P1-③）。
            Menu {
                ForEach(groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.endpoints) { endpoint in
                            Button {
                                onSelect(endpoint)
                            } label: {
                                HStack {
                                    Text(endpoint.model)
                                    if endpoint.id == current?.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
                if groups.allSatisfy({ $0.endpoints.isEmpty }) {
                    Text("没有可用的模型。")
                }
            } label: {
                HStack {
                    Text("模型")
                    Spacer()
                    Text(current?.model ?? "选择模型")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 根菜单行 2 =「推理等级」→ 钻入等级列表（dsh :255-261，effort 行）。
            Menu {
                ForEach(Self.effortChoices, id: \.effort) { choice in
                    Button {
                        onEffort(choice.effort)
                    } label: {
                        HStack {
                            Text(choice.label)
                            if currentEffort ?? nil == choice.effort {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    Text("推理等级")
                    Spacer()
                    Text(effortLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            // 触发器（dsh :235-237）：模型名（effort 以说明字号随行）+ chevron。
            HStack(spacing: 4) {
                Text(current?.model ?? "未选择模型")
                    .font(.caption)
                    .lineLimit(1)
                if currentEffort != nil {
                    Text(effortLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(.tertiarySystemFill))
            .clipShape(Capsule())
        }
        .accessibilityLabel("选择模型，当前 \(current?.model ?? "未选择")，推理等级 \(effortLabel)")
    }
}
