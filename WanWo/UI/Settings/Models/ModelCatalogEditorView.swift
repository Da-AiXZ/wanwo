//
//  ModelCatalogEditorView.swift
//  WanWo
//
//  【m8 批1 A2 · 照 dsh 语义翻译】模型目录编辑器。
//  语义源：dsh ui-settings-models/src/client/DeepSeekModelsEditor.tsx:151-364
//  （行列表 id+name+chevron 展开/收起+行删除、继承/已自定义徽标+重置、
//  添加=append 空行 :353-361、行删除时缓冲与展开态 re-key :177-197）
//  + ModelListEditor.tsx 的探测动作（fetchModels 语义：候选由用户挑选、
//  绝不静默写配置；失败非死路=错误显示在行旁继续手填）。
//
//  平台适配（报告登记）：
//    · 容量以 K/M 文本编辑，per-field 输入缓冲（key "行:字段"）防重排丢字
//      （dsh :152-163 同语义）；缓冲由父卡持有（Binding），不可读文本无法
//      编码进 Int? 容量字段（dsh 以 NaN 存入 draft 由 validate 拒绝），故
//      保存门经父卡读缓冲判不可读并按行报错。
//    · 探测缝：万我无 Host discovery 面，经闭包缝注入（A1 ModelDiscovery
//      就绪后接线）；候选=id 字符串列表，采纳=append 新行，绝不静默写。
//    · chevron 旋转/展开动画为万我平台增强（WOMotion 纪律内）。
//

import SwiftUI

/// 模型目录编辑器（dsh DeepSeekModelsEditor.tsx:151-364 交互骨架 1:1）。
struct ModelCatalogEditorView: View {

    // MARK: - 输入

    /// 生效行：父级在继承态供给缺省目录，首次编辑起为用户 override。
    let models: [ModelCatalogEntry]
    /// 用户层当前是否持有整个目录（true=已自定义，false=继承）。
    let overridden: Bool
    /// 行省略精确值时回落使用的上下文容量（placeholder 展示）。
    let defaultContextWindow: Int?
    /// 行省略精确值时回落使用的输出上限（placeholder 展示）。
    let defaultMaxTokens: Int?
    /// 禁用全部编辑（只读或保存进行中）。
    let disabled: Bool
    /// 探测缝：(baseURL, 已输入未保存 key) → 候选模型（id+name+容量）列表 / 错误。
    /// nil = 探测入口不渲染（A1 ModelDiscovery 交付后由挂点注入启用）。
    var discoverModels: ((String, String?) async -> Result<[DiscoveredModel], Error>)?
    /// 探测用表单当前 baseURL（含未保存值——dsh "表单当前值"语义）。
    var probeBaseURL: String?
    /// 探测用已输入未保存 key（永不回显，仅随请求）。
    var probeAPIKey: String?
    /// 探测入口禁用原因文案（如 key 形校验未过——dsh probeBlocked 语义）。
    var probeBlockedReason: String?

    /// 替换用户目录（一次可见编辑后整组回调）。
    let onChange: ([ModelCatalogEntry]) -> Void
    /// 移除用户目录、回到继承。
    let onReset: () -> Void

    /// 容量文本 per-field 缓冲（key = "\(行):\(字段)"）。父卡持有：
    /// 保存门需读缓冲判不可读文本（文件头注·平台适配）。
    @Binding var capacityBuffers: [String: String]

    // MARK: - 状态

    /// 展开的行集合（dsh expanded :164；行删除时同步 re-key）。
    @State private var expanded: Set<Int> = []
    /// 探测进行中。
    @State private var probing = false
    /// 探测失败文案（显示在行列表旁，非死路——继续手填）。
    @State private var probeFailure: String?
    /// 候选挑选弹层。
    @State private var candidates: [DiscoveredModel]?
    /// 候选勾选集。
    @State private var picked: Set<String> = []
    /// 候选搜索词。
    @State private var candidateQuery = ""

    // MARK: - 常量

    private static let bufferK = "contextWindow"
    private static let bufferM = "maxTokens"

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            listHead
            if models.isEmpty {
                Text("选择器中将不显示任何模型；未列出的模型 ID 仍可直接发送。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(models.indices, id: \.self) { index in
                    modelRow(index)
                }
            }
            addModelButton
            if let probeFailure {
                Text(probeFailure)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("模型目录")
        // 候选挑选弹层（dsh Modal fetchTitle 语义：挑选采纳，绝不静默写）。
        .sheet(isPresented: Binding(get: { candidates != nil },
                                    set: { if !$0 { closePicker() } })) {
            candidatePicker
        }
    }

    // MARK: - 列表头（标题 + 徽标 + 重置 + 探测）

