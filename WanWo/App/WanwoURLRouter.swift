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
    /// M6.6（B4）：待消费的资源 URL（右侧栏浏览器页签消费——B3 骨架日志位
    /// 的接线点落位；RootView openResourceURL 后清零）。
    @Published var pendingResourceURL: URL?
    /// 【P2-2 方案甲 2026-09-28】待消费的工作区文件打开请求（非 HTML 文本/
    /// 二进制类分流落点——文件页签打开；RootFrame 消费后清零）。
    @Published var pendingWorkspaceFilePath: String?

    private init() {}

    // MARK: - 分流判定（cc-haha 分流语义万我版；纯函数——单测直呼）

    /// wanwo:// 资源链接的打开落点判定。
    /// 出处对拍（cc-haha 全链调研 2026-09-28）：
    ///   · 文件树/普通点击 → 恒文件视图（WorkspaceFileTab.tsx:346
    ///     workspaceOpen.file——tab 内部按形态渲染 code/md/image/binary 提示）
    ///   · HTML 特例走浏览器（CurrentTurnChangeCard.tsx:89-96 +
    ///     htmlPreviewPolicy.ts shouldOfferStaticHtmlPreview——"要运行的"才
    ///     进浏览器；万我简化：.html/.htm 一律浏览器，框架项目模板区分不做
    ///     ——万我 AI 场景产物以手写单页为主，登记差异）
    ///   · 非 workspace host（browser 截图桶/attachments 媒体）维持浏览器
    ///     （文件页签树只见项目工作区，其它桶文件它无处定位）
    /// 用户拍板语义：文本在文件里打开，HTML 在浏览器里打开。
    enum ResourceRouteTarget: Equatable {
        case browser
        case workspaceFile(relativePath: String)
    }
    nonisolated static func routeTarget(for url: URL) -> ResourceRouteTarget {
        guard url.host?.lowercased() == "workspace" else { return .browser }
        // url.path 已 percent-decode 一次（WanwoURLPathDecoding 契约）。
        let path = url.path.hasPrefix("/")
            ? String(url.path.dropFirst()) : url.path
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "html" || ext == "htm" { return .browser }
        return .workspaceFile(relativePath: path)
    }

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
        // 资源链接：B4 接线点落位——【P2-2 方案甲】按形态分流（routeTarget）：
        // HTML/非 workspace 桶 → 浏览器页签（原语义）；workspace 内其它文件
        // → 文件页签定位（文本在文件里打开——用户拍板 2026-09-28）。
        switch Self.routeTarget(for: url) {
        case .browser:
            Self.logger.info("resource URL routed → sidebar browser tab: \(url.absoluteString)")
            pendingResourceURL = url
        case .workspaceFile(let relativePath):
            Self.logger.info("resource URL routed → sidebar files tab: \(relativePath)")
            pendingWorkspaceFilePath = relativePath
        }
    }

    /// RootView 消费完毕后复位。
    func consumePermissionsRoute() {
        pendingPermissionsRoute = false
    }

    /// 资源 URL 消费完毕后复位（B4）。
    func consumeResourceURL() {
        pendingResourceURL = nil
    }

    /// 【P2-2】工作区文件打开请求消费完毕后复位。
    func consumeWorkspaceFilePath() {
        pendingWorkspaceFilePath = nil
    }
}
