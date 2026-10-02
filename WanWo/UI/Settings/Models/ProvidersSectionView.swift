//
//  ProvidersSectionView.swift
//  WanWo
//
//  【m7-fix2 · E2 · 按用户 HTML 原型 1:1 重做】设置·模型分区主视图
//  （原型右主区 .main + .provider-list）。
//  原型锚点（设置模型配置原型（带动画）.html）：
//    · main-top：右对齐「打开配置文件」ghost 钮 + 关闭钮（:932-940）；
//      关闭钮由 WOSettingsModal 壳承载（多分区共用，报告登记）。
//    · 滚动区（pad 6/44/44）：页标题「模型」+副标「填入各提供商的 API 密钥
//      即可使用其模型。」+ provider 行卡列表 +「＋ 添加模型提供商」虚线钮
//      + 展开的添加表单（:942-962）。
//    · provider 行卡（:177-236）：圆角14 边框卡 = 名称 + key 状态点
//      （绿=已配/灰=未配，#22c55e+光晕 0 0 0 3px rgba(34,197,94,.15)）
//      + 行尾操作钮（编辑 / 删除 danger）；hover 边框加深+阴影；
//      **同时只能展开一张编辑卡**（点第二张第一张自动收起——清单9）；
//      removing 出场态（opacity 0 / 上移 6px / scale .97，:195-199）。
//    · 行卡入场 opacity 0 + translateY(-8) scale(.99) → none（.45/.55s）。
//
//  数据面（只消费不改）：EndpointStore / CredentialStore 语义（经
//  ProviderCredentialSeam）/ ModelDiscovery（经探测缝）。
//  平台适配（报告登记）：
//    · 「打开配置文件」= 分享 providers.json（文件 App 导出/查看）——
//      App 沙箱目录无「打开所在目录」的 iOS 等价，用既有 ShareLink 面；
//      路径自 WanWoPaths.persistentBase/config/providers.json 重建（与
//      AppEnvironment :363 同约定，零 App/ 改动）。
//    · dsh 首启引导卡（needsSetup setup 卡）退役——原型无此形态，行卡编辑
//      面板即配置路径；「未配置」语义由灰状态点透出（清单13 重建后一致）。
//    · 删除 = 二次确认（confirmationDialog）→ 先 unset 凭据（幂等）→
//      removing 出场折叠 → 450ms 后 store.remove（双删幂等，清单13）。
//
//  iOS 16.6 红线自查：无 foregroundStyle、无双参 onChange、无 iOS17+ API。
//

import SwiftUI

/// 提供方分区主视图（原型右主区 1:1）。
struct ProvidersSectionView: View {

    // MARK: - 输入

    @ObservedObject private var store: EndpointStore
    /// 探测缝（下传编辑卡与添加表单；nil=探测入口不渲染）。
    var discoverModels: ((String, String?) async -> Result<[DiscoveredModel], Error>)?

    init(store: EndpointStore,
         discoverModels: ((String, String?) async -> Result<[DiscoveredModel], Error>)? = nil) {
        self.store = store
        self.discoverModels = discoverModels
    }

    // MARK: - 状态

    /// 当前展开的编辑卡（一次只开一张；nil=全部收起——清单9 单展开）。
    @State private var editingID: UUID?
    /// 添加表单展开中（原型与编辑卡互不排斥——:1767-1770 独立 toggle）。
    @State private var formOpen = false
    /// 出场折叠中的卡（removing 态；450ms 后真正移除）。
    @State private var removingID: UUID?
    /// 删除确认目标（清单13 二次确认）。
    @State private var deleteTarget: EndpointConfig?
    @State private var deleteInFlight = false
    /// 凭据存储描述（编辑卡保存透出；随 saved 轻提示合并）。
    @State private var credentialNotice: String?
    /// 顶部轻提示（saved / 错误；WOToast 自计时）。
    @State private var toast: String?

    // MARK: - 凭据缝（缺省=EndpointStore 现有面；CredentialInfo 永不含值）

    private var credentialSeam: ProviderCredentialSeam {
        let store = self.store
        return ProviderCredentialSeam(
            describe: { CredentialInfo(configured: store.credentialConfigured(for: $0),
                                       source: nil, writable: true) },
            set: { try store.setApiKey($1, for: $0) },
            unset: { store.unsetCredential(for: $0) })
    }

