//
//  UserQuestionService.swift
//  WanWo
//
//  【语义移植 · dsh · M3 T1】出处（packages/interaction/user-questions/src 全量）：
//    - types.ts:7-64 —— AskUserQuestionOption/Intent/Item/AnswerItem/Answer
//      类型 1:1（字段名与语义逐条对位；multiSelect 对应 wire 的 multi_select）。
//    - types.ts:21-30 —— AskUserQuestionIntent：呈现意图只改呈现不改协议；
//      plan-review 的 approve 按名不按位。
//    - index.ts:86-151 —— ask()：signal 已取消即 ASK_ABORTED（:87-89）；
//      空问题集 EMPTY_QUESTIONS（:90-92）；BAD_INTENT（:115-129）——intent 的
//      approve 必须命名本问题自身 options 之一、plan-review 必带 detail
//      （在 asker 处捕获错误，而非在每个 UI 里）；无 answerer NO_PROVIDER
//      （:130-133 fail closed）；异常归一（:143-150）。
//    - index.ts:41-47 —— abortedQuestion：ASK_ABORTED 固定文案与代码。
//  WanWo 形态：AskUserQuestionRequest 的 agent/signal 字段收敛为
//  「调用任务取消 = signal aborted」（WanWo 无子 agent 谱系，CALLER_NOT_LIVE /
//  DELEGATED_CALLER 校验随 M7 子代理落地——偏差登记）。
//

import Foundation

// MARK: - 类型（dsh user-questions/types.ts 1:1）

/// 一个可选项（dsh AskUserQuestionOption）。
struct AskUserQuestionOption: Equatable, Sendable, Codable {
    let label: String
    let description: String?
}

/// 呈现意图（dsh AskUserQuestionIntent；kind=plan-review 为 T3 消费）。
struct AskUserQuestionIntent: Equatable, Sendable, Codable {
    /// 目前闭集仅 "plan-review"（dsh types.ts:23）。
    let kind: String
    /// 表示同意的选项 label（按名不按位）。
    let approve: String
}

/// 一条提问（dsh AskUserQuestionItem；id 为稳定回显键）。
struct AskUserQuestionItem: Equatable, Sendable, Codable {
    let id: String
    let question: String
    let detail: String?
    let header: String?
    let options: [AskUserQuestionOption]?
    let multiSelect: Bool?
    let intent: AskUserQuestionIntent?
}

/// 单条回答（dsh AskUserQuestionAnswerItem）。
struct AskUserQuestionAnswerItem: Equatable, Sendable, Codable {
    let id: String
    let selected: [String]
    let custom: String?
}

/// 整组回答（dsh AskUserQuestionAnswer）。
struct AskUserQuestionAnswer: Equatable, Sendable, Codable {
    let answers: [AskUserQuestionAnswerItem]
}

// MARK: - 错误（dsh UserQuestionError 稳定错误分类）

/// user-questions 稳定错误分类（dsh index.ts:34-39 的 code 词汇 1:1）。
struct UserQuestionError: Error, Equatable {
    let message: String
    let code: String

    /// dsh index.ts:41-47 abortedQuestion。
    static func aborted(cause: String? = nil) -> UserQuestionError {
        UserQuestionError(
            message: "ask_user_question was aborted before the user answered",
            code: "ASK_ABORTED")
    }

    static func cancelled() -> UserQuestionError {
        UserQuestionError(
            message: "ask_user_question was dismissed by the user",
            code: "ASK_CANCELLED")
    }
}

// MARK: - 服务

/// 提问服务：校验 + presenter 缝 + 在途登记（first answer wins）。
/// 由 ask_user_question 工具（dsh tool-ask-user 的 Consumer 形态）阻塞调用。
final class UserQuestionService: @unchecked Sendable {

    private static let logger = AppLogger(category: "UserQuestionService")

    /// 在途登记项。结算错误随项登记（error）：answer/dismiss/abort 与续体注册
    /// 是并发竞速——谁先到谁定值，续体注册时若已结算即按登记错误恢复。
    private struct PendingEntry {
        let presentation: PendingQuestionPresentation
        var continuation: CheckedContinuation<AskUserQuestionAnswer, Error>?
        var settled = false
        var error: Error?
    }

