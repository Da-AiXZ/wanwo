//
//  WOAppState.swift
//  WanWo
//
//  R1 诚实化地基环 —— App 级会话真值源（analysis/11-ui-design.md §十二 R1 产出①②）。
//  ①当前会话=唯一权威信号：所有打开路径（新壳点行/新会话创建/旧界面/深链）写同一点，
//    持久化=重启恢复（v4 片1 的 AppStorage 哨兵只记录"本壳新建"且无下游消费=假信号，退役）。
//  ②sessionListEpoch：SessionStore 写路径失效信号（writer 追加/标题落盘/建删）→ UI 推刷新。
//  运行状态点真值③不在此处——直接消费 AppEnvironment 既有镜像
// （pendingInteractionSessionIDs/activeRunSessionIDs，M6.6 B4 已建、ChatViewModel 已上报）。
//  纪律：本类只持状态，不触达存储细节；快照派生仍由各视图拉取。
//

import SwiftUI

@MainActor
final class WOAppState: ObservableObject {

    // MARK: - ① 当前会话（唯一真值源）

    /// 当前会话 id。nil=无当前会话（hero 空态）。
    @Published private(set) var currentSessionId: String?

    // MARK: - ② 列表变更纪元

    /// SessionStore 写路径失效信号计数（任意写 +1）。视图层订阅它触发快照重算——
    /// 替代环4批1 的"列表手动刷新"（D2 清偿）。
    @Published private(set) var sessionListEpoch = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 重启恢复：App 级"最后当前会话"（验收 R1-⑤ 的支撑）。
        let saved = defaults.string(forKey: Self.currentKey)
        if let saved, !saved.isEmpty {
            currentSessionId = saved
        }
    }

    private static let currentKey = "wo.appState.currentSessionId"

    /// 打开会话（所有路径唯一入口）。重复写同一 id 不触发通知（去重防 churn）。
    func openSession(_ id: String) {
        guard currentSessionId != id else { return }
        currentSessionId = id
        defaults.set(id, forKey: Self.currentKey)
    }

    /// 会话被删除/关闭时的收敛：若删的是当前会话，回退到 nil（hero）。
    /// （不做"自动跳最近"——dsh 语义：当前会话消失即回空态，startSession 目标才选 recent。）
    func sessionRemoved(_ id: String) {
        guard currentSessionId == id else { return }
        currentSessionId = nil
        defaults.removeObject(forKey: Self.currentKey)
    }

    /// 列表变更纪元 +1（SessionStore 失效信号触发；高频写路径由 SwiftUI 合并帧）。
    func bumpSessionList() {
        sessionListEpoch += 1
    }

    /// 快照组装辅助：当前会话是否"存在且非 blank"（10-design AppFrame detailsSession 语义）。
    /// blank=无标题占位会话（WOWorkspaceModel.isBlank 同口径）。
    func hasDetailsSession(in sessions: [SessionSummary]) -> Bool {
        guard let id = currentSessionId else { return false }
        return sessions.contains { $0.id == id && $0.title != nil }
    }

    // MARK: - composer 草稿缓存（dsh ConversationStoreState.draft 跨切换持久语义）

    /// 会话草稿缓存（App 级内存；会话切换销毁/重建 ChatView 后草稿跟回——
    /// dsh「blank 会话复用时草稿恢复」的 WanWo 折算。跨杀后台持久=dsh 还有
    /// storedDraft 落库，本版不落库，登记 §十六）。
    @Published private(set) var draftCache: [String: String] = [:]

    func updateDraft(_ text: String, for sessionId: String) {
        if draftCache[sessionId] == text { return }
        if text.isEmpty {
            draftCache.removeValue(forKey: sessionId)
        } else {
            draftCache[sessionId] = text
        }
    }

    func cachedDraft(for sessionId: String) -> String? {
        draftCache[sessionId]
    }
}
