//
//  OffloadApprovalPresenter.swift
//  WanWo
//
//  【万我 M6.1 增 · B1c ④审批卡接线】OffloadPermissionManager.presentApproval
//  缝 → SwiftUI 审批呈现的桥（TODO(审批接线) 落位）。
//
//  呈现语义对齐 OpenMinis 权限确认卡（源=OpenMinis
//  src/ios/Views/Chat/OffloadPermissionDialog.swift 1:1 移植，见
//  WanWo/Views/Chat/OffloadPermissionDialog.swift）：
//    · 原件形态 = OffloadPermissionManager 的 @Published pendingRequest +
//      respond(to:allowed:)（原件 OffloadPermissionManager.swift :259-303）；
//      本批 B1a 缝化后应答通道由 presentApproval(request, respond) 闭包承载，
//      呈现侧状态迁到本 presenter（ObservedObject 目标），manager 零改动。
//    · pendingRequest 单槽语义保留（原件 sheet(item:) 即单槽；并发第二请求
//      覆盖呈现、先行者的 30s 超时兜底收敛——与原件 MainActor 串行化行为
//      同形，resume-once 由 manager 侧锁保证双恢复安全）。
//    · 卡片内容 = PermissionRequest 的 displayLabel（commandName 行）/
//      description/fullCommand 经 parsedArguments 解析的键值行 + Allow/Deny
//      （OpenMinis OffloadPermissionDialogContent 1:1）。
//    · 允许/拒绝回写走缝的应答闭包（first answer wins 在 manager 侧——
//      超时竞速与双恢复已由 OffloadPermissionManager resumeLock 保证）。
//
//  装配点 = AppEnvironment（init 内 install()，与其他 App 级 manager 同位
//  ——resourceGovernor/jobRegistry/jobNotifier 先例）。
//

import Foundation
import Combine

@MainActor
final class OffloadApprovalPresenter: ObservableObject {

    static let shared = OffloadApprovalPresenter()

    private static let logger = AppLogger(category: "OffloadApproval")

    /// 当前在途审批（单槽——OpenMinis pendingRequest sheet(item:) 同形；
    /// 并发第二请求覆盖呈现，先行者由 manager 侧 30s 超时兜底）。
    @Published var pendingRequest: PermissionRequest?

    /// 应答闭包登记（按 request id；MainActor 域访问，免锁）。
    private var responders: [String: @Sendable (Bool) -> Void] = [:]

    private init() {}

    // MARK: - 缝装配

    /// 把 OffloadPermissionManager.presentApproval 缝接到本呈现器。
    /// AppEnvironment init 调用（App 生命周期一次；幂等——重复 install 只是
    /// 重挂同一闭包形态）。
    func install() {
        OffloadPermissionManager.shared.presentApproval = { [weak self] request, respond in
            self?.present(request: request, respond: respond)
        }
    }

    // MARK: - 呈现与回写

    /// 缝入口：登记应答闭包 + 弹卡（MainActor；缝回调恒在 MainActor——
    /// manager 的 presentApproval 调用点在 Task { @MainActor } 内）。
    private func present(request: PermissionRequest, respond: @escaping @Sendable (Bool) -> Void) {
        responders[request.id] = respond
        pendingRequest = request
        Self.logger.info("offload approval presented: \(request.commandName)")
    }

    /// 审批卡 Allow/Deny 回写（OpenMinis OffloadPermissionManager.respond
    /// :294-299 语义：id 匹配才收，清槽，闭包应答一次）。
    /// manager 侧 resume-once 锁保证超时竞速下只首个生效——迟到应答安全丢弃。
    func respond(to requestID: String, allowed: Bool) {
        guard pendingRequest?.id == requestID, let respond = responders.removeValue(forKey: requestID) else {
            Self.logger.info("offload approval respond dropped (stale id): \(requestID)")
            return
        }
        pendingRequest = nil
        respond(allowed)
    }

    // MARK: - 测试缝（万我 M6.1 增 · 仅单测注入）

    /// 单测注入口：不经 install() 直挂呈现面（登记应答闭包 + 弹卡，与
    /// present(request:respond:) 同逻辑；生产路径不触碰）。单测经 shared
    /// 单例驱动（@MainActor 串行），避免为可测性放开 private init。
    func presentForTesting(request: PermissionRequest,
                           respond: @escaping @Sendable (Bool) -> Void) {
        responders[request.id] = respond
        pendingRequest = request
    }
}
