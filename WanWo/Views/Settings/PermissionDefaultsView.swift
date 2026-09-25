//
//  PermissionDefaultsView.swift
//  WanWo
//
//  【dsh Web UI 原件移植 · M3 T2.2】设置·新会话默认权限行（权限入口③；
//  T2.2 派单项 2）。出处（packages/client/ui-permission-presets）：
//    - src/client/PermissionRow.tsx:1-5 —— 权限行 = 「the default preset for
//      subsequently created sessions」：App 级新会话默认，与当前会话旋钮分离。
//    - :36-37 —— Render the new-session Permission default selector。
//    - :41-64 —— 行形态：title「权限」+ desc「选择新会话的默认权限模式」+
//      三挡 Menu 下拉（chevron 触发器；busy/不可写禁用）。
//    - :81-85 + :105-125 —— Full access 特判 → RiskConfirmation（四段文案
//      zh:12-16 逐字：「新会话将减少确认步骤…后续任务」变体）。
//    - src/client/settings-store.ts:131-161 —— select 持久化默认值（WanWo
//      宿主面 = PermissionDefaultStore JSON 持久文件）。
//    - src/client/locales.ts:5-16 —— zh 文案逐字（title/description/三挡名/
//      确认四段）。
//  P1-4：规则 CRUD 入口随 F022 砍除——本页为唯一权限设置面。
//

import SwiftUI

/// 设置 · 权限（新会话默认预设选择器；PermissionRow.tsx 1:1）。
/// T2.4 P1-4：store 改 ObservedObject 直持——setDefault 的 objectWillChange
/// 即时联动本页（原读侧不经发布器，挡位显示要重进页面才刷新）。
struct PermissionDefaultsView: View {
    @ObservedObject private var store: PermissionDefaultStore
    /// 设备命令权限段数据源（2026-09-25 M6 欠账补齐）：OffloadPermissionManager
    /// 的档位存 UserDefaults（无 @Published），切档后经 objectWillChange.send()
    /// 强制本页刷新（ObservedObject 订阅此信号）。
    @ObservedObject private var offloadManager = OffloadPermissionManager.shared

    @State private var confirmingFullAccess = false
    @State private var acknowledged = false

    init(environment: AppEnvironment) {
        _store = ObservedObject(wrappedValue: environment.permissionDefaults)
    }

    /// 三挡选项（dsh settings schema 动态枚举对 defaultPreset 广播的三挡；
    /// 文案 = locales.ts:9-11 逐字）。
    private var options: [(id: String, label: String)] {
        [
            ("read-only", "仅可查看"),
            ("workspace-write", "工作区内修改"),
            ("danger-full-access", "完全权限"),
        ]
    }

    private var currentLabel: String {
        options.first { $0.id == store.defaultPreset }?.label
            ?? store.defaultPreset
    }

