//
//  ApprovalCoordinator.swift
//  WanWo
//
//  【语义移植 · dsh · M3 T1】出处：
//    - dsh packages/interaction/user-approval/src/index.ts:207-226 —— request()
//      全时序：turn-enclosed 前置（:209-215）→ 追加 approval/asked（:217-222，
//      id/toolName/callId?/reason?）→ decide → 追加 approval/decided（:224）。
//      审计对恒成对：decided 在 asked 之后必然落盘，outcome 已知时逐 ask 恰一条。
//    - dsh index.ts:77-84 —— hasOpenTurn：审计对必须被回合封闭（turn 是持久
//      日志的 commit/replay 边界；回合间的裸事件与 crash-tail 无法区分，
//      reload 时被静默丢弃）。
//    - dsh index.ts:55-56 / types.ts:30 —— 无 answerer fail closed 'unavailable'。
//    - dsh packages/client/ui-approval/src/client/contract/slots.ts:69-159 ——
//      PendingApproval 载体：settled 一次性（:151-158 finish 已结算即抛），
//      abort（:146-149）撤销未答请求；迟到回答按已结算丢弃（:290-296 注释语义）。
//    - dsh .agents/notes/implemented/feature/2026-07-23-web-permission-and-approval.md
//      —— 宿主注册表持有在途请求（WanWo：coordinator 内存登记表 = host 内存
//      唯一裁决者）；按钮禁用、失败 re-arm（结算才是真相，WanWo 由 request()
//      收尾统一结算呈现）。
//    - m3-scope-brief §二.5 —— first answer wins（resolved 标志 + 幂等防双击）+
//      host 内存唯一裁决者 + 桥关闭在途待决一律 unavailable。
//  WanWo 归一化（偏差登记）：dsh 对 turn 外 ask 抛错（:209-215 throw）；Swift 侧
//  管线不捕异常，故本实现归一化为返回 .unavailable（fail closed 同向：不放行、
//  不落任何审计事件——dsh 抛错路径同样未落 asked）。
//

import Foundation

/// 审批协调器：宿主侧唯一裁决登记处。职责：
///   · turn-enclosed 前置校验（开放回合外一律 .unavailable，且不落审计）；
///   · approval/asked + approval/decided 审计对的唯一落盘点（恒成对）；
///   · 在途登记表 + first answer wins（settled 一次性，结算值随项登记）；
///   · 任务取消 → .cancelled；桥关闭 → 在途待决一律 .unavailable。
/// P1-4：T2 记忆位（requestWithMemory/ApprovalResolution/rememberable）随
/// F022 砍除——allowed-once 仅 stamp 触发审批的那一次提权（dsh
/// escalation.ts:183），无跨调用授权面。
final class ApprovalCoordinator: @unchecked Sendable {

    private static let logger = AppLogger(category: "ApprovalCoordinator")

    /// 在途登记项。结算值随项登记（result）：answer/withdraw/bridgeClosed 与
    /// 续体注册是并发竞速——谁先到谁定值，续体注册时若已结算即按登记值恢复。
    private struct PendingEntry {
        let presentation: PendingApprovalPresentation
        var continuation: CheckedContinuation<ApprovalOutcome, Never>?
        var settled = false
        var result: ApprovalOutcome = .cancelled
    }

    private let lock = NSLock()
    private var pending: [String: PendingEntry] = [:]
    /// 呈现缝（弱持有：ChatViewModel 持有 coordinator，反向必须弱引用防环）。
    private weak var presenter: (any SessionInteractionPresenter)?
    private let writer: SessionWriter

    init(writer: SessionWriter, presenter: (any SessionInteractionPresenter)?) {
        self.writer = writer
        self.presenter = presenter
    }

    // MARK: - 请求（管线侧；dsh ApprovalService.request 全时序）

    /// 发起一次审批询问并阻塞等待结论。`.allowedOnce` 是唯一授予。
    func request(tool: String, callId: String?, reason: String?) async -> ApprovalOutcome {
        // turn-enclosed 前置（dsh index.ts:209-215；WanWo 归一化为 .unavailable，
        // fail closed 同向且不落任何审计事件——回合外的裸审计对正是 crash-tail）。
        guard writer.openTurn != nil else {
            Self.logger.error("approval.request outside an open turn; failing closed "
                + "(audit pair must be turn-enclosed, dsh index.ts:209-215)")
            return .unavailable
        }

        let requestId = "apr-\(UUID().uuidString)"
        // 审计对上半：approval/asked（dsh index.ts:217-222；provenance 走既有
        // asked.reason 字段——提权理由 `escalate sandbox to ${mode}: …` 由
        // P1-3 审批通道传入）。落盘失败 → fail closed（dsh index.ts:199-201：
        // 返回未落审计的裁决即破坏审计对）。
        do {
            _ = try await writer.append(
                .approvalAsked(requestId: requestId, tool: tool, reason: reason),
                ignorable: true)
        } catch {
            Self.logger.error("approval/asked append failed; failing closed: "
                + "\(String(describing: error))")
            return .unavailable
        }

        let presentation = PendingApprovalPresentation(
            id: requestId, toolName: tool, callId: callId,
            reason: reason, commandDetail: nil)

        // 取消 → .cancelled（dsh index.ts:120-123：aborting withdraws the
        // question, settles 'cancelled' immediately, late answer discarded）。
        let outcome: ApprovalOutcome = await withTaskCancellationHandler {
            await self.awaitAnswer(presentation)
        } onCancel: {
            self.withdraw(requestId: requestId)
        }

        // 审计对下半：approval/decided（dsh index.ts:224——恰随每个 ask 一条；
        // verdict 字段值为四值闭集原文 1:1）。落盘失败仍拒（dsh index.ts:199-201：
        // 返回未落审计的裁决即破坏审计对——fail closed，工具不执行）。
        do {
            _ = try await writer.append(
                .approvalDecided(requestId: requestId, verdict: outcome.rawValue),
                ignorable: true)
        } catch {
            Self.logger.error("approval/decided append failed; failing closed: "
                + "\(String(describing: error))")
            return .unavailable
        }

        // 结算呈现 + 登记表清理（面板退位恢复 composer；dsh：resolved 帧结算）。
        await MainActor.run { [presenter] in
            presenter?.settleApproval(id: requestId, outcome: outcome)
        }
        return outcome
    }

