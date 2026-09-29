//
//  ProvidersSectionView.swift
//  WanWo
//
//  【m8 批1 A2 · 照 dsh 语义翻译】模型/提供方分区主视图。
//  语义源：dsh ui-settings-models/src/client/ModelsSection.tsx:195-588
//  ——provider 行卡列表；一次只开一张编辑卡（开卡时关添加/声明卡
//  :388-401）；行头=displayName+custom 标签+key 状态实心点（configured→绿/
//  缺→灰 :363-386）；删除=确认弹窗→先 unset 凭据再删端点、两步幂等
//  （removeProviderProfile :113-130）；保存成功 reload+saved 轻提示
//  （announceSaved :216-221）；无任何已配置端点时首启引导卡（可 dismiss，
//  needsSetup :141-145 + closeSetup :237-240）。
//
//  平台适配（报告登记）：
//    · dsh 双添加路（adopt 目录可选 + 手声明）→ 万我无 provider 目录面，
//      仅保留手声明一路（CustomProviderCardView）；adopt select 不做。
//    · store 为 ObservableObject：保存后 @Published 驱动重渲染，dsh 的
//      controller.load() reload 步骤不需要；saved 轻提示在 onClose(true)
//      时设置，下次任意开卡/删除时清除（savedTarget 生命周期等价）。
//    · 删除=先 unset 凭据（幂等）再 store.remove（内部亦删 Keychain——
//      双删幂等无害，语义与 dsh 两步幂等一致）；删除失败显示为提示行。
//    · custom 标签判定近似：万我端点均为 BYOK 自建，非出厂默认形态
//      （baseURL/name/model 与出厂三元组逐值比对）即视作手声明显示标签。
//    · 凭据缺省缝直绑 EndpointStore 现有 Keychain+文件兜底面（A1
//      CredentialStore 落地后换实现——CredentialInfo 永不含值语义保留）。
//

import SwiftUI

/// 提供方分区主视图（dsh ModelsSection.tsx:195-588 交互骨架 1:1）。
struct ProvidersSectionView: View {

    // MARK: - 输入

    @ObservedObject private var store: EndpointStore
    /// 探测缝（下传编辑卡与声明卡；nil=探测入口不渲染）。
    var discoverModels: ((String, String?) async -> Result<[DiscoveredModel], Error>)?

    init(store: EndpointStore,
         discoverModels: ((String, String?) async -> Result<[DiscoveredModel], Error>)? = nil) {
        self.store = store
        self.discoverModels = discoverModels
    }

    // MARK: - 状态（dsh :207-214 一组）

    /// 当前展开的编辑卡（一次只开一张；nil=全部收起）。
    @State private var editingID: UUID?
    /// 手声明卡展开中（与编辑卡互斥——:388-401）。
    @State private var declaring = false
    /// 删除确认目标。
    @State private var deleteTarget: EndpointConfig?
    @State private var deleteInFlight = false
    @State private var deleteFailure: String?
    /// saved 轻提示（保存成功后设；下次开卡/删除清除——savedTarget 语义）。
    @State private var savedNotice: String?
    /// 首启引导卡已关闭集合（dsh dismissedSetup :214）。
    @State private var dismissedSetup: Set<UUID> = []

    // MARK: - 凭据缝（缺省=EndpointStore 现有面；A1 CredentialStore 换实现）

    private var credentialSeam: ProviderCredentialSeam {
        let store = self.store
        return ProviderCredentialSeam(
            // 读视图直呼（dsh describe configured 布尔——值永不进 UI 缝，
            // A1 协调：apiKey(for:) 读值判空为不必要的缝）。
            describe: { CredentialInfo(configured: store.credentialConfigured(for: $0),
                                       source: nil, writable: true) },
            set: { try store.setApiKey($1, for: $0) },
            // 凭据清除走 store 三清缝（route ref + 旧 uuid 账目 + 文件兜底，
            // 幂等——直删 KeychainStore 旧账目清不到 route ref，A1 协调修正）。
            unset: { store.unsetCredential(for: $0) })
    }

