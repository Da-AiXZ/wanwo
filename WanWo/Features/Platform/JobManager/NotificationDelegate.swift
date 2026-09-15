//
//  NotificationDelegate.swift
//  WanWo
//
//  【真机批 B3 · 前台通知呈现】OpenMinis ShortcutNotificationDelegate
//  原件适配（SendPromptIntent.swift:421-465，先看后写）：
//    · willPresent → [.banner]：iOS 默认行为 = App 前台时本地通知不展示
//      横幅且不进通知中心（静默丢弃）——真机实证：作业完成通知"判定
//      通过（[jobnotify] not active — will notify 打点在场）、授权允许
//      （设置已开）、通知栏无通知"（用户回前台瞬间解冻涌出，投递时刻
//      App 已 active → 前台静默丢弃）。实现本回调后前台横幅恢复。
//    · 无声裁定维持：completionHandler 不含 .sound（JobNotifier 头注
//      "无声：不设 content.sound"——提示职责模型侧 inject 已承担）。
//    · delegate 注册时序纪律（OpenMinis :424-430 实证注释）：必须在
//      didFinishLaunching 返回前设置，否则冷启动投递缺失；SwiftUI
//      .onAppear 注册太晚——WanWo 注册点 = WanWoApp.init。
//    · didReceive（点通知跳对应会话）：本轮最小实现不实现——点击仅
//      打开 App；"点通知跳会话"登记为后续增强（OpenMinis :436-455 有
//      完整原件可对照）。
//

import Foundation
import UserNotifications

final class WanWoNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WanWoNotificationDelegate()

    /// 启动最早期调用（WanWoApp.init）——时序纪律见头注。
    func register() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// App 前台时也展示横幅（iOS 默认静默丢弃——见头注）。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
