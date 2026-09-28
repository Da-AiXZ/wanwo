//
//  TeamBoardView.swift
//  WanWo
//
//  【M7 件 L · F046 · UI 最小呈现】派单落点⑦：花名册+任务板只读面（M7.5
//  验收 = "两 agent 邮箱互通"——UI 最小即可）。dsh agent-team-web-profile
//  不移植（登记）。
//  数据面：TeamService.teamView（index.ts remoteView :242-248 1:1 语义——
//  members + tasks 投影）。会话选择 = AppEnvironment 当前选中会话；非 Team
//  成员 / 无选择 → 引导文案（只读，零操作面）。
//

import SwiftUI

/// Agent Teams 花名册+任务板（只读；设置·Teams 入口）。
struct TeamBoardView: View {
    let environment: AppEnvironment

    @State private var view: TeamView?
    @State private var failureText: String?
    @State private var reloadToken = 0

    /// 当前选中会话（Team 归属判定与投影 rootId 供值）。
    private var selectedSessionId: String? {
        if case .session(let id) = environment.selection { return id }
        return nil
    }

    var body: some View {
        Group {
            if let sessionId = selectedSessionId {
                content(sessionId: sessionId)
            } else {
                hint("未选择会话——Agent Teams 以顶层会话为隐式 Team 根，先选择一个会话。")
            }
        }
        .navigationTitle("Teams")
    }

    @ViewBuilder
    private func content(sessionId: String) -> some View {
        if let failureText {
            hint(failureText)
        } else if let view {
            List {
                Section("花名册") {
                    ForEach(Array(view.members.enumerated()), id: \.offset) { _, member in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(member.name)
                                    .font(.system(size: 15, weight: .semibold))
                                Text(member.role)
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                Spacer()
                                Text(member.status)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            if let description = member.description {
                                Text(description)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            ForEach(Array(member.diagnostics.enumerated()),
                                    id: \.offset) { _, diagnostic in
                                Text(diagnostic)
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                Section("任务板") {
                    if view.tasks.isEmpty {
                        Text("暂无任务")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    ForEach(Array(view.tasks.enumerated()), id: \.offset) { _, task in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(task.subject)
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Text(task.status.rawValue)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            HStack(spacing: 10) {
                                Text(task.id)
                                Text("r\(task.revision)")
                                if let ownerName = task.ownerName {
                                    Text("owner: \(ownerName)")
                                }
                                if task.ready { Text("ready") }
                            }
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            if !task.blockedBy.isEmpty {
                                Text("blockedBy: " + task.blockedBy.joined(separator: ", "))
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                            }
                            ForEach(Array(task.writeScopeWarnings.enumerated()),
                                    id: \.offset) { _, warning in
                                Text(warning)
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    reloadToken += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .padding(12)
                        .background(Circle().fill(.thinMaterial))
                }
                .padding(16)
                .accessibilityLabel("刷新")
            }
            // QA-6 P2-2：task id 含 sessionId 组合——切换会话后重载不因
            // reloadToken 未变而跳过。
            .task(id: "\(sessionId)#\(reloadToken)") { await load(sessionId: sessionId) }
        } else {
            ProgressView()
                .task(id: "\(sessionId)#\(reloadToken)") { await load(sessionId: sessionId) }
        }
    }

    private func hint(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load(sessionId: String) async {
        do {
            view = try await environment.teamService.teamView(sessionId)
            failureText = nil
        } catch {
            view = nil
            failureText = (error as? TeamError)?.message ?? String(describing: error)
        }
    }
}
