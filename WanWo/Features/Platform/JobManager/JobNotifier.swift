//
//  JobNotifier.swift
//  WanWo
//
//  【M5-A 批 J4 · 后台作业完成的 iOS 本地通知映射】
//  语义源：07 清单 F007 iOS 注记——"作业随 App 前台执行；完成经本地通知；
//  iOS 后台受限需明示"。J3 已接 in-process 通道（onJobDone→inject，模型侧
//  可见）；本件补用户侧可见性：用户不在看 App（applicationState != .active）
//  而 App 后台存活的短窗口内作业 settle 时发本地通知。
//
//  裁定（派单钉死 + 本件登记）：
//    - 触发条件 = applicationState != .active。App 挂起时代码不执行、iSH
//      线程冻结——作业不会在挂起期间完成，不存在挂起期补发面；前台发通知
//      =打扰（inject 已可见）不发。
//    - 通知 body = JobCompletionNotice.text(for:)（J3 同一文本双通道：模型
//      见 inject、用户见通知；outputLimitBytes 预算面是模型侧语义，通知直用
//      不另造文案）。
//    - 授权：requestAuthorization([.alert, .sound, .badge]) 首次发通知前
//      惰性请求（requestAuthorization 幂等——首次弹窗、之后直返当前态，不
//      轰炸启动流）；拒绝/出错 = 静默跳过（fail open，登记）。
//    - 无声：不设 content.sound（避打扰；提示职责模型侧已由 inject 承担）。
//    - 通知 identifier = job id（UNUserNotificationCenter 同 identifier
//      覆盖——同作业重发去重；多会话 listener 重复请求同此收敛，登记）。
//    - 通知无会话隔离：任何（有主）作业完成都提醒；owner nil 不发（owner
//      归一面口径与 inject 一致）。
//

import Foundation
import UserNotifications
import UIKit

/// 后台作业完成的本地通知器（07 F007）。注入缝三枚：前台态判定 / 授权请求 /
/// 通知投递——测试桩替换；生产缺省走 UIKit + UNUserNotificationCenter。
struct JobNotifier: Sendable {

    /// title 截断字节上限（label=一行命令，防超长通知；UTF-8 边界保留——
    /// 复用 J3 retainHead）。
    static let titleMaxBytes = 120

    /// 前台态判定（true=active → 抑制）。生产=MainActor 读 applicationState
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

    /// 通知投递（identifier=job id；无 trigger=立即呈现——系统推荐形态；
    /// 无声）。生产=UNUserNotificationCenter.add。
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
            try? await UNUserNotificationCenter.current().add(request)
        }

    /// 作业 settle 后按需发本地通知（onJobDone listener 消费面）。
    /// - Parameters:
    ///   - snapshot: 终态快照（id 作通知 identifier，label 作 title）。
    ///   - ownerSessionId: 精确 owner（nil=unowned → 不发）。
    ///   - noticeText: JobCompletionNotice.text(for:) 产物（模型/用户同文本）。
    func notifyIfNeeded(snapshot: JobSnapshot,
                        ownerSessionId: String?,
                        noticeText: String) async {
        // owner 归一面口径：reported（已上报）与 unowned（owner nil）不发
        // ——listener 已过滤，此处复检保证独立调用面也合规（J4 测试锚点）。
        if snapshot.reported || ownerSessionId == nil { return }
        // 前台抑制：active → inject 已可见，通知=打扰（F007 判定钉死）。
        if await isAppActive() { return }
        // 授权惰性请求；拒绝/出错静默跳过（fail open，登记）。
        guard await requestAuthorization() else { return }
        let title = retainHead(snapshot.label, maxBytes: Self.titleMaxBytes)
        await addNotification(snapshot.id, title, noticeText)
    }
}
