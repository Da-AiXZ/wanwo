//
//  ModelCatalog.swift
//  WanWo
//
//  【语义移植 · dsh · M8 批1 件A1】模型目录契约 + 归一化 + 窗口解析链。
//  出处（dsh 快照 repos/deepseek-harness-master/）：
//    - packages/llm/llm-deepseek/src/adapter.ts:49-66（DeepSeekCatalogModel
//      字段词汇：id 必填 / name? / description? / contextWindow? / maxTokens? /
//      inputModalities?——本文件 ModelCatalogEntry 1:1，image 请求限幅字段
//      不做：万我 OpenAICompatAdapter 无 imagePixelBudget 消费面，登记）；
//    - packages/llm/llm-deepseek/src/index.ts:214-280（resolveModels：id 非空
//      / name 非空 / 容量正整数 / modalities 非空且仅 text|image / id 去重；
//      万我按派单语义在归一化时 trim id——UI 粘贴残留永不参与匹配）；
//    - packages/llm/llm-deepseek/src/adapter.ts:393-430（modelInfoFor 唯一
//      解析入口：configured?.contextWindow ?? connection.defaultContextWindow；
//      defaultMaxTokens = configured?.maxTokens ?? connection.maxTokens）；
//    - packages/llm/llm-pi-ai/src/catalog.ts:866-873（resolveRouteModels
//      同构链：entry ?? base ?? request.defaultContextWindow，正整数防线）；
//    - adapter.ts:140/:142（DEFAULT_CONTEXT_WINDOW 1_000_000 /
//      DEFAULT_MAX_TOKENS 256_000）。
//  平台适配登记：dsh DEFAULT_MODELS 为 DeepSeek 专属内置目录——万我 BYOK
//  场景端点任意，内置缺省目录 = 空集起步（纯自定义；登记为架构差异而非缺失，
//  见派单简报 §一件A1）。UI 侧行级校验在 A2 的 ModelCatalogValidation
//  （WanWo/UI/Settings/Models/CapacityFormatting.swift），本文件不重复。
//


import Foundation

/// 内置缺省（dsh adapter.ts:140/:142 常量逐值）。
enum ModelCatalogDefaults {
    /// 缺省合并上下文窗（dsh DEFAULT_CONTEXT_WINDOW = 1_000_000）。
    static let contextWindow = 1_000_000
    /// 缺省单次输出上限（dsh DEFAULT_MAX_TOKENS = 256_000）。
    static let maxTokens = 256_000
    /// 缺省请求模态（dsh inputModalities default ['text']，index.ts:172）。
    static let inputModalities = ["text"]
    /// 合法模态集（dsh MODEL_MODALITIES，index.ts:115）。
    static let modalities: Set<String> = ["text", "image"]
}

// MARK: - 契约类型（冻结接口；A2 的 UI 并行施工按此签名消费，禁改名）

/// 一条模型目录项（dsh DeepSeekCatalogModel 词汇 1:1；image 限幅两字段
/// 不做——登记见文件头注）。
struct ModelCatalogEntry: Codable, Equatable, Sendable {
    /// 必填非空（resolveModels 语义：trim 后去重）。
    var id: String
    /// nil → UI 显示用 id（dsh name ?? id）。
    var name: String?
    var description: String?
    /// nil → 继承 endpoint 缺省窗口。
    var contextWindow: Int?
    /// nil → 继承 endpoint 缺省 maxTokens。
    var maxTokens: Int?
    /// 缺省 ["text"]（dsh inputModalities 缺席语义）。
    var inputModalities: [String]?
}

// MARK: - 归一化（dsh resolveModels 语义）

/// resolveModels 归一化失败（dsh index.ts 各 throw 分支的 Swift 形态：
/// 稳定 code + 行位置/模型 id 诊断）。
struct ModelCatalogResolveError: Error, Equatable, Sendable {
    var code: String
    var message: String
}

/// 模型目录命名空间（解析链唯一入口；dsh modelInfoFor 的万我承载）。
enum ModelCatalog {

    /// 生产落盘门（P2-1 收口，review batch1）：非抛归一化——id trim、空 id 行
    /// 丢弃、trim 后去重保序、非正容量清 nil（回落继承链）。resolveModels
    /// （抛错严格面）保留给 UI 行级校验/测试；本函数是 EndpointStore
    /// add/update 落盘前的唯一归一化点（dsh 分层语义：UI validate 层 +
    /// 运行侧 resolve 层，万我以存储门承载运行侧）。
    static func sanitized(_ models: [ModelCatalogEntry]) -> [ModelCatalogEntry] {
        var seen = Set<String>()
        var resolved: [ModelCatalogEntry] = []
        for var model in models {
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            model.id = id
            if let window = model.contextWindow, window <= 0 { model.contextWindow = nil }
            if let maxTokens = model.maxTokens, maxTokens <= 0 { model.maxTokens = nil }
            resolved.append(model)
        }
        return resolved
    }