    // MARK: - 裁决（UI 侧；first answer wins）

    /// UI 回填裁决。仅交互二值可回（dsh slots.ts:64 ApprovalDecision）。
    /// - Returns: false = 请求不存在或已结算（UI 需 re-arm 按钮——dsh 笔记：
    ///            按钮本地禁用、失败后 re-arm，结算才是真相）。
    @discardableResult
    func answer(requestId: String, outcome: ApprovalOutcome) -> Bool {
        // 幂等防双击 + rogue 输入拒绝（cancelled/unavailable 不是用户输入）。
        guard outcome == .allowedOnce || outcome == .rejected else { return false }
        return settle(requestId: requestId, result: outcome)
    }

    /// 桥关闭（会话视图离场）：在途待决一律 .unavailable（m3-scope-brief §二.5；
    /// fail closed——无人可答的问题不能挂着静默放行）。
    func bridgeClosed() {
        lock.lock()
        let ids = pending.filter { !$0.value.settled }.map(\.key)
        for id in ids { pending[id]?.settled = true; pending[id]?.result = .unavailable }
        lock.unlock()
        for id in ids { resumeIfRegistered(id) }
    }

    // MARK: - 内部

    /// 结算一次（first answer wins：settled 项拒绝再次结算）。
    private func settle(requestId: String, result: ApprovalOutcome) -> Bool {
        lock.lock()
        guard var entry = pending[requestId], !entry.settled else {
            lock.unlock()
            return false
        }
        entry.settled = true
        entry.result = result
        let continuation = entry.continuation
        entry.continuation = nil
        pending[requestId] = entry
        lock.unlock()
        continuation?.resume(returning: result)
        return true
    }

    /// 已结算但续体后到：按登记值恢复（结算值不丢——answer/withdraw 与
    /// 续体注册并发竞速的收敛点）。
    private func resumeIfRegistered(_ requestId: String) {
        lock.lock()
        let continuation = pending[requestId]?.continuation
        if continuation != nil { pending[requestId]?.continuation = nil }
        let result = pending[requestId]?.result ?? .unavailable
        lock.unlock()
        continuation?.resume(returning: result)
    }

    /// 挂起等待：登记占位 → 呈现 → 注册续体 → 等首个 settle。
    private func awaitAnswer(_ presentation: PendingApprovalPresentation) async
        -> ApprovalOutcome {
        // ① 先登记占位（未结算）——呈现与裁决（MainActor）可能抢在续体注册前，
        //   占位保证 settle 有落点、结算值不丢。
        lock.lock()
        if pending[presentation.id] == nil {
            pending[presentation.id] = PendingEntry(presentation: presentation)
        }
        lock.unlock()

        // ② 呈现（composer 接管）。
        let presenter = self.presenter
        await MainActor.run { presenter?.presentApproval(presentation) }

        // ③ 注册续体；若已结算（含注册前取消）即按登记值直接恢复。
        return await withCheckedContinuation { (continuation: CheckedContinuation<
            ApprovalOutcome, Never>) in
            lock.lock()
            guard var entry = pending[presentation.id] else {
                lock.unlock()
                continuation.resume(returning: .cancelled)
                return
            }
            if entry.settled {
                let result = entry.result
                lock.unlock()
                continuation.resume(returning: result)
                return
            }
            entry.continuation = continuation
            pending[presentation.id] = entry
            lock.unlock()
            // 注册后补检取消：onCancel 可能在占位与注册之间触发（此时 settle
            // 已把值记进 entry，但无续体可复用）——按登记值恢复（竞态封堵）。
            if Task.isCancelled {
                withdraw(requestId: presentation.id)
            }
        }
    }

    /// 撤销（任务取消路径；dsh index.ts:119-123 abort 语义：立即结算
    /// 'cancelled'，迟到的回答按已结算丢弃）。
    private func withdraw(requestId: String) {
        _ = settle(requestId: requestId, result: .cancelled)
    }
}
