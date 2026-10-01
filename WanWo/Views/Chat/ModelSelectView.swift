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
//    3. 【M8 批1 件A4】模型层扩为 endpoint → 模型两级（目录 = 端点 models
//       + 继承缺省项，dsh ui-model-selection per-session 目录语义；选择 =
//       会话级 modelID 覆盖，EndpointStore.resolve 应用——下一请求生效、
//       运行中 step 不变）。目录空 = 单模型现状行为（catalogEntries 兜底）。
//

import SwiftUI

/// composer 模型挡位（触发器 = 模型名（· effort）；菜单 = 模型 / 推理等级两级）。
struct ModelSelectView: View {
    @ObservedObject var store: EndpointStore
    /// 当前生效端点（会话选择优先，缺省 = 活动端点；VM published 镜像——
    /// M8 件A4：resolve 已应用会话 modelID 覆盖，current.model 即当前模型）。
    let current: EndpointConfig?
    /// 当前会话 effort（nil = provider default）。
    let currentEffort: String?
    /// 模型选择回传（会话级选择；两级 endpoint → 模型，M8 件A4——
    /// dsh ui-model-selection：选择下一请求生效、运行中 step 不变）。
    let onSelect: (EndpointConfig, String) -> Void
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

    /// 目录数据源（m7-fix2 M6③；dsh discovery.ts:208-216 installed 语义）：
    /// 端点用户目录 ∪ 该端点预置内置目录（ProviderCatalog 只读候选）。
    /// 去重保序、用户目录优先；只读候选——**绝不静默写配置**（dsh
    /// ModelListEditor 口径：内置 id 仅供挑选发送，不回写 endpoint.models）。
    private func mergedEntries(for endpoint: EndpointConfig) -> [ModelCatalogEntry] {
        var seen = Set<String>()
        var merged: [ModelCatalogEntry] = []
        for entry in endpoint.catalogEntries() + store.builtinCatalog(for: endpoint) {
            if seen.insert(entry.id).inserted { merged.append(entry) }
        }
        return merged
    }

    /// 触发器模型显示名（M8 件A4：目录项 name 优先，缺省 = id——
    /// dsh modelInfo name ?? id 语义；M6③：并集目录内解析）。
    private var currentModelLabel: String? {
        guard let current else { return nil }
        return mergedEntries(for: current).first { $0.id == current.model }?.name ?? current.model
    }

    /// 悬停底色（指针场景增强；触屏无 hover——触屏纪律）。
    @State private var hovering = false

    var body: some View {
        Menu {
            // 根菜单行 1 =「模型」→ 钻入 provider 分组列表（dsh :250-253；
            // 行右指示器 = Menu 自带，不再自绘——T2.4 P1-③）。
            // M8 批1 件A4：endpoint → 模型两级（dsh ui-model-selection
            // per-session 目录语义——目录 = 端点 models + 继承缺省项；
            // 目录空 = 单模型现状行为，catalogEntries 兜底 endpoint.model）。
            Menu {
                ForEach(groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.endpoints) { endpoint in
                            Menu {
                                // M6③：目录 = 用户目录 ∪ 预置内置目录（去重）。
                                ForEach(mergedEntries(for: endpoint), id: \.id) { entry in
                                    Button {
                                        onSelect(endpoint, entry.id)
                                    } label: {
                                        HStack {
                                            Text(entry.name ?? entry.id)
                                            if endpoint.id == current?.id,
                                               entry.id == current?.model {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(endpoint.displayName ?? endpoint.name)
                                    Spacer()
                                    Text(endpoint.model)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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
                    Text(currentModelLabel ?? "选择模型")
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
            // 触发器（原型 .model-pill：透明平底 28px r8、13px/500、chevron 12、
            // hover 显灰；effort 只在菜单内呈现——pill 只显模型名；
            // 2026-09-21 旧 UI 灰底胶囊皮退役）。
            HStack(spacing: 4) {
                Text(currentModelLabel ?? "选择模型")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(WOAlias.labelSecondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? WOAlias.interactiveBgHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .woPressable()
        .onHover { hovering = $0 }
        .accessibilityLabel("选择模型，当前 \(currentModelLabel ?? "未选择")，推理等级 \(effortLabel)")
    }
}
