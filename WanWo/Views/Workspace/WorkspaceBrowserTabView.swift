//
//  WorkspaceBrowserTabView.swift
//  WanWo
//
//  【M6.6 新写（B4）· 语义源 m6-scope-brief §6.3/§6.6a④】浏览器页签：
//  嵌 B2 的 BrowserSheetView（完整浏览器面——地址栏/工具栏/空态/页签都是
//  它自带的）；wanwo:// 资源 URL 接线 = 打开页签即导航（B3 resolveWanwoURL
//  已闭环，资源 URL 由 WKWebView 内 WanwoURLSchemeHandler 直接服务）。
//  ⚠️ B2 遗留边缘拍板项（downloads=ask 手动浏览 fail closed）本批落定：
//  浏览器页签可见时安装 OriginPolicy.uiAskHandler（用户可见 sheet 确认；
//  工具层 agent 审批缝优先级更高、互不抢道——OriginPolicy 两层裁决序）；
//  页签离场撤缝回到 fail closed。选择理由：保持 downloads=ask 政策档不变、
//  只补呈现缝——手动浏览的下载也该过同一道用户裁决（fail-open 改默认档
//  会削弱 B2 语义，不取）。
//

import SwiftUI

/// 浏览器页签（每页签一枚独立 BrowserTabPool——与 agent 会话池经
/// BrowserTabPoolRegistry 全局并发护栏协调）。
struct WorkspaceBrowserTabView: View {
    /// 打开即导航的目标（wanwo:// 资源深链；nil = 空白起始）。
    /// 批12+联动B：改为 var——AI 单活动页签跟随（右栏模型改写本值，
    /// onChange 消费=同页签换 URL 不新建）。
    var initialURL: URL?

    /// 【批2 B①】宿主环境——当前选中会话 id 的锚（pool.sessionId 绑定源）。
    @ObservedObject var environment: AppEnvironment

    @StateObject private var pool = BrowserTabPool()
    @ObservedObject private var asker = BrowserDownloadAsker.shared
    @State private var navigated = false

    var body: some View {
        BrowserSheetView(pool: pool)
            .onAppear {
                asker.install()
                // 【批2 B①】pool.sessionId 绑定当前选中会话——BrowserTabPool
                // 把它经 sessionIdProvider（:1323）喂给 BrowserUseManager 的
                // WKDownload decideDestination（:2582）；此前本页签的 pool 从未
                // 设置 sessionId → 手动页签下载批准后被静默取消（用户允许了
                // 却无落盘、无任何可见反馈）。didSet 副作用 = loadPersistedURLs
                // （BrowserTabPool:304-310），绑定即恢复该会话的页签 URL 持久化
                // ——原设计能力顺带接通。
                pool.sessionId = WorkspaceRightSidebarView.sessionID(of: environment.selection)
                if !navigated, let initialURL {
                    navigated = true
                    pool.ensureTabForUI()
                    pool.activeManager?.loadURL(initialURL.absoluteString)
                }
            }
            // 会话切换跟随（批2 简报 B① 修法原句：onChange）。
            .onChange(of: environment.selection) { selection in
                pool.sessionId = WorkspaceRightSidebarView.sessionID(of: selection)
            }
            // 批12+联动B：AI 单活动页签跟随——右栏模型改写 initialURL →
            // 同页签换 URL（不新建页签；WKWebView 原生返回键=AI 开过的页历史）。
            .onChange(of: initialURL) { newURL in
                guard let newURL else { return }
                navigated = true
                pool.ensureTabForUI()
                pool.activeManager?.loadURL(newURL.absoluteString)
            }
            .onDisappear {
                asker.uninstall()
            }
            .sheet(item: Binding(
                get: { asker.frontmost },
                set: { newValue in
                    // 点外/下拉关闭 = 拒绝（fail closed——续流必须收口）。
                    if newValue == nil, let current = asker.frontmost {
                        asker.respond(to: current, allow: false)
                    }
                })) { request in
                downloadConfirm(request)
            }
    }

    /// 下载确认（形态从简——sheet 双钮；理由随 B4 报告）。
    private func downloadConfirm(_ request: BrowserDownloadAsker.Request) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("允许下载？")
                .font(.system(size: 17, weight: .semibold))
            Text(request.reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("拒绝") { asker.respond(to: request, allow: false) }
                    .buttonStyle(.bordered)
                Button("允许下载") { asker.respond(to: request, allow: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .presentationDetents([.medium])
    }
}

// MARK: - downloads=ask 的 UI 呈现缝（B2 fail closed 边缘拍板的落地面）

/// 手动浏览下载确认协调器：页签可见时安装为 OriginPolicy 第二层审批缝。
/// 裁决序（OriginPolicy.authorize）：agent 工具层 askHandler（每次 execute
/// 接线）优先 → uiAskHandler（本协调器）→ 都缺 = fail closed。
/// 并发请求排队（多下载同时到达逐条确认——continuation 挂起）。
@MainActor
final class BrowserDownloadAsker: ObservableObject {

    struct Request: Identifiable {
        let id = UUID()
        let reason: String
        fileprivate let continuation: CheckedContinuation<Bool, Never>
    }

    static let shared = BrowserDownloadAsker()

    /// 队首（sheet 绑定；nil = 无待确认）。
    @Published private(set) var frontmost: Request?

    private var queue: [Request] = []
    private var installed = false

    private init() {}

    /// 页签 onAppear 安装（幂等）。
    func install() {
        guard !installed else { return }
        installed = true
        OriginPolicy.shared.uiAskHandler = { [weak self] reason in
            guard let self else { return false }
            return await self.ask(reason: reason)
        }
    }

    /// 页签 onDisappear 撤缝（回到 fail closed）；在途请求一律拒绝收敛。
    func uninstall() {
        OriginPolicy.shared.uiAskHandler = nil
        installed = false
        let pending = queue
        queue.removeAll()
        frontmost = nil
        for request in pending {
            request.continuation.resume(returning: false)
        }
    }

    private func ask(reason: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let request = Request(reason: reason, continuation: continuation)
            queue.append(request)
            if frontmost == nil {
                advance()
            }
        }
    }

    /// 用户裁决（allow → 放行本次下载；拒绝/撤缝 → 取消）。
    func respond(to request: Request, allow: Bool) {
        guard let index = queue.firstIndex(where: { $0.id == request.id }) else { return }
        queue.remove(at: index)
        request.continuation.resume(returning: allow)
        advance()
    }

    private func advance() {
        frontmost = queue.first
    }
}
