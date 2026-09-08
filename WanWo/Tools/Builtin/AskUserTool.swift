//
//  AskUserTool.swift
//  WanWo
//
//  【语义移植 · dsh · M3 T1 · F063】出处（packages/interaction/tool-ask-user/src/index.ts
//  全量 1:1）：
//    - :16-17 —— 工具 description 原文。
//    - :20-57 —— parameters schema 1:1（questions 数组：id/question/header/
//      options{label,description}/multi_select；id 与 question 必填）。
//    - :58-79 —— output schema（answers 数组：id/selected/custom）与 render
//      （JSON.stringify——WanWo 以 JSON 文本作为结果 content）。
//    - :80-99 —— execute：args → AskUserQuestionItem 映射（multi_select →
//      multiSelect），经 userQuestions.ask 阻塞等待，答案作为普通 tool result
//      回流（id 稳定回显）。
//  四件套核对（m3-scope-brief §六.Q3）：schema = 本文件 parameters；section =
//  无（dsh SECTION_ORDERS 无 TOOL_ASK_USER 位，packages/core/system-prompt/
//  src/index.ts:121-152 核对——独立 section 为「无」，已呈报）；行为 = execute；
//  格式化 = presentCall/presentResult（dsh ask-question toolview 行：waiting /
//  N/M answered / cancelled / interrupted，2026-07-29 笔记 §Decision）。
//

import Foundation

/// ask_user_question（F063）：暂停工具调用直到人类回答，答案作为 tool result 回流。
struct AskUserTool: AgentTool {
    let name = "ask_user_question"
    let description = "Ask the user a concise question when you need confirmation, a choice, "
        + "or missing information before proceeding. "
        + "Send one or more questions, each with a stable id that will be echoed in the answer."

