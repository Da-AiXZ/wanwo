//
//  BrowserUseOffloadBridge.swift
//  WanWo
//
//  【vendored 复用 · 源=OpenMinis src/ios/NativeOffloads/BrowserUseOffloadBridge.swift
//   全文 249 行（B2 批）】
//  Swift bridge for BrowserTabPool, called from BrowserUseOffload.m.
//  BrowserTabPool is Swift-only and @MainActor; this class exposes
//  per-session tab pools and a synchronous-facing execute method for
//  the ObjC handler to consume via a completion block.
//  适配点（详见 B2 交付报告）：
//    1. 文件头注释 MinisApp → WanWo；品牌/路径字符串 minis→wanwo 四类（B2 派单）；
//    2. 池解析降级：OpenMinis 两级（ViewModelCache 活动池 → fallbackPools）
//       在 WanWo 收敛为单级——AIChatViewModel/ViewModelCache 未随 M6 移植，
//       agent 工具（BrowserUseTool）与 shell CLI 同取 BrowserUseSessionStore
//       （Features/Browser/），"shell 与 agent 共享一份浏览器状态"语义保持；
//    3. ChatStore.getSession 存在性预检降级拆除（WanWo 无跨层会话查询缝），
//       残留池由 BrowserTabPoolRegistry 空闲驱逐/内存警告回收兜底（登记报告）；
//    4. ISHExecutionCoordinator.mountedSessionIdSnapshot → IshExecutorBridge.
//       mountedSessionIdSnapshot（WanWo ISHRuntime 同名同语义缝）；
//    5. AIChatViewModel.minisBrowserPersistentDir/minisBrowserLinuxDir →
//       WanWoPaths.sessionPersistentDir(bucket:"browser") / browserLinuxDir。
//

import Foundation

@objc public class BrowserUseOffloadBridge: NSObject {

    private static let logger = AppLogger(category: "BrowserUseOffloadBridge")

    /// Fallback pools keyed by session id — used only when the corresponding
    /// `AIChatViewModel` is not currently cached (e.g. Terminal opened for a
    /// session whose chat UI hasn't been instantiated yet in this process).
    /// When the agent-side vm is cached we reuse its `browserTabPool` directly
    /// so the shell and the agent share one browser state.
    ///
    /// Sentinel key `"__unmounted__"` collects the rare invocations with no
    /// resolvable session (kernel not booted / mount missing).
    /// 【WanWo 适配②】登记表本体收敛到 BrowserUseSessionStore（Features/
    /// Browser/）——agent 工具与 shell CLI 同取一表，共享浏览器状态语义保持；
    /// 本文件不再自持字典（原 fallbackPools 删除，登记报告）。

    /// Sentinel session id for invocations with no active mount.
    private static let unmountedSentinel = "__unmounted__"

    /// Resolve the tab pool for the given session id.
    ///
    /// Resolution order:
    ///   1. Live `AIChatViewModel.browserTabPool` from `ViewModelCache` —
    ///      unifies UI-visible tabs with shell CLI usage.
    ///   2. Fallback pool bound to this sid, reused across subsequent CLI
    ///      invocations so successive shell commands see consistent tabs.
    ///      Allocated on demand iff the session still exists in ChatStore.
    ///
    /// Returns `nil` when the session has been deleted — caller must surface
    /// an error to the shell.
    @MainActor
    private static func pool(for sid: String) async -> BrowserTabPool? {
        if sid == Self.unmountedSentinel {
            return sentinelPool()
        }
        // 【WanWo 适配③】ChatStore.getSession 存在性预检降级拆除（无跨层
        // 会话查询缝）——直接经登记表取/建池；删除会话残留池由 registry
        // 空闲驱逐/内存警告回收兜底。
        let p = BrowserUseSessionStore.shared.pool(for: sid)
        logger.info("Resolved browser pool for session \(sid.prefix(8))")
        return p
    }

    @MainActor
    private static func sentinelPool() -> BrowserTabPool {
        BrowserUseSessionStore.shared.pool(for: Self.unmountedSentinel)
    }

