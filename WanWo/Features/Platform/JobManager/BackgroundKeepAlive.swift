//
//  BackgroundKeepAlive.swift
//  WanWo
//
//  【真机批 B4 · 后台保活】OpenMinis AIChatViewModel+BackgroundTask.swift
//  原件最小适配（beginBackgroundProcessing/endBackgroundProcessing 核心）：
//    · 切后台时申请 finite background task（iOS 给 ~30s 执行宽限）——
//      回合在窗口内继续跑完 → 触发"回合完成通知"（JobNotifier
//      .notifyTurnCompleted）→ 用户切回验收。这是"发任务→切走→做完→
//      通知"验收模型的物理前提。
//    · 窗口到期：系统收回执行权，App 冻结（WanWo 无静音音频等增强保活，
//      不移植 OpenMinis 的 re-arm/suspend 管理）——回前台后既有解冻涌出
//      路径恢复（真机已验证）。
//    · 无条件 begin 的副作用为零：窗口空转到点自动回收；有回合在飞时
//      窗口内 AI 继续（sleep 20 类短作业可全程后台完成）。
//

import Foundation
import UIKit

final class BackgroundKeepAlive: @unchecked Sendable {
    private static let logger = AppLogger(category: "keepalive")

    private let lock = NSLock()
    private var taskID: UIBackgroundTaskIdentifier = .invalid

    static let shared = BackgroundKeepAlive()

    /// 切后台调用（幂等——已持有即跳过）。
    func begin() {
        lock.lock(); defer { lock.unlock() }
        guard taskID == .invalid else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "WanWo-AgentLoop") {
            // 到期 handler：系统即将冻结——不做挂起管理（头注），仅日志+
            // 结束标记（防泄漏；回前台解冻涌出为既有恢复路径）。
            Self.logger.warning("[keepalive] background window expired — app will freeze until foreground")
            Self.shared.end()
        }
        if taskID == .invalid {
            Self.logger.warning("[keepalive] beginBackgroundTask REFUSED (.invalid)")
        } else {
            Self.logger.info("[keepalive] began id=\(taskID.rawValue) "
                             + "remaining=\(UIApplication.shared.backgroundTimeRemaining)")
        }
    }

    /// 回前台调用（幂等）。
    func end() {
        lock.lock(); defer { lock.unlock() }
        guard taskID != .invalid else { return }
        let id = taskID
        taskID = .invalid
        // MainActor：endBackgroundTask 的 UI 系面调用点（OpenMinis 同形）。
        Task { @MainActor in
            UIApplication.shared.endBackgroundTask(id)
            Self.logger.info("[keepalive] ended id=\(id.rawValue)")
        }
    }
}
