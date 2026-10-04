//
//  WOHaptics.swift
//  WanWo
//
//  【批0 件3】触觉三档（lody ChatHaptics 机制引入·万我最小形态）。
//  单一入口 WOHaptics.shared.notify(.success/.warning/.error)，挂
//  UINotificationFeedbackGenerator（iOS 10+，零依赖）——Core Haptics 流式
//  脉冲（lody ChatReplyHaptics/ChatReplyPulses）不在本批，后批评估。
//  lody 缓存生成器做法：generator 进程级单例复用 + 每次 notify 前 prepare()
//  （苹果推荐——预充电降低首振延迟，不重复构造）。
//  触发点纪律：只在事件真实发生处调用（phase 迁移/横幅出现/门控拦下），
//  不在 UI 按钮处——触觉跟事实走，不跟按钮走。
//

import UIKit

@MainActor
final class WOHaptics {
    static let shared = WOHaptics()

    /// 三档语义（UINotificationFeedbackGenerator 原生档位一一对应）。
    enum Kind {
        /// 发送成功 / 回合正常收敛。
        case success
        /// 重要确认（danger-full-access 门控拦下等待用户裁决）。
        case warning
        /// 发送 / 操作失败（回合错误、附件准入拒绝）。
        case error
    }

    /// 全局开关（设置项挂账——本批默认开，代码留缝：设置面落地后接偏好
    /// 存储读取，调用点零改动）。
    var isEnabled = true

    private let generator = UINotificationFeedbackGenerator()

    private init() {
        // 就地预充电（首次 notify 零构造延迟）。
        generator.prepare()
    }

    /// 触觉通知（MainActor 纪律：全部触发点在 ChatViewModel @MainActor 链上）。
    func notify(_ kind: Kind) {
        guard isEnabled else { return }
        generator.prepare()
        switch kind {
        case .success:
            generator.notificationOccurred(.success)
        case .warning:
            generator.notificationOccurred(.warning)
        case .error:
            generator.notificationOccurred(.error)
        }
    }
}