    /// 归一化用户目录（dsh index.ts:214-280 resolveModels 语义裁剪到万我
    /// 字段集）：id trim 非空 / name 非空 / 容量正整数 / modalities 非空且仅
    /// text|image 不重复 / trim 后 id 去重。nil = 继承内置缺省（万我 = 空
    /// 集起步，登记）由调用方先行展开，本函数恒收显式数组。
    static func resolveModels(_ models: [ModelCatalogEntry]) throws -> [ModelCatalogEntry] {
        var seen = Set<String>()
        var resolved: [ModelCatalogEntry] = []
        for (index, model) in models.enumerated() {
            // 派单语义：trim 后去重（dsh UI 校验同口径比较 :99-105；dsh 运行
            // 侧 resolveModels 不 trim，万我在归一化层收口——一处落定）。
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty {
                throw ModelCatalogResolveError(
                    code: "MODEL_ID_REQUIRED",
                    message: "catalog model at index \(index) has an empty id")
            }
            if let name = model.name, name.isEmpty {
                throw ModelCatalogResolveError(
                    code: "MODEL_NAME_INVALID",
                    message: "catalog model \"\(id)\" has an empty name")
            }
            if let window = model.contextWindow, window <= 0 {
                throw ModelCatalogResolveError(
                    code: "MODEL_CONTEXT_INVALID",
                    message: "catalog model \"\(id)\" contextWindow must be a positive integer")
            }
            if let maxTokens = model.maxTokens, maxTokens <= 0 {
                throw ModelCatalogResolveError(
                    code: "MODEL_MAX_TOKENS_INVALID",
                    message: "catalog model \"\(id)\" maxTokens must be a positive integer")
            }
            let modalities = model.inputModalities ?? ModelCatalogDefaults.inputModalities
            if modalities.isEmpty {
                throw ModelCatalogResolveError(
                    code: "MODEL_MODALITIES_EMPTY",
                    message: "catalog model \"\(id)\" inputModalities must not be empty")
            }
            for modality in modalities where !ModelCatalogDefaults.modalities.contains(modality) {
                throw ModelCatalogResolveError(
                    code: "MODEL_MODALITIES_INVALID",
                    message: "catalog model \"\(id)\" inputModalities must contain only \"text\" and \"image\"")
            }
            if Set(modalities).count != modalities.count {
                throw ModelCatalogResolveError(
                    code: "MODEL_MODALITIES_DUPLICATE",
                    message: "catalog model \"\(id)\" inputModalities must not contain duplicates")
            }
            if seen.contains(id) {
                throw ModelCatalogResolveError(
                    code: "MODEL_ID_DUPLICATE",
                    message: "duplicate catalog model \"\(id)\"")
            }
            seen.insert(id)
            resolved.append(ModelCatalogEntry(
                id: id,
                name: model.name,
                description: model.description,
                contextWindow: model.contextWindow,
                maxTokens: model.maxTokens,
                inputModalities: modalities))
        }
        return resolved
    }

    // MARK: 解析链（唯一入口语义；dsh adapter.ts:398-409 modelInfoFor）

    /// 解析后上下文窗 = entry.contextWindow ?? endpoint 缺省窗口 ?? 1_000_000
    /// （dsh configured?.contextWindow ?? connection.defaultContextWindow；
    /// 万我 endpoint 缺省窗口 nil = 1_000_000）。
    static func resolvedContextWindow(_ entry: ModelCatalogEntry?,
                                      defaultContextWindow: Int?) -> Int {
        entry?.contextWindow ?? defaultContextWindow ?? ModelCatalogDefaults.contextWindow
    }

    /// 解析后单次输出上限 = entry.maxTokens ?? endpoint 缺省 maxTokens ??
    /// 256_000（dsh configured?.maxTokens ?? connection.maxTokens）。
    static func resolvedMaxTokens(_ entry: ModelCatalogEntry?,
                                  defaultMaxTokens: Int?) -> Int {
        entry?.maxTokens ?? defaultMaxTokens ?? ModelCatalogDefaults.maxTokens
    }

    /// 请求模态（dsh :307 modelInfo：inputModalities ?? ['text']——未登记即
    /// text-only 的 fail-closed 口径，见 pi-ai config.ts:66-76）。
    static func resolvedInputModalities(_ entry: ModelCatalogEntry?) -> [String] {
        let modalities = entry?.inputModalities ?? ModelCatalogDefaults.inputModalities
        return modalities.isEmpty ? ModelCatalogDefaults.inputModalities : modalities
    }

    /// 模型解析产物（dsh modelInfoFor 全量语义：精确 id 匹配 + 端点缺省兜底；
    /// 未登记模型 = 文本-only，窗口走端点缺省）。
    static func resolvedInfo(endpoint: EndpointConfig, modelID: String) -> ResolvedModelInfo {
        let entry = endpoint.models?.first(where: { $0.id == modelID })
        return ResolvedModelInfo(
            contextWindow: resolvedContextWindow(entry,
                                                 defaultContextWindow: endpoint.defaultContextWindow),
            defaultMaxTokens: resolvedMaxTokens(entry,
                                                defaultMaxTokens: endpoint.defaultMaxTokens),
            inputModalities: resolvedInputModalities(entry))
    }
}

// MARK: - EndpointConfig 消费辅助

extension EndpointConfig {
    /// 有效模型目录（件A4 数据源）：models 目录优先；nil/空 = 继承内置缺省
    /// ——万我内置目录空集起步 → 单模型行为（endpoint.model 一行；dsh
    /// catalog.ts:801-804「空列表 = serve installed catalog」的万我形态，
    /// installed = 空集时回落当前单模型，保证 chip 恒有可用项）。
    func catalogEntries() -> [ModelCatalogEntry] {
        if let models, !models.isEmpty { return models }
        return [ModelCatalogEntry(id: model)]
    }
}