    // MARK: - Body

    var body: some View {
        List {
            Section {
                Text("填入各提供方的 API 密钥即可使用其模型。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let savedNotice {
                    Text(savedNotice)
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }
            Section {
                ForEach(store.endpoints) { endpoint in
                    row(endpoint)
                }
            } footer: {
                Text("OpenAI 兼容格式接入（base URL + API Key + 模型目录）。API Key 存 Keychain，"
                     + "侧载环境 Keychain 不可用时自动以沙箱文件兜底；均不写入配置文件。")
            }
            Section {
                if declaring {
                    CustomProviderCardView(
                        store: store,
                        taken: store.endpoints.map(\.name),
                        credentialSeam: credentialSeam,
                        discoverModels: discoverModels,
                        onClose: { changed in
                            declaring = false
                            if changed { announceSaved() }
                        },
                        onCredentialNotice: { appendCredentialNotice($0) })
                } else {
                    // 添加入口（dsh addActions :501-539 的万我单路形态：
                    // 无 provider 目录面，仅手声明一路——报告登记）。
                    Button {
                        savedNotice = nil
                        editingID = nil
                        declaring = true
                    } label: {
                        Label("添加自定义提供方", systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            }
        }
        // 删除确认弹窗（dsh Modal :542-575 的 confirmationDialog 等价——
        // 批3 B3 既有形态；失败文本于分区提示行显示）。
        .confirmationDialog("删除端点", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { closeDelete() } }),
            titleVisibility: .visible,
            presenting: deleteTarget) { endpoint in
            Button("删除「\(endpoint.displayName ?? endpoint.name)」", role: .destructive) {
                Task { await confirmDelete(endpoint) }
            }
            .disabled(deleteInFlight)
            Button("取消", role: .cancel) { closeDelete() }
        } message: { endpoint in
            Text(deleteMessage(for: endpoint))
        }
    }

    // MARK: - 行卡（dsh :352-436）

    @ViewBuilder
    private func row(_ endpoint: EndpointConfig) -> some View {
        // 首启引导：无任何已配置端点且本行未 dismiss → setup 卡即其存在
        // （needsSetup :141-145；dsh 只渲染 setup 卡而非行）。
        if needsSetup(endpoint) {
            VStack(alignment: .leading, spacing: 8) {
                Text("添加一个 API Key 开始使用。")
                    .font(.subheadline)
                ProviderEditorView(
                    store: store,
                    endpoint: endpoint,
                    credentialOnly: true,
                    credentialRequired: true,
                    autoFocusKey: true,
                    cancelLabel: "稍后配置",
                    submitLabel: "保存",
                    credentialSeam: credentialSeam,
                    discoverModels: discoverModels,
                    onClose: { changed in
                        // 关引导卡只记本卡状态，不动编辑/添加卡草稿
                        //（closeSetup :237-240 语义）。
                        dismissedSetup.insert(endpoint.id)
                        if changed { announceSaved() }
                    },
                    onCredentialNotice: { appendCredentialNotice($0) })
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    keyStatusDot(isConfigured(endpoint))
                    Text(endpoint.displayName ?? endpoint.name)
                        .font(.headline)
                    if isCustom(endpoint) {
                        Text("自定义")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if let editingID, editingID == endpoint.id {
                    ProviderEditorView(
                        store: store,
                        endpoint: endpoint,
                        credentialSeam: credentialSeam,
                        discoverModels: discoverModels,
                        onClose: { changed in
                            closeEditor(changed: changed, endpoint: endpoint)
                        },
                        onCredentialNotice: { appendCredentialNotice($0) })
                } else {
                    HStack(spacing: 8) {
                        Text("\(endpoint.baseURL)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        // 编辑钮（开卡先关声明卡+saved 清除——:384-396）。
                        Button("编辑") {
                            savedNotice = nil
                            declaring = false
                            editingID = editingID == endpoint.id ? nil : endpoint.id
                        }
                        .frame(minHeight: 44)
                        .buttonStyle(.bordered)
                        Button("删除", role: .destructive) {
                            savedNotice = nil
                            deleteFailure = nil
                            deleteTarget = endpoint
                        }
                        .frame(minHeight: 44)
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// key 状态实心点（dsh :363-386：configured→绿实心 / 缺→灰）。
    @ViewBuilder
    private func keyStatusDot(_ present: Bool) -> some View {
        if present {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .accessibilityLabel("已配置 API Key")
        } else {
            Circle()
                .strokeBorder(Color.secondary, lineWidth: 1)
                .frame(width: 8, height: 8)
                .accessibilityLabel("未配置 API Key")
        }
    }

    // MARK: - 首启引导判定（dsh needsSetup :141-145）

    /// 无任何已配置端点（anyUsable=false 等价）且本行无凭据且未 dismiss。
    private func needsSetup(_ endpoint: EndpointConfig) -> Bool {
        guard !dismissedSetup.contains(endpoint.id) else { return false }
        guard !store.endpoints.contains(where: isConfigured) else { return false }
        return !isConfigured(endpoint)
    }

    private func isConfigured(_ endpoint: EndpointConfig) -> Bool {
        credentialSeam.describe(endpoint).configured
    }

    /// custom 标签近似判定（文件头注·平台适配）：与出厂默认三元组不一致
    /// 即视为手声明。
    private func isCustom(_ endpoint: EndpointConfig) -> Bool {
        !(endpoint.name == "DeepSeek"
            && endpoint.baseURL == "https://api.deepseek.com"
            && endpoint.model == "deepseek-v4-flash")
    }

    // MARK: - 编辑卡关闭 / saved 轻提示（dsh :216-228）

    private func closeEditor(changed: Bool, endpoint: EndpointConfig) {
        editingID = nil
        declaring = false
        if changed { announceSaved() }
    }

    private func announceSaved() {
        // 万我 store 即发布源：@Published 已驱动重渲染，dsh 的 reload 步骤
        // 不需要；提示在下次开卡/删除时清除（savedTarget 生命周期等价）。
        savedNotice = savedNoticeBase
    }

    private var savedNoticeBase: String { "已保存。" }

    private func appendCredentialNotice(_ notice: String?) {
        guard let notice, !notice.isEmpty else { return }
        // 凭据存储描述并入轻提示（Keychain/文件兜底透出——ERR-016 语义）。
        savedNotice = "\(savedNoticeBase) \(notice)"
    }

    // MARK: - 删除（dsh removeProviderProfile :113-130 两步幂等）

    private func closeDelete() {
        if deleteInFlight { return }
        deleteTarget = nil
        deleteFailure = nil
    }

    private func confirmDelete(_ endpoint: EndpointConfig) async {
        deleteInFlight = true
        defer { deleteInFlight = false }
        // 第一步：先删凭据（幂等——第二步失败时行仍可见、整体可重试）。
        do {
            try credentialSeam.unset(endpoint)
        } catch {
            deleteFailure = "凭据清除失败：\((error as NSError).localizedDescription)"
            savedNotice = deleteFailure
            return
        }
        // 第二步：删端点（store.remove 内部亦删 Keychain——双删幂等无害）。
        store.remove(endpoint)
        deleteTarget = nil
    }

    /// 删除确认两版描述（有凭据点明一并清除——dsh deleteDescription 两版）。
    private func deleteMessage(for endpoint: EndpointConfig) -> String {
        isConfigured(endpoint)
            ? "「\(endpoint.displayName ?? endpoint.name)」已配置 API Key，删除将一并清除凭据，且无法恢复。"
            : "删除端点「\(endpoint.displayName ?? endpoint.name)」？此操作无法恢复。"
    }
}