    private let lock = NSLock()
    private var pending: [String: PendingEntry] = [:]
    private weak var presenter: (any SessionInteractionPresenter)?

    init(presenter: (any SessionInteractionPresenter)?) {
        self.presenter = presenter
    }

    /// 是否存在审阅通道（T3 exit_plan_mode 前置检查用——dsh execute 在 ask 之前
    /// 判 ctx.get('userQuestions') 是否可用并给出专属文案；ask 自身的 NO_PROVIDER
    /// 文案面向 ask_user_question 工具，通道缺失时两者都 fail closed）。
    var hasAnswerer: Bool {
        presenter != nil
    }

    // MARK: 询问（工具侧阻塞入口；dsh index.ts:86-151 ask() 全时序）

    /// 询问用户并等待回答。
    /// - Throws: UserQuestionError（ASK_ABORTED / EMPTY_QUESTIONS / BAD_INTENT /
    ///   NO_PROVIDER / ASK_CANCELLED）；任务取消归一 ASK_ABORTED（dsh signal 语义）。
    func ask(questions: [AskUserQuestionItem], callId: String?) async throws
        -> AskUserQuestionAnswer {
        // signal 已取消（dsh :87-89；WanWo：调用任务已取消等价）。
        if Task.isCancelled { throw UserQuestionError.aborted() }
        // 空问题集（dsh :90-92）。
        guard !questions.isEmpty else {
            throw UserQuestionError(message: "ask_user_question requires at least one question",
                                    code: "EMPTY_QUESTIONS")
        }
        // BAD_INTENT（dsh :115-129 逐条 1:1）：approve 必须命名本问题的选项之一；
        // 有意图必带 detail。在 asker 处捕获（错误源头在提问方）。
        for question in questions {
            guard let intent = question.intent else { continue }
            let labels = (question.options ?? []).map(\.label)
            if !labels.contains(intent.approve) {
                throw UserQuestionError(
                    message: "question \(question.id) declares intent \(intent.kind) whose "
                        + "approve label \"\(intent.approve)\" names none of its options",
                    code: "BAD_INTENT")
            }
            if question.detail == nil {
                throw UserQuestionError(
                    message: "question \(question.id) declares intent \(intent.kind) "
                        + "without the detail it reviews",
                    code: "BAD_INTENT")
            }
        }
        // 无 answerer（dsh :130-133 NO_PROVIDER——fail closed，绝不编造回答）。
        guard let answerer = presenter else {
            throw UserQuestionError(message: "no user-questions answerer accepted the request",
                                    code: "NO_PROVIDER")
        }

        let requestId = "ask-\(UUID().uuidString)"
        let presentation = PendingQuestionPresentation(id: requestId, questions: questions,
                                                       callId: callId)

        // 呈现 → 登记续体 → 等首个 settle；任务取消 → ASK_ABORTED
        // （dsh：signal abort withdraws the question）。
        await MainActor.run { answerer.presentQuestion(presentation) }
        let settlement: QuestionSettlement
        do {
            let answer = try await withTaskCancellationHandler {
                try await self.awaitAnswer(presentation)
            } onCancel: {
                self.abort(requestId: requestId)
            }
            settlement = .answered(answer)
        } catch let error as UserQuestionError {
            settlement = error.code == "ASK_ABORTED" ? .aborted : .cancelled
        } catch {
            // 未知抛出归一为中断（fail closed：不把未知错误当正常回答）。
            settlement = .aborted
        }

        // 登记表清理 + 结算呈现（toolview 行结局：N/M answered / cancelled /
        // interrupted——dsh 2026-07-29 笔记 §Decision）。
        lock.lock()
        pending.removeValue(forKey: requestId)
        lock.unlock()
        await MainActor.run { answerer.settleQuestion(id: requestId, settlement: settlement) }

        guard case .answered(let answer) = settlement else {
            // 结算错误回执：与 settlement 同源（ASK_ABORTED / ASK_CANCELLED）。
            throw settlement == .aborted
                ? UserQuestionError.aborted()
                : UserQuestionError.cancelled()
        }
        return answer
    }

