//
//  MountedFoldersSettingsView.swift
//  WanWo
//
//  【UI 对齐批 1 · 工作项 1A：呈现链照 OpenMinis 原件整段恢复】
//  原件：repos/OpenMinis-main/src/ios/Views/Settings/MountedFoldersSettingsView.swift
//    · :16-26  PendingMount（Identifiable 状态载体，驱动 .sheet(item:)）
//    · :95-170 双 sheet 结构（.sheet(isPresented:) picker + .sheet(item:) 命名卡）
//    · :107-128 竞态注释纪律（"iOS refuses to stack two sheets…hop one runloop"）
//    · :129-161 命名卡从 pending 闭包参数读值（Optional binding 重路由瞬时 nil）
//    · :404-425 FolderPicker 与 Coordinator
//
//  「选完文件夹点打开没反应」真机实证：picker 关闭后 didPickDocumentsAt 从未回调
//  ——断在选择器呈现链。前两版自创修法（①0×0 Color.clear 挂 fullScreenCover
//  ②ZStack overlay 自绘卡）治错环节，全部废除：
//    · 批2 B③：fullScreenCover 挂 0×0 Color.clear —— 已废；
//    · 批4：ZStack overlay 自绘命名卡（addMountOverlay/addMountSheet 包装层 +
//      body ZStack 改造）—— 本批删除，呈现链恢复原件双 sheet 形态：picker 用
//      .sheet(isPresented:)，命名确认卡用 .sheet(item:) 真第二弹窗，onPick 回调里
//      DispatchQueue.main.async 跳一拍再赋 pendingMount（原件 :118-126 同构）。
//    · AddMountSheet 内容件本身保留复用（作为 .sheet(item:) 内容）。
//    · 批4 过渡动画纪律（spring 0.3/0.85）改由系统 sheet 呈现/收束动画承接，
//      overlay 自定义 transition 随之删除。
//
//  承接原件的状态机/校验纪律（保留）：
//    · 名称校验 = MountedFolderEntry.isValidMountName（无 /、非空、非 . / ..）
//    · 双层写开关呈现：R/W（OS 可写+用户放行）/ Locked（OS 可写+用户锁）/ 只读
//      （OS 探测不可写）= accessBadge 三态语义
//    · 默认挂载名建议：iCloud 容器 Documents 目录反推 app slug（trivial 后缀剔除）
//    · 目录选择 = UIDocumentPickerViewController(.folder)（dsh pick 动词的 iOS
//      不可抗力映射）
//    · 「添加挂载文件夹」实体按钮行保留（设置面板无 NavigationStack、toolbar
//      不渲染的既有教训）；model.add 失败必弹 alert。
//

import SwiftUI
import UniformTypeIdentifiers

private let mountUILogger = AppLogger(category: "MountedFoldersUI")

/// Add-Mount 表单的状态载体（原件 PendingMount 同形，:21-26；驱动
/// `.sheet(item:)`——保证 sheet 构造时 URL 必在；两个 .sheet(isPresented:)
/// 叠用首次选择会竞态：AddMountSheet 先于 pendingPickedURL 传播构造，
/// "Source path" 段渲染为空）。
private struct PendingMount: Identifiable {
    let id = UUID()
    let url: URL
    var name: String
    var allowWrite: Bool
}

/// 设置·外挂载文件夹管理页（挂 WanWo 设置页体系，侧栏「设置」段进入）。
struct MountedFoldersSettingsView: View {
    @StateObject private var model = MountedFoldersViewModel()
    @State private var showingPicker = false
    @State private var pendingMount: PendingMount?
    @State private var errorText: String?
    /// 详情编辑态（rename / allowWrite / 刷新可写性）。`entry.id == nil` 视为关闭。
    @State private var detailEntryID: UUID?