    /// Release the fallback pool for a session. Live vm-owned pools are
    /// managed by the vm lifecycle; this only touches bridge-owned fallbacks.
    /// Called from `AIChatViewModel.clearChat` / session deletion paths.
    /// 【WanWo 适配②】转发 BrowserUseSessionStore.releasePool（单级登记表）。
    @objc public static func releasePool(forSession sessionId: String) {
        Task { @MainActor in
            BrowserUseSessionStore.shared.releasePool(forSession: sessionId)
            logger.info("Released browser pool for session \(sessionId.prefix(8))")
        }
    }

    /// Execute a browser action given a JSON payload matching the
    /// `browser_use` tool schema. The completion block receives a
    /// dictionary describing the result; the ObjC caller is responsible
    /// for serializing it to the guest's stdout.
    ///
    /// Session resolution: reads `ISHExecutionCoordinator.mountedSessionId`
    /// at the moment the handler fires. Because shell execution is
    /// serialized by the coordinator actor and the mount-swap happens
    /// synchronously before the guest command runs, this value is
    /// guaranteed to be the session that owns the current `/var/wanwo/`
    /// bind mount for the lifetime of this CLI invocation.
    ///
    /// When `withBase64` is false (default), any captured screenshot is
    /// persisted to that session's `/var/wanwo/browser/` directory and
    /// surfaced via `image_path` + `wanwo_url` instead of `image_base64`.
    /// Set `withBase64` to true only when the caller explicitly wants the
    /// raw base64 blob inline (e.g. piping to another tool).
    ///
    /// Keys on success: text, success, page_url?, image_path?,
    /// wanwo_url?, image_base64?, fetched_file?, fetched_bytes?,
    /// fetched_path?, fetched_wanwo_url?.
    /// Keys on failure: text, success=false.
    @objc public static func execute(
        withJson json: String,
        withBase64: Bool,
        completion: @escaping (NSDictionary) -> Void
    ) {
        let bridgeStart = CFAbsoluteTimeGetCurrent()

        guard let input = BrowserActionInput.parse(from: json) else {
            completion([
                "text": "Error: Invalid browser_use input. Required: 'action' parameter.",
                "success": false,
            ] as NSDictionary)
            return
        }

        logger.info("[BridgeTiming] enter action=\(input.action.rawValue) tab_id=\(input.tabId.map(String.init) ?? "nil") url=\(input.url?.prefix(80) ?? "nil")")

        // Resolve the owning session via the lock-protected snapshot BEFORE
        // hopping to MainActor. Awaiting the coordinator actor here used to
        // deadlock under shell pressure: the guest task thread sits on
        // `dispatch_semaphore_wait`, and this task's MainActor hop has to
        // beat every `dispatch_async(main_queue, ^{ ctx.lineCallback(line) })`
        // coming out of ISHShellExecutor to get picked up. Reading the
        // nonisolated snapshot synchronously avoids both the coordinator
        // actor suspension and one MainActor ordering hop.
        // 【WanWo 适配④】ISHExecutionCoordinator.mountedSessionIdSnapshot →
        // IshExecutorBridge.mountedSessionIdSnapshot（WanWo ISHRuntime 同名
        // 同语义缝——lock-protected 非 isolated 快照，锁保护读免死锁语义同源）。
        let sid = IshExecutorBridge.mountedSessionIdSnapshot
                  ?? Self.unmountedSentinel

        Task { @MainActor in
            guard let pool = await Self.pool(for: sid) else {
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - bridgeStart) * 1000)
                logger.info("[BridgeTiming] pool_not_found elapsed=\(elapsedMs)ms sid=\(sid.prefix(8))")
                completion([
                    "text": "Error: session \(sid) no longer exists — cannot run browser_use.",
                    "success": false,
                ] as NSDictionary)
                return
            }

            let poolResolvedMs = Int((CFAbsoluteTimeGetCurrent() - bridgeStart) * 1000)
            logger.info("[BridgeTiming] pool_resolved elapsed=\(poolResolvedMs)ms sid=\(sid.prefix(8))")

