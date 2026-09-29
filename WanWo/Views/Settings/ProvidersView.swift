//
//  ProvidersView.swift
//  WanWo
//
//  【m8 批1 A2 · 薄壳】旧 371 行 Providers UI（按设计新写 §7.2 + 批3 B 增强）
//  已由 dsh ui-settings-models 语义翻译件整块替换（WanWo/UI/Settings/Models/
//  ProvidersSectionView.swift 一族——ModelsSection/ProviderEditor/
//  DeepSeekModelsEditor/CustomProviderCard 交互骨架 1:1，见 analysis/m8-fix/
//  a2-report.md 组件×dsh 锚点对照表）。
//
//  本文件仅保留旧挂点名（SettingsPanelView contentBody 路由既有引用面），
//  内部转发新分区视图——旧 EndpointEditSheet/sheet 槽/引导 gate 逻辑随之退役
//  （引导卡/删除确认/key 状态点/saved 提示均由新分区视图承载）。
//

import SwiftUI

struct ProvidersView: View {
    @ObservedObject private var environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var body: some View {
        ProvidersSectionView(store: environment.endpointStore)
    }

    /// 删除确认两版描述（批3 B3 既有纯函数——UIBatch3Tests 直呼面，语义
    /// 不变；新分区视图内部同文案由 ProvidersSectionView.deleteMessage 承载）。
    nonisolated static func deleteMessage(for endpoint: EndpointConfig,
                                          hasCredential: Bool) -> String {
        hasCredential
            ? "「\(endpoint.name)」已配置 API Key，删除将一并清除凭据，且无法恢复。"
            : "删除端点「\(endpoint.name)」？此操作无法恢复。"
    }
}