    /// 参数 schema（dsh tool-ask-user index.ts:23-57 1:1）。
    let parameters: JSONValue = .schemaObject(
        properties: [
            "questions": .object([
                "type": .string("array"),
                "description": .string("Questions to ask the user before continuing."),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(true),
                    "properties": .object([
                        "id": .object(["type": .string("string"),
                                       "description": .string("Stable id for this question; echoed in the answer.")]),
                        "question": .object(["type": .string("string"),
                                             "description": .string("The specific question to ask the user.")]),
                        "header": .object(["type": .string("string"),
                                           "description": .string("Optional short heading for the question, such as \"Confirm\" or \"Choose Mode\".")]),
                        "options": .object([
                            "type": .string("array"),
                            "description": .string("Optional choices to show the user. If you recommend one, put it first and append \"(Recommended)\" to that label."),
                            "items": .object([
                                "type": .string("object"),
                                "additionalProperties": .bool(true),
                                "properties": .object([
                                    "label": .object(["type": .string("string"),
                                                      "description": .string("Short user-facing option label.")]),
                                    "description": .object(["type": .string("string"),
                                                            "description": .string("One sentence explaining the tradeoff or impact.")]),
                                ]),
                            ]),
                        ]),
                        "multi_select": .object(["type": .string("boolean"),
                                                 "description": .string("Whether the user may select more than one option. Defaults to false.")]),
                    ]),
                ]),
            ]),
        ],
        required: ["questions"])

    /// 提问服务缝（makeAgentStack 装配；同一会话同一实例）。
    let service: UserQuestionService

    // 交互工具不设超时（人类回答耗时不可预算；dsh 无该工具 deadline）。
    var timeoutMs: Int? { nil }

    // MARK: - 参数映射（dsh execute 的 args.map 1:1；畸形字段 fail closed）

    /// tool args JSON → 问题项数组。缺 id/question 的条目整体拒绝（EMPTY/
    /// malformed 语义由调用方以错误结果合成——dsh schema required 的运行时复核）。
    static func decodeQuestions(_ args: JSONValue) throws -> [AskUserQuestionItem] {
        guard let items = args.field("questions")?.arrayItems else {
            throw UserQuestionError(message: "questions array is required", code: "INVALID_ARGS")
        }
        var out: [AskUserQuestionItem] = []
        for item in items {
            guard let id = item.field("id")?.stringValue, !id.isEmpty,
                  let question = item.field("question")?.stringValue else {
                throw UserQuestionError(
                    message: "each question requires non-empty \"id\" and \"question\"",
                    code: "INVALID_ARGS")
            }
            let options = item.field("options")?.arrayItems?.map { option -> AskUserQuestionOption in
                AskUserQuestionOption(label: option.field("label")?.stringValue ?? "",
                                      description: option.field("description")?.stringValue)
            }
            if let options, options.contains(where: { $0.label.isEmpty }) {
                throw UserQuestionError(message: "option labels must be non-empty",
                                        code: "INVALID_ARGS")
            }
            let intent: AskUserQuestionIntent?
            if let rawIntent = item.field("intent"),
               let kind = rawIntent.field("kind")?.stringValue,
               let approve = rawIntent.field("approve")?.stringValue {
                intent = AskUserQuestionIntent(kind: kind, approve: approve)
            } else {
                intent = nil
            }
            out.append(AskUserQuestionItem(
                id: id,
                question: question,
                detail: item.field("detail")?.stringValue,
                header: item.field("header")?.stringValue,
                options: options,
                multiSelect: item.field("multi_select")?.boolValue,
                intent: intent))
        }
        return out
    }

    // MARK: - 执行（dsh execute 1:1：阻塞等待 → 答案作为 tool result 回流）

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        let questions: [AskUserQuestionItem]
        do {
            questions = try Self.decodeQuestions(args)
        } catch let error as UserQuestionError {
            return .failure(error.message, code: error.code, name: "UserQuestionError")
        }
        do {
            let answer = try await service.ask(questions: questions, callId: ctx.callId)
            return .success(Self.renderAnswer(answer))
        } catch let error as UserQuestionError {
            return .failure(error.message, code: error.code, name: "UserQuestionError")
        } catch {
            return .failure(String(describing: error), code: "TOOL_ERROR",
                            name: "UserQuestionError")
        }
    }

    /// 结果渲染（dsh output.render：JSON.stringify——id 稳定回显，selected 数组，
    /// custom 缺省省略）。
    static func renderAnswer(_ answer: AskUserQuestionAnswer) -> String {
        let items: [JSONValue] = answer.answers.map { item in
            var fields: [String: JSONValue] = [
                "id": .string(item.id),
                "selected": .array(item.selected.map { .string($0) }),
            ]
            if let custom = item.custom, !custom.isEmpty {
                fields["custom"] = .string(custom)
            }
            return .object(fields)
        }
        let value = JSONValue.object(["answers": .array(items)])
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 结果解析（presentResult 的 N/M 计数输入；畸形返回 nil → 通用卡兜底）。
    static func parseAnswer(from output: ToolOutput) -> AskUserQuestionAnswer? {
        guard !output.isError,
              let value = JSONValue(data: Data(output.text.utf8)),
              let items = value.field("answers")?.arrayItems else { return nil }
        var answers: [AskUserQuestionAnswerItem] = []
        for item in items {
            guard let id = item.field("id")?.stringValue,
                  let selected = item.field("selected")?.arrayItems?
                      .compactMap({ $0.stringValue }) else { return nil }
            answers.append(AskUserQuestionAnswerItem(
                id: id, selected: selected, custom: item.field("custom")?.stringValue))
        }
        return AskUserQuestionAnswer(answers: answers)
    }

    // MARK: - 呈现（dsh ask-question toolview 行语义，2026-07-29 笔记 §Decision）

    /// 待执行卡：waiting（纯函数——live 与 replay 同形）。
    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        let count = args.field("questions")?.arrayItems?.count ?? 0
        return ToolCardIntent(title: "ask_user_question · 等待回答（\(count) 问）")
    }

    /// 结算卡：N/M answered / cancelled / interrupted（跳过的回答——空 selected
    /// 且无 custom——不计入 N；畸形/截断结果回落通用卡）。
    func presentResult(_ args: JSONValue, _ output: ToolOutput) -> ToolCardIntent? {
        if output.isError {
            switch output.errorCode {
            case "ASK_CANCELLED":
                return ToolCardIntent(title: "ask_user_question · 已取消")
            case "ASK_ABORTED":
                return ToolCardIntent(title: "ask_user_question · 已中断")
            default:
                return nil // 通用错误卡（fail-closed 兜底）
            }
        }
        guard let answer = Self.parseAnswer(from: output),
              let questions = args.field("questions")?.arrayItems?.compactMap({
                  $0.field("id")?.stringValue
              }), !questions.isEmpty else {
            return nil
        }
        let answeredIDs = Set(answer.answers.filter { item in
            !item.selected.isEmpty || !(item.custom ?? "").isEmpty
        }.map(\.id))
        let answered = questions.filter { answeredIDs.contains($0) }.count
        return ToolCardIntent(title: "ask_user_question · \(answered)/\(questions.count) 已回答")
    }
}
