//
//  ModelCatalogEditorView.swift
//  WanWo
//
//  【m7-fix2 · E2 · 按用户 HTML 原型 1:1 重做】模型目录 field（.dir-field）。
//  原型锚点（设置模型配置原型（带动画）.html）：
//    · field-head（:1044-1054）：左 dir-label（label「模型目录」+ dir-status
//      「正在使用适配器默认模型」/「已自定义模型目录」）；右 dir-links =
//      「恢复默认模型」（有自定义才显示）+「获取可用模型」。
//    · 空态 empty-box 虚线框（:1056）：「模型选择器中将不显示任何模型；
//      目录外 ID 仍可直接发送。」
//    · model-row（:589-659）：head=模型 ID（等宽 12.8）+显示名两输入+行尾
//      展开（chev rotate 180° .42s）/删除钮；expanded 态阴影+顶部分隔线；
//      展开区=上下文窗口/最大输出 grid-2 + 输入类型勾选（文本/图片，
//      方框勾选 scale .24s）；entering 入场 modelRowIn .5s；删除=height
//      折叠 .4s（420ms 后移除）。
//    · 「＋ 添加模型」钮（:570-587）+ model-err 红行（:702-709）。
//
//  数据面契约（只消费不改）：ModelCatalogEntry / CapacityFormatting（十进制
//  1M=100万，清单10）/ ModelCatalogValidation / ModelDiscovery（探测缝——
//  候选由用户挑选、绝不静默写配置，清单12）。
//  平台适配（报告登记）：
//    · 容量输入键盘用 .default（可键入 K/M 后缀——旧实现 numberPad 键不出
//      字母后缀，与清单10「1M/256K 十进制」冲突，本批修正）。
//    · 「恢复默认模型」整组同时折叠（原型逐行 45ms 级联不做，登记）。
//    · 弹窗改 fullScreenCover + presentationBackground(.clear)（iOS 16.4+，
//      部署目标 16.6 内）承载原型遮罩+居中卡形态。
//    · 目录空集（继承态）时 dir-status 恒「正在使用适配器默认模型」；行级
//      目录在继承态直接编辑即转 override（onChange 整组上报，语义同批1）。
//
//  iOS 16.6 红线自查：无 foregroundStyle、无双参 onChange、无 iOS17+ API。
//

import SwiftUI

/// 模型目录 field（原型 .dir-field 交互骨架 1:1）。
struct ModelCatalogEditorView: View {

    // MARK: - 输入（契约同批1，只消费不改）

    let models: [ModelCatalogEntry]
    let overridden: Bool
    let defaultContextWindow: Int?
    let defaultMaxTokens: Int?
    let disabled: Bool
    var discoverModels: ((String, String?) async -> Result<[DiscoveredModel], Error>)?
    var probeBaseURL: String?
    var probeAPIKey: String?
    var probeBlockedReason: String?
    let onChange: ([ModelCatalogEntry]) -> Void
    let onReset: () -> Void
    /// 容量文本 per-field 缓冲（key = "\(行):\(字段)"；父卡持有供保存门读）。
    @Binding var capacityBuffers: [String: String]

    // MARK: - 状态

    @State private var expanded: Set<Int> = []
    @State private var probing = false
    @State private var probeFailure: String?
    /// 候选弹窗（原型 .modal-mask/.modal）。
    @State private var pickerPresented = false
    @State private var candidates: [DiscoveredModel] = []
    /// 出场折叠中的行（420ms 后真正移除——原型 removeModelRow 时序）。
    @State private var removingIndices: Set<Int> = []
    /// 「恢复默认模型」整组折叠中。
    @State private var resetting = false

    // MARK: - 常量

