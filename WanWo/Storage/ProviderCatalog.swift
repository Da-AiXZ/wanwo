//
//  ProviderCatalog.swift
//  WanWo
//
//  【m7-fix2 · E2 · M6① 预置目录下沉数据面】预置提供商表（baseUrl + 内置
//  模型 id 表），原 AddProviderFormView.swift:33-52 的 UI 静态表下沉至此。
//
//  dsh 语义出处（repos/deepseek-harness-master/packages/llm/llm-pi-ai/src/）：
//    · catalog.ts:186-190 catalogModels(provider)——按 provider id 查内置
//      目录，逐条 id 索引；未收录 provider = 空 Map；
//    · catalog.ts:799-800 defaults = catalogModels(provider) + provider 的
//      catalog baseUrl（providerBaseUrl = catalogProvider(provider)?.baseUrl）；
//    · discovery.ts:208-216 installed = catalogModels(request.provider)——
//      「获取可用模型」选项 = 用户目录 ∪ 内置目录（万我对应消费口在
//      EndpointStore.builtinCatalog + ModelSelectView 并集，只读候选语义）。
//
//  适配登记（报告详）：pi-ai 上游注册表（@earendil-works/pi-ai
//  getBuiltinModels）**不在 dsh 快照内**（仓库无 node_modules，已核实），
//  具体模型 id 无法逐行照抄。处理：
//    · DeepSeek 条目取仓库权威有效线（EndpointStore.swift:22-24 + 04
//      §5.4：deepseek-v4-flash / deepseek-v4-pro；旧 deepseek-chat/
//      deepseek-reasoner 2026-07-24 下线，禁再作示例值）；
//    · 其余预置条目按各商公开文档策展的 OpenAI 兼容 id 子集（候选语义，
//      只供挑选，绝不静默写配置——dsh ModelListEditor 口径）；
//    · baseUrl 取各商 PUBLIC_BASE_URL 语义（dsh llm-deepseek/src/index.ts:200
//      DeepSeek='https://api.deepseek.com'），与原 UI 静态表逐值一致。
//
//  红线：本文件为纯数据（零 UI、零 IO、零静默写）；iOS 16.6 无关。
//

import Foundation

/// 一条预置提供商（dsh catalogProvider + catalogModels 的万我数据形态）。
struct ProviderCatalogPreset: Equatable, Sendable {
    /// 预置 provider id（= 端点 name；dsh provider route key）。
    let id: String
    /// 端点基址（PUBLIC_BASE_URL 语义，不含 /chat/completions）。
    let baseURL: String
    /// 内置模型目录（dsh catalogModels(provider) 值序）。
    let builtinModels: [ModelCatalogEntry]
}

/// 预置提供商目录（数据面唯一来源；UI/菜单只读消费）。
enum ProviderCatalog {

    /// 预置表（OpenAI 兼容端点子集；原 AddProviderFormView.presets 逐值下沉）。
    static let presets: [ProviderCatalogPreset] = [
        preset("openai", "https://api.openai.com/v1", [
            entry("gpt-4o", "GPT-4o", image: true),
            entry("gpt-4o-mini", "GPT-4o mini", image: true),
            entry("gpt-4.1", "GPT-4.1", image: true),
            entry("o4-mini", "o4-mini"),
        ]),
        preset("deepseek", "https://api.deepseek.com", [
            // 仓库有效线（EndpointStore.swift:22-24；04 §5.4）。
            entry("deepseek-v4-flash", "DeepSeek V4 Flash"),
            entry("deepseek-v4-pro", "DeepSeek V4 Pro"),
        ]),
        preset("moonshot", "https://api.moonshot.cn/v1", [
            entry("kimi-k2-0905-preview", "Kimi K2 (0905 Preview)"),
            entry("kimi-latest", "Kimi Latest", image: true),
            entry("moonshot-v1-128k", "Moonshot v1 128K"),
        ]),
        preset("minimax-cn", "https://api.minimaxi.com/v1", [
            entry("MiniMax-Text-01", "MiniMax Text 01"),
            entry("abab6.5s-chat", "abab6.5s"),
        ]),
        preset("siliconflow", "https://api.siliconflow.cn/v1", [
            entry("deepseek-ai/DeepSeek-V3", "DeepSeek V3 (SiliconFlow)"),
            entry("Qwen/Qwen2.5-72B-Instruct", "Qwen2.5 72B"),
        ]),
        preset("groq", "https://api.groq.com/openai/v1", [
            entry("llama-3.3-70b-versatile", "Llama 3.3 70B"),
            entry("llama-3.1-8b-instant", "Llama 3.1 8B"),
        ]),
        preset("mistral", "https://api.mistral.ai/v1", [
            entry("mistral-large-latest", "Mistral Large"),
            entry("mistral-small-latest", "Mistral Small"),
        ]),
        preset("fireworks", "https://api.fireworks.ai/inference/v1", [
            entry("accounts/fireworks/models/llama-v3p3-70b-instruct",
                  "Llama 3.3 70B (Fireworks)"),
            entry("accounts/fireworks/models/deepseek-v3", "DeepSeek V3 (Fireworks)"),
        ]),
        preset("together", "https://api.together.xyz/v1", [
            entry("meta-llama/Llama-3.3-70B-Instruct-Turbo", "Llama 3.3 70B Turbo"),
            entry("deepseek-ai/DeepSeek-V3", "DeepSeek V3 (Together)"),
        ]),
        preset("openrouter", "https://openrouter.ai/api/v1", [
            entry("openrouter/auto", "Auto (OpenRouter)"),
            entry("openai/gpt-4o-mini", "GPT-4o mini (OpenRouter)"),
        ]),
        preset("google", "https://generativelanguage.googleapis.com/v1beta/openai", [
            entry("gemini-2.0-flash", "Gemini 2.0 Flash", image: true),
            entry("gemini-1.5-pro", "Gemini 1.5 Pro", image: true),
        ]),
    ]

    // MARK: 查询（dsh catalogModels(provider) 语义：未收录 = 空集）

    /// 按 provider id 查预置（大小写不敏感——端点 name 首字母形态不限）。
    static func preset(forProvider id: String) -> ProviderCatalogPreset? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return presets.first { $0.id.lowercased() == key }
    }

    /// 预置内置模型目录（dsh catalogModels：未收录 = 空集；候选语义只读）。
    static func builtinModels(forProvider id: String) -> [ModelCatalogEntry] {
        preset(forProvider: id)?.builtinModels ?? []
    }

    // MARK: 构造辅助

    private static func preset(_ id: String, _ baseURL: String,
                               _ models: [ModelCatalogEntry]) -> ProviderCatalogPreset {
        ProviderCatalogPreset(id: id, baseURL: baseURL, builtinModels: models)
    }

    /// 目录项快捷构造（inputModalities nil = 缺省 ["text"] 继承语义）。
    private static func entry(_ id: String, _ name: String? = nil,
                              context: Int? = nil, maxTokens: Int? = nil,
                              image: Bool = false) -> ModelCatalogEntry {
        ModelCatalogEntry(
            id: id,
            name: name,
            description: nil,
            contextWindow: context,
            maxTokens: maxTokens,
            inputModalities: image ? ["text", "image"] : nil)
    }
}
