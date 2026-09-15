//
//  OffloadPermissionDialog.swift
//  WanWo
//
//  【vendored 复用 · 源=OpenMinis src/ios/Views/Chat/OffloadPermissionDialog.swift
//   全文 128 行，语义 1:1（B1c ④审批卡接线）】
//  `askOnce` 档 offload 命令的权限确认卡（sheet 形态）。
//  适配点（其余逐行 1:1）：
//   1. ObservedObject 目标：OffloadPermissionManager.shared（其 @Published
//      pendingRequest 在 B1a 缝化时删除）→ OffloadApprovalPresenter.shared
//      （呈现侧状态宿主；应答走 presenter.respond → 缝应答闭包回写 manager）；
//   2. 挂载点：原件挂 ContentView，WanWo 挂 RootView（.offloadPermissionDialog()
//      全局覆盖——offload 审批可来自任意会话的内核分发点，非单会话面）。
//   3. 文件头注释出处注记。
//

import SwiftUI

struct OffloadPermissionDialogModifier: ViewModifier {
    @ObservedObject private var presenter = OffloadApprovalPresenter.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $presenter.pendingRequest) { request in
                OffloadPermissionDialogContent(request: request)
                    // Both detents — long arg lists were getting pushed below
                    // the medium detent's bottom edge with the Allow / Deny
                    // buttons trailing them, leaving no way to respond. Allow
                    // dragging up to .large; the content is scrollable in
                    // either height.
                    .presentationDetents([.medium, .large])
                    .interactiveDismissDisabled()
            }
    }
}

private struct OffloadPermissionDialogContent: View {
    let request: PermissionRequest

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable content. Long argument lists previously stretched the
            // outer VStack past the sheet height and pushed the Allow / Deny
            // buttons below the bottom edge with no way to scroll to them.
            // Pinning the buttons in a separate sibling and wrapping the rest
            // in a ScrollView guarantees the action row is always visible.
            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)

                        Text("Permission Request")
                            .font(.title3.bold())

                        Text("The agent wants to use **\(request.commandName)**")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                    // Description
                    if !request.description.isEmpty {
                        Text(request.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }

                    // Arguments
                    let args = request.parsedArguments
                    if !args.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(args.enumerated()), id: \.offset) { idx, arg in
                                HStack {
                                    Text(arg.key)
                                        .font(.footnote.bold())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 80, alignment: .trailing)
                                    Text(arg.value)
                                        .font(.footnote.monospaced())
                                        .lineLimit(2)
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                if idx < args.count - 1 {
                                    Divider().padding(.leading, 108)
                                }
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                }
            }

            // Buttons — pinned to the bottom of the sheet, outside the
            // ScrollView, so they stay tappable even with very long arg lists.
            VStack(spacing: 10) {
                Button {
                    OffloadApprovalPresenter.shared.respond(to: request.id, allowed: true)
                } label: {
                    Text("Allow in Session")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button {
                    OffloadApprovalPresenter.shared.respond(to: request.id, allowed: false)
                } label: {
                    Text("Deny in Session")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 30)
            .background(Color(.systemGroupedBackground))
        }
        .background(Color(.systemGroupedBackground))
    }
}

extension View {
    func offloadPermissionDialog() -> some View {
        modifier(OffloadPermissionDialogModifier())
    }
}
