//
//  SessionsSidebarView.swift
//  WanWo
//
//  【按设计新写 · 非原件】出处：10-design §7.1（侧栏：会话列表 + 新建会话 + 设置）、
//  §十一 M1.1（会话列表 UI：新建/列表/删除）、§7.4（视觉素净占位）。
//  M0 回归入口（ShellTestView）保留在「诊断」段（M0 验收仍可过）。
//

import SwiftUI

struct SessionsSidebarView: View {
    @ObservedObject var environment: AppEnvironment
    @Binding var selection: RootSelection

    @State private var summaries: [SessionSummary] = []
    @State private var creating = false
    /// 待确认删除的行号集（A6：滑动删除 → 确认对话框 → 执行）。
    @State private var pendingDeleteOffsets: IndexSet?

    var body: some View {
        List {
            Section {
                Button {
                    newSession()
                } label: {
                    Label("新建会话", systemImage: "plus.circle")
                }
                .disabled(creating)
            }

            Section("会话") {
                if summaries.isEmpty {
                    Text("暂无会话")
                        .foregroundStyle(.secondary)
                }
                ForEach(summaries) { summary in
                    Button {
                        selection = .session(id: summary.id)
                    } label: {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.title ?? "新会话")
                                    .lineLimit(1)
                                Text(summary.updatedAt.formatted(.dateTime.month().day().hour().minute()))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            // M3 T1：琥珀警示圆点（dsh 2026-07-23 笔记——sidebar
                            // mirrors every blocked interaction with an amber
                            // warning dot that outranks the running ring；
                            // WanWo 侧栏暂无运行中圆环，见批次报告偏差登记）。
                            if environment.pendingInteractionSessionIDs.contains(summary.id) {
                                Circle()
                                    .fill(ApprovalPanelStyle.warnPrimary)
                                    .frame(width: 8, height: 8)
                                    .accessibilityLabel("有待决审批或提问")
                            }
                        }
                    }
                }
                .onDelete { indexSet in
                    // M3 T2.2 A6：删除前确认（滑动删除不再直删——派单项 6）。
                    pendingDeleteOffsets = indexSet
                }
            }

            Section("设置") {
                Button {
                    selection = .providers
                } label: {
                    Label("Providers", systemImage: "cpu")
                }
                Button {
                    // M3 T2.2：设置·新会话默认权限行（PermissionRow.tsx 1:1；
                    // P1-4 后唯一权限入口——规则 CRUD 页随 F022 砍除）。
                    selection = .permissionDefaults
                } label: {
                    Label("权限", systemImage: "lock.shield")
                }
            }

            Section("诊断") {
                Button {
                    selection = .shellTest
                } label: {
                    Label("Shell 测试（M0）", systemImage: "terminal")
                }
                Button {
                    // M2.8 只读事件流诊断页（页内自选会话，取更简单方案）。
                    selection = .eventStream
                } label: {
                    Label("事件流", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("万我")
        .task { await reload() }
        .onChange(of: environment.sessionsRevision) { _ in
            Task { await reload() }
        }
        // M3 T2.2 A6：删除确认对话框（滑动删除不直删）。
        .confirmationDialog(
            "删除会话？该操作不可撤销。",
            isPresented: Binding(get: { pendingDeleteOffsets != nil },
                                 set: { if !$0 { pendingDeleteOffsets = nil } }),
            titleVisibility: .visible) {
            Button("删除会话", role: .destructive) {
                if let offsets = pendingDeleteOffsets {
                    delete(at: offsets)
                }
                pendingDeleteOffsets = nil
            }
            Button("取消", role: .cancel) { pendingDeleteOffsets = nil }
        }
    }

    private func reload() async {
        summaries = await environment.loadSessions()
    }

    private func newSession() {
        creating = true
        Task {
            if let summary = await environment.createSession() {
                selection = .session(id: summary.id)
            }
            creating = false
        }
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { summaries[$0].id }
        Task {
            for id in ids {
                await environment.deleteSession(id: id)
            }
        }
    }
}