            do {
                // CLI is a serial human/script driver — run in single-tab mode
                // so navigate → execute_js / get_page_info / get_text etc. all
                // hit the page just navigated to, instead of being fanned out
                // across grace-busy tabs. Explicit --tab-id still routes
                // normally. Agent tool path keeps the default (fan-out).
                // [T-browser-executejs-stale-context-ios]
                let result = try await pool.execute(action: input, singleTab: true)
                let poolDoneMs = Int((CFAbsoluteTimeGetCurrent() - bridgeStart) * 1000)
                logger.info("[BridgeTiming] pool_execute_done elapsed=\(poolDoneMs)ms action=\(input.action.rawValue)")

                let encoded = Self.encode(result, withBase64: withBase64, sid: sid)
                let totalMs = Int((CFAbsoluteTimeGetCurrent() - bridgeStart) * 1000)
                logger.info("[BridgeTiming] completion elapsed=\(totalMs)ms action=\(input.action.rawValue) success=\(result.success)")
                completion(encoded)
            } catch {
                let totalMs = Int((CFAbsoluteTimeGetCurrent() - bridgeStart) * 1000)
                logger.info("[BridgeTiming] error elapsed=\(totalMs)ms action=\(input.action.rawValue) error=\(error.localizedDescription.prefix(120))")
                completion([
                    "text": "Error: \(error.localizedDescription)",
                    "success": false,
                ] as NSDictionary)
            }
        }
    }

    private static func encode(_ r: BrowserActionResult, withBase64: Bool, sid: String) -> NSDictionary {
        let out = NSMutableDictionary()
        out["text"] = r.text
        out["success"] = r.success
        if let url = r.pageURL, !url.isEmpty { out["page_url"] = url }

        // Persist screenshot + fetched bytes under the invoking session's
        // browser directory. We resolve the host path directly from the sid
        // captured at execute() entry instead of querying the coordinator's
        // live mount table — a concurrent UI session-switch could null that
        // out mid-flight. 【WanWo 适配⑤】WanWoPaths.sessionPersistentDir
        // (bucket:"browser") 是纯路径拼接 groups/default/<sid>/browser/
        // （=Library/WanWo/wanwo/…），恰为该会话 /var/wanwo/browser/
        // bind-mount 的宿主目录。
        let browserHostDir: URL? = (sid == Self.unmountedSentinel)
            ? nil
            : WanWoPaths.sessionPersistentDir(for: sid, bucket: "browser")

        // ── Screenshot / snapshot ──
        var persistedImagePath: String? = nil
        if let b64 = r.base64Image, !b64.isEmpty, let data = Data(base64Encoded: b64) {
            let filename = "screenshot_\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
            if let hostDir = browserHostDir {
                try? FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
                let dest = hostDir.appendingPathComponent(filename)
                do {
                    try data.write(to: dest)
                    let linuxPath = "\(WanWoPaths.browserLinuxDir)/\(filename)"
                    persistedImagePath = linuxPath
                    out["image_path"] = linuxPath
                    out["wanwo_url"] = "wanwo://browser/\(filename)"
                } catch {
                    logger.warning("Failed to persist screenshot to \(dest.path): \(error.localizedDescription)")
                }
            } else {
                logger.warning("No /var/wanwo/browser mount — falling back to base64-only output")
            }
        }

        // Fall back to the in-memory host path only when we couldn't persist.
        if persistedImagePath == nil, let p = r.imageFilePath, !p.isEmpty {
            out["image_path"] = p
        }

        if withBase64, let b = r.base64Image, !b.isEmpty {
            out["image_base64"] = b
        }

        // ── Fetched file (fetch action) ──
        if let name = r.fetchedFileName, !name.isEmpty {
            out["fetched_file"] = name
            if let data = r.fetchedFileData {
                out["fetched_bytes"] = data.count
                if let hostDir = browserHostDir {
                    try? FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
                    let dest = hostDir.appendingPathComponent(name)
                    do {
                        try data.write(to: dest)
                        let linuxPath = "\(WanWoPaths.browserLinuxDir)/\(name)"
                        out["fetched_path"] = linuxPath
                        out["fetched_wanwo_url"] = "wanwo://browser/\(name)"
                    } catch {
                        logger.warning("Failed to persist fetched file to \(dest.path): \(error.localizedDescription)")
                    }
                }
            }
        }

        return out
    }
}