    var body: some View {
        List {
            Section {
                infoBanner
            }

            // 添加入口实体化：SettingsPanelView 容器无 NavigationStack，
            // .toolbar 内的「+」在其中不渲染（等于消失）——List 显式行，
            // 两种容器（面板 / RootView detail）下均可见可用。
            Section {
                Button {
                    showingPicker = true
                } label: {
                    Label("添加挂载文件夹", systemImage: "plus.circle.fill")
                }
                .disabled(model.isAtCapacity)
            }

            if model.entries.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "externaldrive.badge.plus")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("暂无外挂文件夹")
                            .font(.headline)
                        Text("点上方「添加挂载文件夹」，从「文件」App 中选择一个文件夹（如 iCloud Drive 里的资料库）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section {
                    ForEach(model.entries) { entry in
                        Button {
                            detailEntryID = entry.id
                        } label: {
                            mountedFolderRow(entry)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                model.remove(id: entry.id)
                            } label: {
                                Label("移除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("已挂载文件夹")
                        Spacer()
                        Text("\(model.entries.count) / \(MountedFoldersManager.maxMountCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(model.isAtCapacity ? .orange : .secondary)
                    }
                } footer: {
                    if model.isAtCapacity {
                        Text("已达挂载上限，请先移除一个现有挂载。")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("外挂载文件夹")
        .navigationBarTitleDisplayMode(.inline)
        // 【批 1 工作项 1A】呈现链恢复原件 :107-128 双 sheet 第一环：
        // picker 用 .sheet(isPresented:)。
        .sheet(isPresented: $showingPicker) {
            FolderPicker { url in
                // `UIDocumentPickerViewController` 的 `didPickDocumentsAt` 委托
                // 回调在 SwiftUI 已开始 dismiss picker sheet 之后才到，而第二
                // 张 sheet 必须等退场彻底完成才能提呈——iOS 拒绝叠两张 sheet，
                // 此处同步赋 pendingMount 会在首次选择时静默丢掉提呈。跳到下一
                // 个 runloop tick 让 picker sheet 先离开视图层级（原件 :109-126
                // 竞态注释纪律逐语义保留）。
                mountUILogger.info("FolderPicker onPick url=\(url.path)")
                DispatchQueue.main.async {
                    let pm = PendingMount(
                        url: url,
                        name: Self.defaultMountName(for: url),
                        allowWrite: true
                    )
                    mountUILogger.info("async assign pendingMount id=\(pm.id.uuidString) url=\(url.path)")
                    pendingMount = pm
                }
            }
        }
        // 【批 1 工作项 1A】命名确认卡 = 原件 :129-161 双 sheet 第二环：
        // .sheet(item:) 真第二弹窗（非 overlay）。
        .sheet(item: $pendingMount) { pending in
            // 重要：从 `pending` 闭包参数读值而非 `pendingMount?.url`——Optional
            // 状态绑定在 SwiftUI 重路由 sheet 的瞬时 nil 会清空来源路径字段
            // （原件 :130-133 同纪律）。
            AddMountSheet(
                sourceURL: pending.url,
                name: Binding(
                    get: { pendingMount?.name ?? pending.name },
                    set: { pendingMount?.name = $0 }
                ),
                allowWrite: Binding(
                    get: { pendingMount?.allowWrite ?? pending.allowWrite },
                    set: { pendingMount?.allowWrite = $0 }
                ),
                onCancel: {
                    mountUILogger.info("add mount cancelled by user url=\(pending.url.path)")
                    pendingMount = nil
                },
                onConfirm: {
                    let current = pendingMount ?? pending
                    do {
                        let entry = try model.add(
                            pickedURL: current.url,
                            customName: current.name,
                            userAllowWrite: current.allowWrite
                        )
                        mountUILogger.info("model.add success id=\(entry.id.uuidString) name=\(entry.name)")
                    } catch {
                        mountUILogger.info("model.add failed url=\(current.url.path) name=\(current.name) error=\(error.localizedDescription)")
                        errorText = error.localizedDescription
                    }
                    pendingMount = nil
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { detailEntryID != nil },
            set: { if !$0 { detailEntryID = nil } }
        )) {
            if let id = detailEntryID {
                MountDetailView(model: model, entryID: id)
            }
        }
        .alert("错误", isPresented: Binding(get: { errorText != nil },
                                          set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: - 子视图（素净版，原件行/徽章语义保留）

    private var infoBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("挂载外部文件夹", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
            Text("选择的文件夹会挂载到 /var/wanwo/mounts/<名称>，可直接在 iSH 终端与 AI 会话中读写（受下方写权限控制）。最多同时挂载 \(MountedFoldersManager.maxMountCount) 个。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 行视图：名称 + 挂载点 + 来源 + 写权限三态徽章（原件 MountedFolderRow 语义）。
    @ViewBuilder
    private func mountedFolderRow(_ entry: MountedFolderEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                Text(entry.name)
                    .font(.body.weight(.medium))
                accessBadge(entry)
                Spacer()
            }
            Text("\(WanWoPaths.mountsLinuxDir)/\(entry.name)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: "← \(model.resolvedURL(for: entry.id)?.path ?? entry.sourceDisplayName)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    /// 写权限三态徽章（原件 accessBadge 语义 1:1）：
    /// - "只读"：OS 层探测不可写（用户选择 n/a）
    /// - "已锁"：OS 可写但用户关掉了 Allow Writes
    /// - "可写"：OS 可写且用户放行
    @ViewBuilder
    private func accessBadge(_ entry: MountedFolderEntry) -> some View {
        if !entry.isWritable {
            badgePill(text: "只读", color: .orange)
        } else if !entry.userAllowWrite {
            badgePill(text: "已锁", color: .purple)
        } else {
            badgePill(text: "可写", color: .green)
        }
    }

    private func badgePill(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1)
            )
    }

    // MARK: - 默认挂载名建议（原件 :197-250 defaultMountName 语义 1:1）

    /// iCloud 容器 id 尾段的琐碎公司后缀（`iCloud~com~x~inc` 的 "inc"），选
    /// 默认名时跳过。
    private static let trivialSuffixes: Set<String> = [
        "inc", "ltd", "llc", "app", "co", "corp", "gmbh"
    ]

    /// iCloud Drive 的 app 目录结构常为
    /// `.../Mobile Documents/iCloud~<team>~<bundle>/Documents/`——lastPathComponent
    /// 恒为 "Documents" 无辨识度；检测该形态改从父容器反推最有意义的段
    /// （如 `iCloud~com~nssurge~inc` → `nssurge` 而非 `inc`）。
    static func defaultMountName(for url: URL) -> String {
        let lastName = url.lastPathComponent
        let candidate: String
        if lastName == "Documents" {
            let parent = url.deletingLastPathComponent()
            let parentName = parent.lastPathComponent
            if parentName.hasPrefix("iCloud~") {
                let parts = parentName.split(separator: "~").map(String.init)
                let remaining = Array(parts.dropFirst(2)) // 去 "iCloud" + team 段
                let best = remaining.reversed().first { segment in
                    !Self.trivialSuffixes.contains(segment.lowercased())
                } ?? remaining.last ?? parts.last ?? lastName
                candidate = best
            } else if !parentName.isEmpty {
                candidate = parentName
            } else {
                candidate = lastName
            }
        } else {
            candidate = lastName
        }

        let cleaned = candidate
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "mount" : cleaned
    }
}

// MARK: - 新建挂载表单（原件 :328-397 AddMountSheet 状态机/校验 1:1；
// 批 1 起作为 .sheet(item:) 内容复用——呈现通道换，内容件不动）

private struct AddMountSheet: View {
    let sourceURL: URL?
    @Binding var name: String
    @Binding var allowWrite: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                if let url = sourceURL {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("来源路径")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(url.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    } footer: {
                        Text("以上是 iOS 暴露该文件夹的路径，可用于确认数据归属的应用。")
                            .font(.caption2)
                    }
                }

                Section(header: Text("挂载名称")) {
                    TextField("名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("将成为 /var/wanwo/mounts/ 下的文件夹名")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(isOn: $allowWrite) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("允许写入")
                            Text(allowWrite
                                 ? "AI、终端将可修改此挂载中的文件。"
                                 : "此挂载将以只读方式暴露。适合不想让 AI 改动的参考资料库。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("权限")
                } footer: {
                    Text("之后可在挂载详情页修改写权限。")
                        .font(.caption)
                }
            }
            .navigationTitle("新建挂载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("挂载", action: onConfirm)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - 挂载详情页（原件 MountDetailView 状态机/校验逻辑：重命名 + 双层写开关 + 刷新可写性 + 激活状态呈现）

struct MountDetailView: View {
    /// 观察共享 ViewModel（entries/states 由 MountedFoldersManager 单例刷新）。
    @ObservedObject var model: MountedFoldersViewModel
    let entryID: UUID

    @State private var name: String = ""
    @State private var allowWrite: Bool = true
    @State private var errorText: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let entry = model.entry(for: entryID) {
                    Section("挂载点") {
                        Text("\(WanWoPaths.mountsLinuxDir)/\(entry.name)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text("来源：\(model.resolvedURL(for: entry.id)?.path ?? entry.sourceDisplayName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Section("状态") {
                        activationStateRow
                    }

                    Section("名称") {
                        TextField("名称", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("重命名") {
                            do {
                                try model.rename(id: entryID, to: name)
                            } catch {
                                errorText = error.localizedDescription
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || name == entry.name)
                    }

                    Section {
                        Toggle(isOn: $allowWrite) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("允许写入")
                                Text(allowWrite
                                     ? "AI、终端将可修改此挂载中的文件。"
                                     : "此挂载将以只读方式暴露。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!(model.entry(for: entryID)?.isWritable ?? true))
                        if !(model.entry(for: entryID)?.isWritable ?? true) {
                            // OS 层探测不可写：用户开关无效（effectiveWritable
                            // 双层开关的 OS 层闸门已关——原件 MountDetailView 同纪律）。
                            Text("来源文件夹在系统层不可写，本挂载恒为只读。可尝试「重新探测可写性」。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Button("重新探测可写性") {
                            model.refreshWritability(id: entryID)
                        }
                    } header: {
                        Text("权限")
                    } footer: {
                        Text("实际写入能力 = 系统层可写 且 此开关打开（双层开关）。")
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("挂载详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                if let entry = model.entry(for: entryID) {
                    name = entry.name
                    allowWrite = entry.userAllowWrite
                }
            }
            .onChange(of: allowWrite) { newValue in
                model.setUserAllowWrite(id: entryID, to: newValue)
            }
            .alert("错误", isPresented: Binding(get: { errorText != nil },
                                              set: { if !$0 { errorText = nil } })) {
                Button("好", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    /// 激活状态行（原件 MountDetailView 状态机呈现：active/stale/permissionDenied/
    /// failed/contentsUnavailable 五态文案化）。
    @ViewBuilder
    private var activationStateRow: some View {
        let state = model.state(for: entryID)
        switch state {
        case .active(let url):
            Label("已激活 · \(url.path)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(2)
        case .stale:
            Label("书签已失效（可尝试重新挂载）", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .permissionDenied:
            Label("安全作用域被拒绝（重新授权后可用）", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.orange)
        case .contentsUnavailable:
            Label("内容未就绪：请打开「文件」App 浏览一次该文件夹以唤醒云盘提供方。", systemImage: "icloud.slash")
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed(let msg):
            Label("激活失败：\(msg)", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }
}

// MARK: - 目录选择器（原件 :401-424 FolderPicker 1:1 + 批 1 补取消日志；
// dsh pick 动词的 iOS 不可抗力映射 = UIDocumentPicker(.folder)）

struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }

        /// 批 1 增补：用户取消硬日志（picker 取消路径与「选了没反应」在
        /// 真机日志中必须可区分——取消时 sheet 自动退场，无需手动 dismiss）。
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            mountUILogger.info("documentPickerWasCancelled (user cancelled folder pick)")
        }
    }
}

// MARK: - ViewModel（原件 :428-485 MountedFoldersViewModel 语义 1:1）

@MainActor
final class MountedFoldersViewModel: ObservableObject {
    @Published private(set) var entries: [MountedFolderEntry] = []
    @Published private(set) var states: [UUID: MountActivationState] = [:]

    var isAtCapacity: Bool {
        entries.count >= MountedFoldersManager.maxMountCount
    }

    init() {
        refresh()
    }

    func refresh() {
        entries = MountedFoldersManager.shared.entries
        states = MountedFoldersManager.shared.activationStates
    }

    func entry(for id: UUID) -> MountedFolderEntry? {
        entries.first { $0.id == id }
    }

    func state(for id: UUID) -> MountActivationState {
        states[id] ?? .failed("")
    }

    /// Resolved host URL for a mount, if currently active. Exposed to row views
    /// so they can display the underlying iOS filesystem path.
    func resolvedURL(for id: UUID) -> URL? {
        MountedFoldersManager.shared.resolvedURL(for: id)
    }

    @discardableResult
    func add(pickedURL: URL, customName: String, userAllowWrite: Bool) throws -> MountedFolderEntry {
        // The document picker gives a URL with scope active; start it once more
        // defensively so MountedFoldersManager's bookmarkData call inside succeeds.
        let started = pickedURL.startAccessingSecurityScopedResource()
        defer { if started { pickedURL.stopAccessingSecurityScopedResource() } }
        let entry = try MountedFoldersManager.shared.add(
            pickedURL: pickedURL,
            customName: customName,
            userAllowWrite: userAllowWrite
        )
        refresh()
        return entry
    }

    func remove(id: UUID) {
        MountedFoldersManager.shared.remove(id: id)
        refresh()
    }

    func rename(id: UUID, to newName: String) throws {
        try MountedFoldersManager.shared.rename(id: id, to: newName)
        refresh()
    }

    func setUserAllowWrite(id: UUID, to allow: Bool) {
        MountedFoldersManager.shared.setUserAllowWrite(id: id, to: allow)
        refresh()
    }

    func refreshWritability(id: UUID) {
        MountedFoldersManager.shared.refreshWritability(id: id)
        refresh()
    }
}