    private static let bufferK = "contextWindow"
    private static let bufferM = "maxTokens"

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldHead
            emptyOrList
            addModelButton
                .padding(.top, models.isEmpty ? 10 : 0)
            errorLine
        }
        .animation(WOMP.ease(WOMP.durRowIn), value: models)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("模型目录")
        .fullScreenCover(isPresented: $pickerPresented) {
            pickerLayer
                // 透明演示底（iOS 16.4+；部署目标 16.6 内）——遮罩+居中卡自绘。
                .presentationBackground(.clear)
        }
    }

    // MARK: field-head（原型 :1044-1054）

    private var fieldHead: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("模型目录")
                    .font(.system(size: 12.8))
                    .foregroundColor(Color(red: 0x55, green: 0x55, blue: 0x5f))
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundColor(WOMP.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(alignment: .top, spacing: 16) {
                if !models.isEmpty {
                    WOLinkButton(title: "恢复默认模型") { resetAll() }
                        .disabled(disabled || resetting || !removingIndices.isEmpty)
                }
                if discoverModels != nil {
                    WOLinkButton(title: probing ? "正在询问提供方…" : "获取可用模型") {
                        Task { await probe() }
                    }
                    .disabled(disabled || probing)
                }
            }
        }
        .padding(.bottom, 8)
    }

    /// dir-status（原型 updateDirState :1279-1292 语义）。
    private var statusText: String {
        models.isEmpty ? "正在使用适配器默认模型" : "已自定义模型目录"
    }

    // MARK: 空态 / 行列表

    @ViewBuilder
    private var emptyOrList: some View {
        if models.isEmpty {
            WOEmptyBox(text: "模型选择器中将不显示任何模型；目录外 ID 仍可直接发送。")
        } else {
            VStack(spacing: 0) {
                ForEach(models.indices, id: \.self) { index in
                    modelRow(index)
                }
            }
        }
    }

    // MARK: 模型行（原型 :589-659）

    private func modelRow(_ index: Int) -> some View {
        let isExpanded = expanded.contains(index)
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                rowHead(index)
                WOCollapsible(open: isExpanded) {
                    expandedBody(index)
                        // expanded 态顶部分隔线（原型 .model-row.expanded 分隔线）
                        .overlay(alignment: .top) {
                            Rectangle().fill(WOMP.lineSoft).frame(height: 1)
                        }
                }
            }
            .background(Color.white)
            .cornerRadius(13)
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(WOMP.line, lineWidth: 1))
            .shadow(color: isExpanded ? Color.black.opacity(0.05) : .clear, radius: 20, y: 6)
            .animation(.easeOut(duration: 0.25), value: isExpanded)
        }
        // 行距（原型 margin-top 10）放进折叠体，出场时一并归零。
        .padding(.top, 10)
        .modifier(WORemoveFold(removing: removingIndices.contains(index) || resetting))
        // entering 入场（原型 modelRowIn .5s：opacity 0 + 上移 8 + scale .985）。
        .transition(.opacity.combined(with: .offset(y: -8)).combined(with: .scale(0.985)))
    }

    /// 行头：ID（等宽）+ 显示名两输入 + 展开/删除钮（原型 :607-654）。
    private func rowHead(_ index: Int) -> some View {
        let isExpanded = expanded.contains(index)
        return HStack(spacing: 4) {
            TextField("模型 ID", text: idBinding(index),
                      prompt: Text("模型 ID").foregroundColor(WOMP.placeholder))
                .font(.system(size: 12.8, design: .monospaced))
                .foregroundColor(WOMP.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .frame(minHeight: 44) // 触屏命中
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowFieldFocused(index, isID: true) ? Color.black.opacity(0.032) : Color.clear))
                .accessibilityLabel("模型 ID \(index + 1)")

            TextField("显示名称", text: nameBinding(index),
                      prompt: Text("显示名称").foregroundColor(WOMP.placeholder))
                .font(.system(size: 13.5))
                .foregroundColor(WOMP.text)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowFieldFocused(index, isID: false) ? Color.black.opacity(0.032) : Color.clear))
                .accessibilityLabel("显示名称 \(index + 1)")

            // 行尾展开钮（chev rotate 180° .42s；触屏 ≥44pt）。
            Button {
                withAnimation(WOMP.ease(WOMP.durChevSection)) { toggle(index) }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(WOMP.text3)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(WOProtoPressStyle())
            .accessibilityLabel(isExpanded ? "收起容量设置 \(index + 1)" : "展开容量设置 \(index + 1)")

            // 行尾删除钮（触屏 ≥44pt；danger hover 态）。
            Button {
                removeRow(index)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundColor(WOMP.text3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(WOProtoPressStyle())
            .accessibilityLabel("删除模型 \(index + 1)")
            .disabled(disabled)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    /// 行内输入 focus 底纹（原型 input:focus bg black 3.2% 的近似——
    /// FocusState 无法按行下发，用「本行有展开态」不成立；退化为不做按行
    /// focus 追踪，保留 hover/静态形态——报告登记）。
    private func rowFieldFocused(_ index: Int, isID: Bool) -> Bool { false }

    /// 展开区：grid-2 容量 + 输入类型勾选（原型 :1246-1269）。
    private func expandedBody(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                capacityField(index, field: Self.bufferK,
                              label: "上下文窗口", fallback: defaultContextWindow)
                capacityField(index, field: Self.bufferM,
                              label: "最大输出 token 数", fallback: defaultMaxTokens)
            }
            HStack(spacing: 24) {
                WOCheckbox(checked: modalityBinding(index, "text"), label: "文本")
                WOCheckbox(checked: modalityBinding(index, "image"), label: "图片")
            }
        }
        .padding(14)
        .padding(.bottom, 16)
    }

    /// 容量字段（十进制 K/M；占位=继承缺省值灰字——清单10「灰占位」）。
    private func capacityField(_ index: Int, field: String,
                               label: String, fallback: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12.8))
                .foregroundColor(Color(red: 0x55, green: 0x55, blue: 0x5f))
            WOProtoInput(
                placeholder: fallback.map { CapacityFormatting.formatCapacity($0) }
                    ?? "使用提供方缺省值",
                text: bufferBinding(index, field: field))
        }
    }

    /// 输入类型勾选绑定（nil/空 = 缺省 ["text"]；全不勾 → 存空数组，
    /// 保存门按「输入类型至少勾选一项」行内报错——数据面 MODEL_MODALITIES_EMPTY）。
    private func modalityBinding(_ index: Int, _ modality: String) -> Binding<Bool> {
        Binding(
            get: {
                let modalities = models[index].inputModalities ?? ["text"]
                return modalities.contains(modality)
            },
            set: { on in
                var next = models
                var current = next[index].inputModalities ?? ["text"]
                if on {
                    if !current.contains(modality) { current.append(modality) }
                } else {
                    current.removeAll { $0 == modality }
                }
                next[index].inputModalities = current
                onChange(next)
            })
    }

    // MARK: 行操作

    private func toggle(_ index: Int) {
        if !expanded.insert(index).inserted { expanded.remove(index) }
    }

    /// 删除 = 出场折叠 .4s → 420ms 后移除（原型 removeModelRow :1313-1334）。
    private func removeRow(_ index: Int) {
        guard !removingIndices.contains(index) else { return }
        removingIndices.insert(index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            actuallyRemove(index)
        }
    }

    /// 真正移除（缓冲与展开态索引同步 re-key——批1 :293-308 语义原样）。
    private func actuallyRemove(_ index: Int) {
        removingIndices.remove(index)
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

    /// 恢复默认模型：整组同时折叠 → onReset 回继承（级联 45ms 不做——登记）。
    private func resetAll() {
        resetting = true
        expanded.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            resetting = false
            capacityBuffers.removeAll()
            onReset()
        }
    }

    /// 添加模型 = append 空行（原型 :353-361 语义；entering 过渡由容器动画驱动）。
    private var addModelButton: some View {
        WOAddModelButton(title: "＋ 添加模型", disabled: disabled) {
            onChange(models + [Self.emptyEntry])
        }
    }

    /// 空行起笔（契约全参构造——memberwise init 无默认参数保证）。
    private static var emptyEntry: ModelCatalogEntry {
        ModelCatalogEntry(id: "", name: nil, description: nil,
                          contextWindow: nil, maxTokens: nil, inputModalities: nil)
    }

    // MARK: 行绑定（批1 语义原样）

    private func idBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { models[index].id },
            set: {
                var next = models
                next[index].id = $0
                onChange(next)
            })
    }

    private func nameBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { models[index].name ?? "" },
            set: {
                var next = models
                next[index].name = $0.isEmpty ? nil : $0
                onChange(next)
            })
    }

    /// 字段当前文本：活键击优先（缓冲），否则存储计数反写（清单10「输错文本
    /// 不丢」的数据基础——不可读文本只存缓冲、不写回 Int? 字段）。
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

    // MARK: 行内报错（model-err，原型 :702-709 红行 #dc2626）

    @ViewBuilder
    private var errorLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let probeFailure {
                Text(probeFailure)
            } else if let live = liveValidationError {
                Text(live)
            } else if let blocked = probeBlockedReason {
                Text(blocked)
            }
        }
        .font(.system(size: 12.5))
        .foregroundColor(WOMP.red)
        .padding(.top, 10)
        .padding(.horizontal, 2)
    }

    /// 活校验（原型 updateErrors :1294-1311：空 ID 首行点名——键击即时报，
    /// 文本不丢）。
    private var liveValidationError: String? {
        for (index, model) in models.enumerated()
        where model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "模型 \(index + 1): 模型 ID 不能为空。"
        }
        return nil
    }

    // MARK: 探测（清单12：候选弹窗挑选加入；失败显错不偷写）

    private func probe() async {
        guard let discoverModels else { return }
        guard let probeBaseURL, !probeBaseURL.isEmpty else {
            probeFailure = "先填写 API 地址，再获取可用模型。"
            return
        }
        probing = true
        probeFailure = nil
        defer { probing = false }
        let result = await discoverModels(probeBaseURL, probeAPIKey)
        switch result {
        case .failure(let error):
            // 失败非死路：错误显示在行旁（model-err），继续手填。
            probeFailure = "获取失败：\(error.localizedDescription)"
        case .success(let found):
            if found.isEmpty {
                probeFailure = "提供方未列出任何模型，请手动添加。"
                return
            }
            candidates = found
            pickerPresented = true
        }
    }

    // MARK: 候选弹窗（原型 .modal-mask/.modal；fullScreenCover + 清晰遮罩自绘）

    private var pickerLayer: some View {
        ModelPickerModal(
            candidates: candidates,
            existingIDs: Set(models.map(\.id)),
            onAdd: { adopt($0) },
            onCancel: { pickerPresented = false })
    }

    /// 采纳勾选（带容量加入）。已有行（按 id 精确匹配）原样保留，绝不静默改写。
    /// 修（清单12 · 多候选采纳丢行）：批量勾选改为**一次性整组上报**——
    /// `models` 是父级下发的 `let` 快照，Task 内逐条 `onChange(models + [entry])`
    /// 会反复读到同一份旧基线，最终覆写只剩最后一条。现在 Task 内以局部
    /// 数组累积（不读捕获副本、循环中绝不触发 onChange），循环结束后以
    /// 完整数组单次 onChange 落盘。行入场动画由 `.animation(value: models)`
    /// 随整组变更触发（原"逐行 60ms 级联"随之让位于正确性）。
    private func adopt(_ picked: [DiscoveredModel]) {
        pickerPresented = false
        guard !picked.isEmpty else { return }
        let baseline = models
        Task { @MainActor in
            var next = baseline
            var addedCount = 0
            for candidate in picked {
                // 去重：目录已有 + 本批内重复（同一 id 只收一次）。
                guard !next.contains(where: { $0.id == candidate.id }) else { continue }
                var entry = ModelCatalogEntry(id: candidate.id, name: candidate.name,
                                              description: nil,
                                              contextWindow: candidate.contextWindow,
                                              maxTokens: candidate.maxTokens,
                                              inputModalities: nil)
                if (entry.name ?? "").isEmpty { entry.name = nil }
                next.append(entry)
                addedCount += 1
            }
            guard addedCount > 0 else { return }
            onChange(next)
        }
    }
}