    // MARK: 裁决（UI 侧）

    /// 结算一次（first answer wins：settled 项拒绝再次结算；error 恒非 nil——
    /// 回答路径走 answer() 自带值恢复，dismiss/abort 走本函数带错误恢复）。
    private func settle(requestId: String, error: Error) -> Bool {
        lock.lock()
        guard var entry = pending[requestId], !entry.settled else {
            lock.unlock()
            return false
        }
        entry.settled = true
        entry.error = error
        let continuation = entry.continuation
        entry.continuation = nil
        pending[requestId] = entry
        lock.unlock()
        continuation?.resume(throwing: error)
        return true
    }

    /// UI 回填整组回答（first answer wins；dsh PendingQuestion carrier 一次性）。
    /// - Returns: false = 请求不存在或已结算。
    @discardableResult
    func answer(requestId: String, _ answer: AskUserQuestionAnswer) -> Bool {
        lock.lock()
        guard var entry = pending[requestId], !entry.settled else {
            lock.unlock()
            return false
        }
        entry.settled = true
        entry.error = nil
        let continuation = entry.continuation
        entry.continuation = nil
        pending[requestId] = entry
        lock.unlock()
        continuation?.resume(returning: answer)
        return true
    }

    /// 用户主动关闭整组提问（dsh composer cancel → ASK_CANCELLED；
    /// 中性结算：用户蓄意为之，非工具失败）。
    @discardableResult
    func dismiss(requestId: String) -> Bool {
        settle(requestId: requestId, error: UserQuestionError.cancelled())
    }

    /// 桥关闭（会话视图离场）：在途提问一律 ASK_ABORTED（fail closed；
    /// 无人可答的问题不得静默编造回答）。
    func bridgeClosed() {
        lock.lock()
        let ids = pending.filter { !$0.value.settled }.map(\.key)
        for id in ids {
            pending[id]?.settled = true
            pending[id]?.error = UserQuestionError.aborted()
        }
        lock.unlock()
        for id in ids {
            lock.lock()
            let continuation = pending[id]?.continuation
            pending[id]?.continuation = nil
            let error = (pending[id]?.error as? UserQuestionError) ?? .aborted()
            lock.unlock()
            continuation?.resume(throwing: error)
        }
    }

    // MARK: 内部

    private func awaitAnswer(_ presentation: PendingQuestionPresentation) async throws
        -> AskUserQuestionAnswer {
        // ① 先登记占位（未结算）——呈现与裁决（MainActor）可能抢在续体注册前，
        //   占位保证 settle 有落点、结算值不丢。
        lock.lock()
        if pending[presentation.id] == nil {
            pending[presentation.id] = PendingEntry(presentation: presentation)
        }
        lock.unlock()

        // ② 呈现（composer 接管）。
        let presenter = self.presenter
        await MainActor.run { presenter?.presentQuestion(presentation) }

        // ③ 注册续体；若已结算（含注册前取消）即按登记错误直接恢复。
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<AskUserQuestionAnswer, Error>) in
            lock.lock()
            guard var entry = pending[presentation.id] else {
                lock.unlock()
                continuation.resume(throwing: UserQuestionError.aborted())
                return
            }
            if entry.settled {
                let error = entry.error ?? UserQuestionError.aborted()
                lock.unlock()
                continuation.resume(throwing: error)
                return
            }
            entry.continuation = continuation
            pending[presentation.id] = entry
            lock.unlock()
            // 注册后补检取消：onCancel 可能在占位与注册之间触发（此时 settle
            // 已把错误记进 entry，但无续体可复用）——按登记值恢复（竞态封堵）。
            if Task.isCancelled {
                self.abort(requestId: presentation.id)
            }
        }
    }

    /// 任务取消路径（dsh abort → ASK_ABORTED；迟到回答按已结算丢弃）。
    private func abort(requestId: String) {
        _ = settle(requestId: requestId, error: UserQuestionError.aborted())
    }
}
