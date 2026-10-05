//
//  WOTextReveal.swift
//  WanWo
//
//  【批 2 · 件 5】打字机显示节奏引擎——CKTextReveal 万我形态。
//  语义源（1:1 移植，行号锚）：_lody_probe/chatkit ChatKit-main
//  Sources/ChatKitCore/CKTextReveal.swift（58 行，MIT；主理人已实读）。
//
//  红线（派单简报件 5）：本引擎**只改「每帧显示多少字」**（display pacing），
//  不改「何时结算/如何结算」——settle 决策依赖面（finishSettling 的"打完"
//  判定=hasPending 翻空、keepSettling 过滤、空缓冲守卫、双代际 id、补打遇
//  新 delta 强制 finish）全部留在 ChatViewModel 原位。宿主持有权威内容与
//  完成状态（CK 头注同语义）。
//
//  机制：arrivalRate += (rate - arrivalRate) * 0.35 指数平滑（出字速率追踪）
//  advance：speed = max(38, arrivalRate * 1.1, backlog / 0.18)（猝发在短预算
//  内排空、与消息长度无关）；elapsed clamp 0.12s；无输入 ≥0.45s 或 backlog
//  >2048 → 全排；非前缀扩展 = 权威修正直接 finish（修正不重播）。
//

import Foundation

/// 单个正文直播槽的显示节奏（值类型；VM 每槽一个实例，随 finishSettling 重置）。
struct WOTextReveal {
    /// 权威内容（宿主同步的全量文本）。
    private(set) var source = ""
    /// 当前显示前缀（shown 恒为 source 的前缀或全文——权威修正例外=全文）。
    private(set) var shown = ""
    private var pending: [Character] = []
    private var offset = 0
    private var lastInput: Double?
    private var lastAdvance = 0.0
    private var arrivalRate = 38.0

    /// 有未显示积压（settle"打完"判定消费——hasPending 翻空 = 本段排空）。
    var hasPending: Bool { offset < pending.count }

    /// 接收权威内容更新（time = CACurrentMediaTime 秒）。
    mutating func receive(_ text: String, animate: Bool, at time: Double) {
        guard text != source else {
            if !animate { finish() }
            return
        }
        guard animate, text.hasPrefix(source) else {
            // 非前缀扩展 = 权威修正：直接全量呈现，不重播（CK :20-26）。
            source = text
            finish()
            lastInput = nil
            arrivalRate = 38
            return
        }
        let appended = Array(text.dropFirst(source.count))
        if let lastInput {
            // 出字速率指数平滑（CK :28-31——0.35 平滑系数）。
            let rate = Double(appended.count) / max(0.016, time - lastInput)
            arrivalRate += (rate - arrivalRate) * 0.35
        }
        if !hasPending { lastAdvance = time }
        lastInput = time
        pending = Array(pending.dropFirst(offset)) + appended
        offset = 0
        source = text
    }

    /// 显示推进（VM 33Hz 节奏器每步调用；time 同源时钟注入）。
    mutating func advance(at time: Double) {
        guard hasPending else { return }
        // elapsed clamp 0.12s（CK :40——长卡顿不产生超大步长）。
        let elapsed = min(0.12, max(0, time - lastAdvance))
        guard elapsed > 0 else { return }
        lastAdvance = time
        let backlog = pending.count - offset
        // 猝发排空预算（CK :44-45——短预算内排空、与消息长度无关）。
        let speed = max(38, arrivalRate * 1.1, Double(backlog) / 0.18)
        var batch = max(1, Int(speed * elapsed))
        // 无输入 ≥0.45s（输入流断了）或超大积压 → 全排（CK :47）。
        if time - (lastInput ?? time) >= 0.45 || backlog > 2048 { batch = backlog }
        let end = min(pending.count, offset + batch)
        shown += String(pending[offset..<end])
        offset = end
        if !hasPending { finish() }
    }

    /// 全量呈现并清空积压（finishSettling 消费）。
    mutating func finish() {
        shown = source
        pending.removeAll(keepingCapacity: false)
        offset = 0
    }

    /// 全量重置（会话切换/结算收口后的干净态）。
    mutating func reset() {
        self = WOTextReveal()
    }
}