    var body: some View {
        List {
            // 新会话默认预设行（PermissionRow.tsx:66-104 1:1：左文案右下拉）。
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("权限")
                            .font(.headline)
                        Text("选择新会话的默认权限模式")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        ForEach(options, id: \.id) { option in
                            Button {
                                choose(option.id)
                            } label: {
                                if option.id == store.defaultPreset {
                                    Label(option.label, systemImage: "checkmark")
                                } else {
                                    Text(option.label)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(currentLabel)
                                .font(.footnote)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("仅对之后新建的会话生效；当前会话的权限挡位在聊天输入框的挡位下拉或 /permission 命令切换。")
            }

            // MARK: 设备命令权限段（2026-09-25 M6 交付欠账补齐）
            //
            // 验收标准"设置-权限页可见 27 命令档位"（m6-acceptance-morning §四.2）
            // 此前从未实现——askOnce 审批卡又挂在死视图上（WORootFrame 迁移同批
            // 修复），形成"弹不出+开不了"死路闭环（M6 真机测试 17 个 askOnce
            // 命令全军覆没的两大根因）。本段 = OpenMinis OffloadPermissionManager
            // showInSettings 元数据的消费页（数据层 M6 B1a 已备，UI 本批补齐）。
            //
            // 全 27 命令列出（不按 showInSettings 过滤）——用户为唯一用户，
            // 全量透明优于原件的"仅隐私类"裁剪；档位三选（免问/每次问/禁止），
            // 写 OffloadPermissionManager 持久化（offloadPermission.<cmd>，
            // 与 OpenMinis 存储形态一致），下次调用立即生效。
            Section("设备命令权限（AI 调用 iPad 能力的开关）") {
                ForEach(offloadGroups, id: \.title) { group in
                    ForEach(group.commands, id: \.name) { cmd in
                        offloadRow(cmd)
                    }
                }
            } footer: {
                Text("「免问」= AI 直接调用；「每次问」= 弹确认卡、本会话内允许一次后免弹；「禁止」= 直接拒绝。修改立即生效。")
            }
        }
        .navigationTitle("权限")
        .navigationBarTitleDisplayMode(.inline)
        // Full access 风险确认（PermissionRow.tsx:81-85 特判 + :105-125 面板）。
        // P2-⑫：呈现由 sheet 改居中模态（dsh RiskConfirmation 对话框形态）。
        // P1-6：去全屏遮罩——dsh RiskConfirmation 挂 PopupSelectView（anchored
        // popup 家族）无全屏遮罩，仅呈现居中确认卡。
        .fullScreenCover(isPresented: $confirmingFullAccess, onDismiss: { acknowledged = false }) {
            ZStack {
                confirmSheet
            }
            .presentationBackground(.clear)
        }
    }

    // MARK: - 选择（dsh onSelect :78-87 语义）

    private func choose(_ id: String) {
        if id == store.defaultPreset { return }
        if id == "danger-full-access" {
            acknowledged = false
            confirmingFullAccess = true
            return
        }
        _ = store.setDefault(named: id)
    }

    // MARK: - 设备命令权限段（2026-09-25 M6 欠账补齐，见 Section 注）

    /// 27 命令按类别分组（序=OffloadPermissionManager 注册序）。
    private var offloadGroups: [(title: String, commands: [OffloadCommandInfo])] {
        let titles: [OffloadCommandCategory: String] = [
            .privacy: "隐私", .media: "媒体", .system: "系统",
        ]
        return OffloadCommandCategory.allCases.map { category in
            (title: titles[category] ?? category.rawValue,
             commands: OffloadPermissionManager.shared.allCommands
                .filter { $0.category == category })
        }
    }

    /// 档位中文名（与 footer 说明用词一致）。
    private func offloadLevelLabel(_ level: OffloadPermissionLevel) -> String {
        switch level {
        case .bypass: return "免问"
        case .askOnce: return "每次问"
        case .notAllowed: return "禁止"
        }
    }

    /// 单命令行（左=名+说明，右=三档 Menu——与上段默认预设 Menu 同款交互）。
    private func offloadRow(_ cmd: OffloadCommandInfo) -> some View {
        let current = offloadManager.permissionLevel(for: cmd.name)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(cmd.displayLabel)
                    .font(.subheadline)
                Text(cmd.name)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if !cmd.description.isEmpty {
                    Text(cmd.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Menu {
                ForEach(OffloadPermissionLevel.allCases, id: \.rawValue) { level in
                    Button {
                        offloadManager.setPermissionLevel(level, for: cmd.name)
                        // 档位存 UserDefaults 无 @Published——手动触发刷新
                        // （ObservedObject 订阅 objectWillChange）。
                        offloadManager.objectWillChange.send()
                    } label: {
                        if level == current {
                            Label(offloadLevelLabel(level), systemImage: "checkmark")
                        } else {
                            Text(offloadLevelLabel(level))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(offloadLevelLabel(current))
                        .font(.footnote)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// RiskConfirmation 四段文案 = locales.ts:12-16 zh 逐字（新会话变体：
    /// 「新会话将减少确认步骤……仅建议在你信任后续任务时使用」）。
    private var confirmSheet: some View {
        RiskConfirmationView(
            title: "确认启用完全权限？",
            description: "启用完全权限后，新会话将减少确认步骤，并且可以直接执行更多操作，"
                + "包括敏感操作、文件修改或外部命令。仅建议在你信任后续任务时使用。",
            acknowledgeLabel: "我已了解风险，并愿意继续",
            cancelLabel: "取消",
            confirmLabel: "启用完全权限",
            acknowledged: $acknowledged,
            onCancel: { confirmingFullAccess = false },
            onConfirm: {
                confirmingFullAccess = false
                _ = store.setDefault(named: "danger-full-access")
            })
    }
}
