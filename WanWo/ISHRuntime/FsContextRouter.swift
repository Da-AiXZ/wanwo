//
//  FsContextRouter.swift
//  WanWo
//
//  【vendored 原件 · 出处 OpenMinis `src/ios/Agent/ISH/MinisFsRouter.swift`（GPL v3）】
//  10-design 附录 A.2 / §四 ISHRuntime 映射 / §十三.8 改名纪律。
//  类名 MinisFsRouter → FsContextRouter；路径 /var/minis → /var/wanwo。
//  fs_context 令牌分配（u64、0 永不下发）、hot-path 纯哈希查表、
//  正向/反向翻译钩子、[已知坑] 防 stale sid 反向翻译守卫 —— 全部逐行保留。
//

import Foundation

/// Routes guest paths under /var/wanwo/{offloads,attachments,workspace,browser}
/// to per-session host directories via the iSH fakefs path-translate hook.
/// 【万我适配】原注释路径为 /var/minis/...，宿主基目录 Library/MinisChat/minis
/// → Library/WanWo/wanwo。
final class FsContextRouter: @unchecked Sendable {
    static let shared = FsContextRouter()

    /// Guest path prefixes that route per-session. Anything under one of these
    /// becomes ~/Library/.../wanwo/<sid>/<bucket>/<tail>. Paths under
    /// /var/wanwo/{memory,skills,shared} stay global and are NOT listed here —
    /// they fall through to the legacy g_bind_mounts[] table.
    private let perSessionBuckets: [(linuxPrefix: String, hostSubdir: String)] = [
        (WanWoPaths.offloadsLinuxDir,    "offloads"),
        (WanWoPaths.attachmentsLinuxDir, "attachments"),
        (WanWoPaths.workspaceLinuxDir,   "workspace"),
        (WanWoPaths.browserLinuxDir,     "browser"),
    ]

    private let lock = NSLock()
    private var nextContext: UInt64 = 1
    private var contextToSid: [UInt64: String] = [:]
    private var sidToContext: [String: UInt64] = [:]

    /// Host base URL (~/Library/WanWo/wanwo). Captured once at install time.
    private let wanwoBaseURL: URL

    private init() {
        self.wanwoBaseURL = WanWoPaths.persistentBase
    }

    /// Allocate a stable fs_context token for `sid`. Repeated calls with the
    /// same sid return the same token, so workers can be respawned without
    /// invalidating prior routing.
    func context(for sid: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        if let existing = sidToContext[sid] { return existing }
        let ctx = nextContext
        nextContext &+= 1
        if nextContext == 0 { nextContext = 1 }   // never hand out 0 (= "no override")
        contextToSid[ctx] = sid
        sidToContext[sid] = ctx
        return ctx
    }

    /// Reverse lookup. Returns nil if the token was never issued or has been
    /// freed. Hot-path: keep this branchless.
    func sid(for context: UInt64) -> String? {
        if context == 0 { return nil }
        lock.lock(); defer { lock.unlock() }
        return contextToSid[context]
    }

    /// Install the path-translate hook on ISHKernel. Idempotent; call once
    /// at boot before any session task is spawned. Installs both the
    /// forward hook (guest→host) and the reverse hook (host→guest) — the
    /// reverse hook is needed by readdir/getpath when fakefs has resolved
    /// a hook-routed path through F_GETPATH and needs to map it back so
    /// meta.db inode lookup works.
    func installHook() {
        ISHKernel.shared.installPathTranslateHandler { [weak self] guestPath, fsContext in
            return self?.translate(guestPath: guestPath, fsContext: fsContext)
        }
        ISHKernel.shared.installPathReverseHandler { [weak self] hostPath in
            return self?.reverse(hostPath: hostPath)
        }
    }

    // MARK: - Translation

    /// The hook itself. Called on iSH worker threads, on the fakefs hot path.
    /// MUST stay non-blocking — only a hash lookup + a few string ops.
    private func translate(guestPath: String, fsContext: UInt64) -> String? {
        guard fsContext != 0, let sid = sid(for: fsContext) else { return nil }
        return hostPath(forGuest: guestPath, sid: sid)
    }

    /// Resolve a guest path under one of the per-session buckets to its host
    /// URL for the given sid. Returns nil if the path is not under any
    /// per-session bucket (caller should fall back to the static mount table).
    /// Used by Swift call sites that need the host path without going through
    /// iSH (e.g. NSFileCoordinator on attachments).
    func hostURL(forGuest guestPath: String, sid: String) -> URL? {
        guard let path = hostPath(forGuest: guestPath, sid: sid) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func hostPath(forGuest guestPath: String, sid: String) -> String? {
        for bucket in perSessionBuckets {
            let prefix = bucket.linuxPrefix
            guard guestPath.hasPrefix(prefix) else { continue }
            let prefixEnd = guestPath.index(guestPath.startIndex, offsetBy: prefix.count)
            if prefixEnd != guestPath.endIndex && guestPath[prefixEnd] != "/" {
                continue
            }
            let tail = String(guestPath[prefixEnd...])
            return wanwoBaseURL
                .appendingPathComponent(sid, isDirectory: true)
                .appendingPathComponent(bucket.hostSubdir, isDirectory: true)
                .path + tail
        }
        return nil
    }

    /// Reverse hook: given a host APFS path under <wanwoBaseURL>/<sid>/<bucket>,
    /// return the canonical guest path /var/wanwo/<bucket>/<tail>.
    /// Returns nil if the path doesn't live under any per-session bucket
    /// (caller falls back to the static bind_mount_resolve table).
    private func reverse(hostPath: String) -> String? {
        let basePath = wanwoBaseURL.path
        // F_GETPATH on iOS may resolve /var → /private/var; normalize that
        // so a single prefix compare suffices.
        var stripped = hostPath
        if hostPath.hasPrefix("/private/var/") && basePath.hasPrefix("/var/") {
            stripped = String(hostPath.dropFirst("/private".count))
        }
        guard stripped.hasPrefix(basePath + "/") else { return nil }
        let rest = stripped.dropFirst(basePath.count + 1)  // "<sid>/<bucket>[/tail]"
        // Split into sid / bucket / tail
        let parts = rest.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let sidPart = String(parts[0])
        let bucketName = String(parts[1])
        // Only translate sids we've actually issued a context for. Without this
        // guard, any path that happens to live under <basePath>/<X>/<known-bucket>/
        // would be reverse-translated even when <X> is a stale or unrelated
        // directory — harmless today but masks the cause of bugs.
        lock.lock()
        let known = sidToContext[sidPart] != nil
        lock.unlock()
        guard known else { return nil }
        guard let bucket = perSessionBuckets.first(where: { $0.hostSubdir == bucketName })
        else { return nil }
        let tail = parts.count == 3 ? "/" + parts[2] : ""
        return bucket.linuxPrefix + tail
    }
}
