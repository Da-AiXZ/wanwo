//
//  JobNotifier.swift
//  WanWo
//
//  【M5-A 批 J4 · 后台可见性】语义演进（真机批 B4 用户裁决重定义）：
//    · 原"作业完成 → 系统通知"面**删除**——作业完成是给 AI 的中间事件
//      （纸条经 AgentLoop.inject 进收件箱，AppEnvironment listener 承载），
//      不该弹系统通知打扰用户（"给 AI 的东西为什么也系统通知我"）。
//    · 新"回合完成 → 系统通知"面：回合结束（turn/end）且 App 不在前台时
//      通知"任务完成，回来验收"——这才是系统通知的正确触发点（用户拍板
//      的验收模型：发任务 → 切走 → AI 做完 → 通知 → 切回验收）。
//      依赖后台保活（BackgroundKeepAlive，~30s 窗口）——无保活时后台冻结、
//      回合不会在后台结束，本通知自然不触发（现状行为不变）。
//    · 授权/投递缝与打点保留（B3 形态：add 成功/失败进 OSLog）。
//    · 前台判定语义简化：不再做 missedInBackground 历史（作业级判定的
//      遗留）——回合完成通知恒以"App 当下是否前台"为准。
//

import Foundation
import UserNotifications
import UIKit

/// 通知器（07 F007 修订形态：回合完成 → 用户验收提醒）。
/// 注入缝三枚：前台态判定 / 授权请求 / 通知投递——测试桩替换；
/// 生产缺省走 UIKit + UNUserNotificationCenter。
struct JobNotifier: Sendable {
    private static let logger = AppLogger(category: "jobnotify")

    /// title 截断字节上限（label=一行命令，防超长通知；UTF-8 边界保留——
    /// 复用 J3 retainHead）。
    static let titleMaxBytes = 120

    /// 前台态判定（true=active → 不通知）。生产=MainActor 读 applicationState
    /// （UIApplication.shared 是 MainActor 隔离面）。
    var isAppActive: @Sendable () async -> Bool = {
        await MainActor.run { UIApplication.shared.applicationState == .active }
    }

    /// 授权请求（true=granted）。生产=requestAuthorization 幂等惰性形态
    /// （首次弹窗，之后直返当前设置——不需自持缓存）。
    var requestAuthorization: @Sendable () async -> Bool = {
        (try? await UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge])) ?? false
    }

    /// 通知投递（identifier=sessionId；无 trigger=立即呈现；无声）。
    /// 生产=UNUserNotificationCenter.add。
    /// 【真机批 B3】吞错可见化：此前 try? 静默——投递成功/失败无痕迹。
    var addNotification: @Sendable (_ identifier: String, _ title: String,
                                    _ body: String) async -> Void
        = { identifier, title, body in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // 无声裁定：不设 content.sound。
            let request = UNNotificationRequest(identifier: identifier,
                                                content: content,
                                                trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
                Self.logger.info("[jobnotify] added ok: \(identifier)")
            } catch {
                Self.logger.error("[jobnotify] add failed for "
                                  + "\(identifier): \(String(describing: error))")
            }
        }

    /// 回合完成 → 用户验收提醒（turn/end 且 App 不在前台时触发；前台完成
    /// = 用户在场，不打扰）。identifier 用 sessionId（同会话覆盖去重）。
    /// - Parameters:
    ///   - sessionId: 会话标识（通知去重键）。
    ///   - taskLabel: 任务摘要（会话标题或首条用户消息前缀）。
    func notifyTurnCompleted(sessionId: String, taskLabel: String) async {
        if await isAppActive() {
            Self.logger.info("[jobnotify] turn completed foreground — no notify (user present)")
            return
        }
        Self.logger.info("[jobnotify] turn completed background — will notify")
        guard await requestAuthorization() else {
            Self.logger.error("[jobnotify] authorization denied (turn completion)")
            return
        }
        let title = retainHead(taskLabel, maxBytes: Self.titleMaxBytes)
        await addNotification(sessionId, title, "任务完成，回来验收。")
    }
}
