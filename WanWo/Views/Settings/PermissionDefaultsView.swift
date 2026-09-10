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
        }
        .navigationTitle("权限")
        .navigationBarTitleDisplayMode(.inline)
        // Full access 风险确认（PermissionRow.tsx:81-85 特判 + :105-125 面板）。
        // P2-⑫：呈现由 sheet 改居中模态（dsh RiskConfirmation 对话框形态）。
        .fullScreenCover(isPresented: $confirmingFullAccess, onDismiss: { acknowledged = false }) {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
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