    /// providers.json（打开配置文件面——AppEnvironment :363 同约定重建）。
    private static var providersFileURL: URL {
        WanWoPaths.persistentBase
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("providers.json")
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    Text("模型")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(WOMP.text)
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                    Text("填入各提供商的 API 密钥即可使用其模型。")
                        .font(.system(size: 13))
                        .foregroundColor(WOMP.text3)
                        .lineSpacing(4)
                        .padding(.bottom, 20)

                    providerList

                    WODashedAddButton(title: "＋ 添加模型提供商") {
                        // 批6 G3：显式事务开合（此前裸 toggle 依赖 WOCollapsible
                        // 隐式 .animation 注入 → 真机「添加卡收起直接没动画，
                        // 瞬间闪上来」——用户复测实证的根因路径）。
                        withAnimation(WOMP.ease(WOMP.durCollapse)) {
                            formOpen.toggle()
                        }
                    }
                    .padding(.top, 4)

                    WOCollapsible(open: formOpen) {
                        AddProviderFormView(
                            store: store,
                            credentialSeam: credentialSeam,
                            discoverModels: discoverModels,
                            // M4③：展开态下传——false→true 时表单整体重置
                            // （重开残留清零，成功/取消路径都覆盖）。
                            isOpen: formOpen,
                            onClose: { changed in
                                // 批6 G3：关闭也走显式 .58s 事务（取消/保存
                                // 统一路径；changed=有提交才并 saved 轻提示）。
                                withAnimation(WOMP.ease(WOMP.durCollapse)) {
                                    formOpen = false
                                }
                                if changed { announceSaved() }
                            },
                            onCredentialNotice: { credentialNotice = $0 })
                    }
                }
                .padding(.horizontal, 44)
                .padding(.top, 6)
                .padding(.bottom, 44)
            }

            // 顶部轻提示（saved / 凭据透出 / 删除失败）。
            if let toast {
                WOToast(text: toast, onDone: { self.toast = nil })
                    .padding(.top, 8)
            }
        }
        // 删除确认弹窗（清单13；确认后先 unset 凭据再出场折叠移除）。
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

    // MARK: - main-top（打开配置文件 ghost 钮；关闭钮归设置壳）

    private var topBar: some View {
        HStack {
            Spacer(minLength: 0)
            ShareLink(item: Self.providersFileURL) {
                Text("打开配置文件")
                    .font(.system(size: 13))
                    .foregroundColor(WOMP.text)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 44, minHeight: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(WOMP.line, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .frame(minHeight: 44) // 触屏命中区
            .accessibilityLabel("打开配置文件")
        }
        .padding(.bottom, 6)
    }

    // MARK: - provider 行卡列表

    private var providerList: some View {
        VStack(spacing: 0) {
            ForEach(store.endpoints) { endpoint in
                ProviderRowCardView(
                    endpoint: endpoint,
                    store: store,
                    isEditing: editingID == endpoint.id,
                    isRemoving: removingID == endpoint.id,
                    seam: credentialSeam,
                    discoverModels: discoverModels,
                    onToggleEdit: {
                        // 单展开（清单9）：开本卡即关他卡；再点收起。
                        // m7-fix2 M3①：折叠事务显式带原型 .58s 曲线（此前
                        // 依赖隐式动画被行级 0.25s 覆盖 → 闪回无动画）。
                        withAnimation(WOMP.ease(WOMP.durCollapse)) {
                            editingID = editingID == endpoint.id ? nil : endpoint.id
                        }
                    },
                    onRequestDelete: {
                        deleteTarget = endpoint
                    },
                    onEditClosed: { changed in
                        // m7-fix2 M3②：编辑卡关闭（取消/保存都走原型
                        // closeEditPanel 同一路径）→ 收起；changed=有提交
                        // 才并 saved 轻提示。收起事务显式带原型 .58s 曲线。
                        withAnimation(WOMP.ease(WOMP.durCollapse)) {
                            if editingID == endpoint.id { editingID = nil }
                        }
                        if changed { announceSaved() }
                    },
                    onCredentialNotice: { notice in
                        // 凭据存储描述只透传（不收卡——保存中段回调）。
                        credentialNotice = notice
                    })
                // 行卡入场（原型 .provider-item：opacity 0 + 上移 8 + scale .99）。
                // 显式 AnyTransition（iOS13+）——避免命中 iOS17 Transition 协议。
                .transition(AnyTransition.opacity
                    .combined(with: .offset(y: -8))
                    .combined(with: .scale(scale: 0.99)))
            }
        }
        .animation(WOMP.ease(WOMP.durCardIn), value: store.endpoints)
    }

    // MARK: - saved 轻提示（dsh announceSaved 语义；WOToast 承载）

    private func announceSaved() {
        var text = "已保存。"
        if let credentialNotice, !credentialNotice.isEmpty {
            // 凭据存储描述并入轻提示（Keychain/文件兜底透出——ERR-016 语义）。
            text += " \(credentialNotice)"
            // self. 限定：if-let 解包的同名局部常量遮蔽了 @State 成员。
            self.credentialNotice = nil
        }
        toast = text
    }

    // MARK: - 删除（清单13：二次确认 + 先 unset 凭据 + removing 出场）

    private func closeDelete() {
        if deleteInFlight { return }
        deleteTarget = nil
    }

    private func confirmDelete(_ endpoint: EndpointConfig) async {
        deleteInFlight = true
        defer { deleteInFlight = false }
        // 第一步：先删凭据（幂等——失败时行仍可见、整体可重试）。
        do {
            try credentialSeam.unset(endpoint)
        } catch {
            toast = "凭据清除失败：\((error as NSError).localizedDescription)"
            return
        }
        // 第二步：removing 出场折叠（.45s）→ 真正移除（store.remove 内部
        // 亦三清凭据——双删幂等无害）。
        let target = endpoint
        deleteTarget = nil
        removingID = target.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            store.remove(target)
            if editingID == target.id { editingID = nil }
            removingID = nil
        }
    }

    /// 删除确认两版描述（有凭据点明一并清除）。
    private func deleteMessage(for endpoint: EndpointConfig) -> String {
        credentialSeam.describe(endpoint).configured
            ? "「\(endpoint.displayName ?? endpoint.name)」已配置 API 密钥，删除将一并清除凭据，且无法恢复。"
            : "删除端点「\(endpoint.displayName ?? endpoint.name)」？此操作无法恢复。"
    }
}

