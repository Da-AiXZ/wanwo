//
//  WOAddWorkspaceModal.swift
//  WanWo
//
//  批10 抽取共用（原 WOWorkspaceBrowser.swift 内嵌 Modal）：「输入名字就是
//  添加工作区的全部」三入口统一弹窗——侧栏 +、空态 hero 芯片菜单、会话内
//  hero 芯片菜单共用本件（2026-09-22 用户令：统一用左侧栏添加的这张卡，
//  暗灰背景底色去掉——蒙层改透明点外关，卡浮于当前内容之上，形态对齐
//  RiskConfirmation 权限警告弹窗的白卡轻影）。
//  状态机自包含（name/busy/duplicate/error/commit——duplicate=registry 查重，
//  dsh conflict.named 文案；commit=WorkspaceAdoption.adopt，导航/提示由宿主
//  onAdopted 回调决定：侧栏=只建+toast，对话域=adopt 后 startSession 打开）。
//

import SwiftUI

struct WOAddWorkspaceModal: View {
    @EnvironmentObject private var environment: AppEnvironment
    /// 呈现绑定（宿主持有；本件 commit 成功/点外/取消均写 false）。
    @Binding var isPresented: Bool
    /// 采纳成功回调（工作区已建/复用；宿主决定后续——toast/导航/startSession）。
    var onAdopted: (WorkspaceRecord) -> Void

    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var nameTrimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 重名门控：与任一既有工作区同名 → 阻止创建并提示
    /// （registry 幂等会复用同路径实体——门控让用户显式改名的意图可见）。
    private var duplicate: Bool {
        guard !nameTrimmed.isEmpty else { return false }
        return environment.workspaceRegistry.list().contains { $0.title == nameTrimmed }
    }

    /// 空值/重名/进行中门控 → 创建钮 disabled（原型 wsCreate.disabled 语义）。
    private var canCreate: Bool {
        !nameTrimmed.isEmpty && !duplicate && !busy
    }

    var body: some View {
        ZStack {
            // 批10：暗灰蒙层退役（bgMask1+ultraThinMaterial）——透明点外关层，
            // 视觉=白卡轻影浮于当前内容（用户令，对齐权限警告弹窗形态）。
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }

            card
                .scaleEffect(reduceMotion ? 1 : (shown ? 1 : 0.96))
                .offset(y: reduceMotion ? 0 : (shown ? 0 : 10))
                .opacity(shown ? 1 : 0)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { nameFocused = true }
            DispatchQueue.main.async { // 延帧（onAppear 首帧前动画被吞铁律）
                withAnimation(reduceMotion ? nil : WOMotion.standardSpring) { shown = true }
            }
        }
    }

    private func onCancel() {
        isPresented = false
    }

    private func commit() {
        let trimmed = nameTrimmed
        guard canCreate else { return }
        busy = true
        error = nil
        do {
            // 建项目目录（幂等）+ registry.create（幂等）——「输入名字即全部」
            // （WorkspaceAdoption 共用；dsh「选择目录就是添加工作区的全部」）。
            let workspace = try WorkspaceAdoption.adopt(name: trimmed, environment: environment)
            busy = false
            isPresented = false
            name = ""
            onAdopted(workspace)
        } catch {
            busy = false
            self.error = "添加失败：\(error.localizedDescription)"
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加工作区")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(WOAlias.labelPrimary)
            Text("给新工作区起个名字，创建后立即可用。")
                .font(.system(size: 14))
                .foregroundColor(WOAlias.labelSecondary)

            TextField("工作区名称", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($nameFocused)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 22).fill(WOSpecific.tip))
                .overlay(RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(duplicate ? WOAlias.stateWarnSecondary
                                            : WOAlias.borderL4, lineWidth: 0.5))
                .disabled(busy)
                .onSubmit { if canCreate { commit() } }

            if duplicate {
                Text("已存在名为「\(nameTrimmed)」的工作区。") // dsh conflict.named
                    .font(.system(size: 12))
                    .foregroundColor(WOAlias.stateWarnLabel)
            }
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(WOAlias.stateErrorPrimary)
            }

            HStack(spacing: 10) {
                Button {
                    onCancel()
                } label: {
                    Text("取消")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(WOAlias.labelPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(WOAlias.bgLayer3)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(WOAlias.borderL3, lineWidth: 0.5)))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .woPressable()

                Button {
                    commit()
                } label: {
                    Text(busy ? "创建中…" : "创建")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(WOStatic.neutral00)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(canCreate ? WOAlias.buttonPrimaryFill
                                            : WOAlias.buttonPrimaryDimmed))
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)
                .woPressable()
            }
        }
        .padding(24)
        .frame(width: min(380, UIScreen.main.bounds.width - 48), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(WOAlias.bgLayer2))
        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 3)
        .shadow(color: .black.opacity(0.05), radius: 20, x: 0, y: 0)
        .overlay(RoundedRectangle(cornerRadius: 24)
            .strokeBorder(WOAlias.borderL4, lineWidth: 0.5))
    }
}