    private var listHead: some View {
        HStack(spacing: 12) {
            Text("模型")
                .font(.subheadline.weight(.medium))
            // 「继承/已自定义」徽标（dsh modelCatalogMeta :270-272）。
            Text(overridden ? "已自定义目录" : "使用适配器缺省")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if overridden {
                Button("恢复缺省") { reset() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .frame(minHeight: 44)
                    .disabled(disabled)
            }
            // 探测入口（dsh ModelListEditor :338-348——表单当前值问端点；
            // 失败非死路，错误留在行旁）。
            if discoverModels != nil {
                Button {
                    Task { await probe() }
                } label: {
                    Text(probing ? "正在询问提供方…" : "拉取可用模型")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .frame(minHeight: 44)
                .disabled(disabled || probing || !askable || probeBlockedReason != nil)
                .help(probeBlockedReason ?? (!askable ? "先填写 Base URL 再拉取。" : ""))
            }
        }
    }

    /// 可问性：有 baseURL 才有可问对象（dsh askable :312）。
    private var askable: Bool {
        guard let probeBaseURL, !probeBaseURL.isEmpty else { return false }
        return true
    }

    // MARK: - 模型行

    private func modelRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("模型 ID", text: idBinding(index),
                          prompt: Text("模型 ID").foregroundStyle(.tertiary))
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("模型 ID \(index + 1)")
                    // 外接键盘回车收尾：trim 粘贴残留（dsh blur 语义的可用近似；
                    // 触屏路径由保存门统一 trim 归一——报告注明）。
                    .onSubmit { settleID(index) }
                TextField("显示名", text: nameBinding(index))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("显示名 \(index + 1)")
                // chevron 展开/收起（旋转动画=万我平台增强；dsh :320-329）。
                Button {
                    withAnimation(WOMotion.standardSpring) { toggle(index) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .rotationEffect(.degrees(expanded.contains(index) ? 90 : 0))
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("容量 \(index + 1)")
                // 行删除（dsh :330-339；缓冲与展开态索引同步 re-key）。
                Button(role: .destructive) {
                    withAnimation(WOMotion.standardSpring) { remove(index) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityLabel("删除模型 \(index + 1)")
                .disabled(disabled)
            }
            if expanded.contains(index) {
                HStack(spacing: 12) {
                    capacityField(index, field: Self.bufferK,
                                  label: "上下文窗口",
                                  fallback: defaultContextWindow)
                    capacityField(index, field: Self.bufferM,
                                  label: "最大输出",
                                  fallback: defaultMaxTokens)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
    }

    /// 行 id 绑定：直接写目录行；blur 时 trim（dsh :302-307 粘贴残留语义）。
    private func idBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { models[index].id },
            set: {
                var next = models
                next[index].id = $0
                onChange(next)
            })
    }

    /// 行 name 绑定：空串落 nil（dsh :316-318 清空=字段离场语义）。
    private func nameBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { models[index].name ?? "" },
            set: {
                var next = models
                next[index].name = $0.isEmpty ? nil : $0
                onChange(next)
            })
    }

    /// id blur 收尾（首尾空白=粘贴残留，按 dsh :302-307 blur 时 trim）。
    private func settleID(_ index: Int) {
        let trimmed = models[index].id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != models[index].id {
            var next = models
            next[index].id = trimmed
            onChange(next)
        }
    }

    /// 一个容量字段（dsh capacityField :237-263：显示=活键击优先，
    /// 否则存储计数反写；占位符=继承缺省值 :344-345）。
    private func capacityField(_ index: Int, field: String,
                               label: String, fallback: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(label, text: bufferBinding(index, field: field),
                          prompt: Text(fallback.map { CapacityFormatting.formatCapacity($0) }
                                   ?? "使用提供方缺省值")
                          .foregroundColor(.secondary))
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .accessibilityLabel("\(label) \(index + 1)")
        }
        .frame(maxWidth: 160, alignment: .leading)
    }

    /// 字段当前文本：活键击优先（缓冲），否则存储计数反写（dsh capacityText :214-219）。
    private func bufferText(_ index: Int, field: String) -> String {
        if let typed = capacityBuffers["\(index):\(field)"] { return typed }
        let value = field == Self.bufferK
            ? models[index].contextWindow
            : models[index].maxTokens
        return value.map { CapacityFormatting.formatCapacity($0) } ?? ""
    }

    private func bufferBinding(_ index: Int, field: String) -> Binding<String> {
        Binding(
            get: { bufferText(index, field: field) },
            set: { text in
                // 键击进缓冲防重排丢字（dsh :255-259）；解析结果同步进行。
                capacityBuffers["\(index):\(field)"] = text
                let parsed = CapacityFormatting.parseCapacity(text)
                let value = parsed.flatMap { $0.isNaN ? nil : Int($0) }
                var next = models
                if field == Self.bufferK {
                    next[index].contextWindow = value
                } else {
                    next[index].maxTokens = value
                }
                onChange(next)
            })
    }

    // MARK: - 行操作（缓冲与展开态索引同步 re-key，dsh :177-197 / :388-403）

    private func toggle(_ index: Int) {
        if !expanded.insert(index).inserted { expanded.remove(index) }
    }

    private func remove(_ index: Int) {
        var rekeyed: [String: String] = [:]
        for (key, text) in capacityBuffers {
            guard let at = Int(key.prefix(while: { $0.isNumber })) else { continue }
            if at == index { continue } // 被删行的缓冲随之离场
            let field = key.contains(":") ? String(key.split(separator: ":", maxSplits: 1)[1]) : key
            rekeyed["\(at > index ? at - 1 : at):\(field)"] = text
        }
        capacityBuffers = rekeyed
        expanded = Set(expanded.compactMap { at -> Int? in
            at == index ? nil : (at > index ? at - 1 : at)
        })
        var next = models
        next.remove(at: index)
        onChange(next)
    }

    private func reset() {
        // 重置回继承：行没了，缓冲与展开态一并清场（dsh :199-203）。
        capacityBuffers.removeAll()
        expanded.removeAll()
        onReset()
    }

    /// 添加模型 = append 空行（dsh :353-361）。
    private var addModelButton: some View {
        Button {
            onChange(models + [Self.emptyEntry])
        } label: {
            Label("添加模型", systemImage: "plus")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
        .frame(minHeight: 44)
        .disabled(disabled)
    }

    /// 空行起笔（契约全参构造——memberwise init 无默认参数保证）。
    private static var emptyEntry: ModelCatalogEntry {
        ModelCatalogEntry(id: "", name: nil, description: nil,
                          contextWindow: nil, maxTokens: nil, inputModalities: nil)
    }

    /// 目录变更上报（值拷贝语义：struct 复制天然保留本编辑器不触碰的字段
    /// ——description/inputModalities 等，对齐 dsh "structurally open" 注释）。
    private func emit() {
        onChange(models)
    }

    // MARK: - 探测（dsh ModelListEditor fetchModels :229-257 语义）

    private func probe() async {
        guard let discoverModels, let probeBaseURL, !probeBaseURL.isEmpty else { return }
        probing = true
        probeFailure = nil
        defer { probing = false }
        let result = await discoverModels(probeBaseURL, probeAPIKey)
        switch result {
        case .failure(let error):
            // 失败非死路：错误显示在行旁，用户继续手填。
            probeFailure = "拉取失败：\(error.localizedDescription)"
        case .success(let found):
            if found.isEmpty {
                probeFailure = "提供方未列出任何模型，请手动添加。"
                return
            }
            // 已配置的行起始不勾选：采纳选择时绝不静默改写用户已调过的行
            //（dsh :248-253）。
            let known = Set(models.map(\.id))
            candidateQuery = ""
            candidates = found
            picked = Set(found.map(\.id).filter { !known.contains($0) })
        }
    }

    private func closePicker() {
        candidates = nil
        picked = []
        candidateQuery = ""
    }

    /// 采纳勾选（dsh adopt :145-152 语义）：已有行（按 id 精确匹配）原样
    /// 保留——用户调过的行赢过提供方数字（:265-279）；其余行连同提供方
    /// 披露的容量一起采纳进目录，省手填。
    private func adoptPicked() {
        var byID = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for candidate in candidates ?? [] where picked.contains(candidate.id) {
            if byID[candidate.id] == nil {
                var entry = ModelCatalogEntry(id: candidate.id, name: candidate.name,
                                              description: nil, contextWindow: candidate.contextWindow,
                                              maxTokens: candidate.maxTokens, inputModalities: nil)
                // 空名不落字段（清空=字段离场语义与行编辑一致）。
                if (entry.name ?? "").isEmpty { entry.name = nil }
                byID[candidate.id] = entry
            }
        }
        onChange(Array(byID.values))
        closePicker()
    }

    // MARK: - 候选挑选弹层

    private var candidatePicker: some View {
        NavigationStack {
            List {
                Section {
                    TextField("搜索模型", text: $candidateQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    ForEach(visibleCandidates, id: \.id) { candidate in
                        Button {
                            if !picked.insert(candidate.id).inserted { picked.remove(candidate.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(candidate.id)
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.primary)
                                    // 容量副行：采纳时随行进目录（dsh adopt 语义）。
                                    if candidate.contextWindow != nil || candidate.maxTokens != nil {
                                        Text(capacitySummary(candidate))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if picked.contains(candidate.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    if visibleCandidates.isEmpty {
                        Text("无匹配模型。")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("这些是提供方当前可用的模型，勾选需要加入目录的项。")
                }
            }
            .navigationTitle("选择要添加的模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { closePicker() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入所选") { adoptPicked() }
                        .disabled(picked.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var visibleCandidates: [DiscoveredModel] {
        let query = candidateQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = candidates ?? []
        guard !query.isEmpty else { return all }
        // id 或显示名含搜索词（dsh :291-294）。
        return all.filter {
            $0.id.lowercased().contains(query)
                || $0.name?.lowercased().contains(query) == true
        }
    }

    /// 候选容量摘要副行（K/M 短式）。
    private func capacitySummary(_ candidate: DiscoveredModel) -> String {
        let parts: [String] = [
            candidate.contextWindow.map { "上下文 \(CapacityFormatting.formatCapacity($0))" },
            candidate.maxTokens.map { "输出 \(CapacityFormatting.formatCapacity($0))" },
        ].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
}
