//
//  InterruptedTurnClosers.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh packages/core/session/src/repair.ts（interruptedTurnClosers）。
//  为开放的尾部回合合成缺失收尾：未闭环 step/end → 合成 step/end；
//  turn/end 缺失 → 合成 interrupted turn/end。seq 续接日志，时间戳复用最后一条
//  真实事件（确定性、绝不发明"未来"时间）。
//  M1 偏差说明：dsh 还会为未闭环 tool/call 合成错误 tool/result——M1 事件词汇尚无
//  tool/call|result（M2 接入工具时补齐）；此处若开放 step 的最后 assistantMessage
//  携带 tool-call 块，改以 .system 注记留痕（ignorable），不合成结果事件。
//

import Foundation

enum InterruptedTurnClosers {
    /// 扫描已加载的持久化事件流，返回应追加在末尾的合成收尾事件（已平衡则空）。
    static func closers(for events: [SessionEvent]) -> [SessionEvent] {
        var openTurn: Int?
        var openStep: Int?
        var pendingToolCallsInOpenStep: [String] = []

        for event in events {
            switch event.payload {
            case .turnStart(let turn):
                openTurn = turn
                openStep = nil
                pendingToolCallsInOpenStep.removeAll()
            case .turnEnd:
                openTurn = nil
                openStep = nil
                pendingToolCallsInOpenStep.removeAll()
            case .stepStart(_, let step):
                openStep = step
                pendingToolCallsInOpenStep.removeAll()
            case .stepEnd:
                pendingToolCallsInOpenStep.removeAll()
                openStep = nil
            case .assistantMessage(_, let step, let message, _, _):
                // 助手消息携带的工具请求块在结果落盘前都算 pending（dsh 语义）。
                if openStep == step {
                    for block in message.content {
                        if case .toolCall(let id, _, _) = block {
                            pendingToolCallsInOpenStep.append(id)
                        }
                    }
                }
            default:
                break
            }
        }

        // 平衡日志（无崩溃尾）：无需收尾。
        guard let turn = openTurn, let last = events.last else { return [] }

        var seq = last.seq + 1
        let time = last.timeMs
        var closers: [SessionEvent] = []

        // 未闭环的工具请求：M1 以系统注记留痕（M2 起改为合成错误 tool/result）。
        if !pendingToolCallsInOpenStep.isEmpty {
            let ids = pendingToolCallsInOpenStep.joined(separator: ", ")
            closers.append(SessionEvent(
                seq: seq, timeMs: time, payload: .system(
                    note: "回合 \(turn) 被中断：工具调用 [\(ids)] 未获结果（结果未知，M2 起将以错误结果回注）。"),
                ignorable: true))
            seq += 1
        }

        // 先收 step（turn/end 时 step 仍开放是不变量违例，必须先合成 step 收尾）。
        if let step = openStep {
            closers.append(SessionEvent(seq: seq, timeMs: time,
                                        payload: .stepEnd(turn: turn, step: step)))
            seq += 1
        }

        closers.append(SessionEvent(seq: seq, timeMs: time,
                                    payload: .turnEnd(turn: turn, reason: .interrupted)))
        return closers
    }
}