// MARK: - 行卡（原型 .provider-item + 内联编辑面板挂载）

/// provider 行卡（原型 .provider-item 1:1；编辑面板常挂 WOCollapsible——
/// 单展开由父级 editingID 驱动）。
private struct ProviderRowCardView: View {

    let endpoint: EndpointConfig
    @ObservedObject var store: EndpointStore
    let isEditing: Bool
    let isRemoving: Bool
    let seam: ProviderCredentialSeam
    var discoverModels: ((String, String?) async -> Result<[DiscoveredModel], Error>)?
    let onToggleEdit: () -> Void
    let onRequestDelete: () -> Void
    /// 编辑卡收起（m7-fix2 M3②：取消/保存统一收起路径；changed=有提交落地）。
    let onEditClosed: (Bool) -> Void
    /// 凭据存储描述透传（保存中段回调，不触发收起）。
    let onCredentialNotice: (String?) -> Void

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            head
            WOCollapsible(open: isEditing) {
                ProviderEditorView(
                    store: store,
                    endpoint: endpoint,
                    credentialSeam: seam,
                    discoverModels: discoverModels,
                    onClose: { changed in
                        // 取消/保存统一收起（M3②）；凭据描述走独立通道。
                        onEditClosed(changed)
                    },
                    onCredentialNotice: { notice in
                        onCredentialNotice(notice)
                    })
                // 原型 .edit-panel margin 0 10 10。
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(Color.white)
        // m7-fix2 M4⑥：对齐原型 .provider-item { overflow: hidden }（:183）——
        // 白卡本体即唯一裁切边界，灰编辑面板（.edit-panel margin 0 10 10）是
        // 卡内嵌段，收合时卡整体连续、灰面板在白卡内高度收合（配合
        // WOCollapsible 关闭 opacity .28s 快隐 + mask 幕帘），杜绝白层盖到
        // 灰面上的视觉断层（用户录屏实证的白闪）。
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(borderColor, lineWidth: 1))
        .shadow(color: Color.black.opacity(isHovering ? 0.06 : 0.03),
                radius: isHovering ? 18 : 2, y: isHovering ? 6 : 1)
        .padding(.bottom, 10)
        .modifier(WORemoveFold(removing: isRemoving))
        .onHover { hovering = $0 } // hover 纯视觉增强（触屏直达不受影响）
        .animation(.easeOut(duration: 0.25), value: hovering)
        // m7-fix2 M3①：移除原 `.animation(.easeOut(0.25), value: isEditing)`
        // ——该行级动画包住整个子树（含 WOCollapsible 的 frame/opacity），
        // 以 0.25s 覆盖折叠容器的 .58s 原型曲线 → 收起闪回。边框编辑态变色
        // 随状态瞬切（原型 border-color .25s 的微小偏差，登记报告）。
    }

    /// hover/编辑态底色引用（阴影与边框共用判定）。
    private var isHovering: Bool { hovering && !isRemoving }

    private var borderColor: Color {
        if isRemoving { return WOMP.lineSoft }
        if isEditing { return WOMP.lineEditing } // 原型 .editing rgba(0,0,0,.14)
        return isHovering ? WOMP.lineHover : WOMP.lineSoft
    }

    // MARK: 行头（名称 + key 状态点 + 操作钮；原型 .provider-head）

    private var head: some View {
        HStack(spacing: 8) {
            Text(endpoint.displayName ?? endpoint.name)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(WOMP.text)
                .lineLimit(1)
            keyStatusDot
            Spacer(minLength: 8)
            WOMiniButton(title: "编辑") { onToggleEdit() }
            WOMiniButton(title: "删除", danger: true) { onRequestDelete() }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
    }

    /// key 状态点（绿=已配 + 光晕 0 0 0 3px rgba(34,197,94,.15)；灰=未配）。
    @ViewBuilder
    private var keyStatusDot: some View {
        let configured = seam.describe(endpoint).configured
        Group {
            if configured {
                Circle()
                    .fill(WOMP.green)
                    .frame(width: 6, height: 6)
                    .background(
                        Circle().fill(WOMP.greenHalo).frame(width: 12, height: 12)
                    )
                    .accessibilityLabel("已配置 API 密钥")
            } else {
                Circle()
                    .fill(WOMP.text3)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("未配置")
            }
        }
        .frame(width: 12, height: 12)
    }
}
