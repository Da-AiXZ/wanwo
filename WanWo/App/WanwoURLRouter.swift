//
//  WanwoURLRouter.swift
//  WanWo
//
//  【M6.5 新写 · wanwo:// 深链路由器】出处：m6-scope-brief §5 / 10-design M6.5。
//  语义源 = OpenMinis：
//    · minis://settings/permissions 深链（OffloadPermissionManager.swift:241 的
//      deny 文案消费端）→ WanWo 侧 OffloadPermissionManager 已在 deny 文案里用
//      wanwo://settings/permissions（B1 批注释登记），本路由器是其消费端落地。
//    · 资源链接（wanwo://<bucket>/...）的 UI 消费端（浏览器/预览面）属 B4 右侧栏
//      ——本批只落 scheme 注册 + 路由分发骨架：资源 URL 在 WKWebView 内由
//      WanwoURLSchemeHandler（B2 保留代码路径）直接服务，App 级 onOpenURL 收到的
//      资源 URL 记日志并标注 B4 接线点。
//
//  路由面（本批）：
//    wanwo://settings/permissions → 设置·权限页（RootSelection.permissionDefaults
//      ——WanWo 现有权限入口；10-design M6.5 口径"路由到设置权限区"）
//    wanwo://<资源路径>           → B4 右侧栏浏览器/预览面（骨架日志位）
//

import Foundation
import SwiftUI

/// 深链路由目标（本批最小面）。
enum WanwoRoute: Equatable {
    /// 设置·权限页（wanwo://settings/permissions）。
    case permissions
    /// 资源链接（wanwo://<bucket>/...）——B4 右侧栏消费（本批仅骨架）。
    case resource(URL)
}

/// App 级深链路由器（WanWoApp.onOpenURL → 分发；RootView 订阅消费）。
@MainActor
final class WanwoURLRouter: ObservableObject {
    static let shared = WanwoURLRouter()

    private static let logger = AppLogger(category: "WanwoURLRouter")

    /// 待消费的权限页路由（RootView onReceive 置位消费——selection 跳转后清零）。
    @Published var pendingPermissionsRoute = false

    private init() {}

    /// onOpenURL 入口：识别 wanwo:// 族并分发；非 wanwo scheme 忽略。
    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "wanwo" else {
            Self.logger.warning("onOpenURL ignored non-wanwo URL: \(url.absoluteString)")
            return
        }
        // 深链：wanwo://settings/permissions（host = settings, path = /permissions）。
        if url.host?.lowercased() == "settings",
           url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == "permissions" {
            Self.logger.info("deep link → settings/permissions")
            pendingPermissionsRoute = true
            return
        }
        // 资源链接：分发骨架（UI 消费端 = B4 右侧栏浏览器/预览面接线点）。
        Self.logger.info("resource URL routed (B4 右侧栏接线点): \(url.absoluteString)")
        // 标注：资源 URL 由 WanwoURLSchemeHandler 在 WKWebView 内直接服务
        // （B2 保留代码路径）；App 级打开（如聊天流链接点按）的呈现面随 B4。
    }

    /// RootView 消费完毕后复位。
    func consumePermissionsRoute() {
        pendingPermissionsRoute = false
    }
}
