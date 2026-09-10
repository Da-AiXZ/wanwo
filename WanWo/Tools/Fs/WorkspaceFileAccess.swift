//
//  WorkspaceFileAccess.swift
//  WanWo
//
//  【按设计新写】出处：10-design §7.5（数据源纪律：fs 工具走 FsContextRouter
//  工作区桶宿主直读，不经 iSH fork——iOS 禁 spawn 的对应落地）+ §十一 M2.5
//  （F014：read-match-write 临界区共享）。
//  语义：
//    · 会话工作区桶 = 宿主 <persistentBase>/<sid>/workspace/，即 guest 视角的
//      /var/wanwo/workspace/（FsContextRouter perSessionBuckets 对应桶）。
//    · 路径安全：guest 绝对路径（/var/wanwo/workspace/**）与相对路径统一解析到
//      根内；规范化后必须仍在根内（防 ../ 逃逸），越界一律 nil（fail closed）。
//    · read-match-write 临界区：编辑类工具（edit / str_replace_editor / write）
//      经同一 NSLock 串行化读-改-写，防并行调用交错损坏（M2.5 验收项）。
//    · 写一律临时文件 + rename 原子替换。
//

import Foundation

final class WorkspaceFileAccess: @unchecked Sendable {
    let sessionId: String
    let rootURL: URL
    /// guest / 的宿主映射根（alpine rootfs data 目录 = RootfsInstaller.dataPath；
    /// P0-1 提权全域通道与 /tmp 白名单的解析落点。可注入以供测试）。
    let guestRootURL: URL
    /// 读-改-写临界区（编辑族工具共享；glob/grep 只读遍历不走此锁）。
    private let mutationLock = NSLock()

    private static let fileManager = FileManager.default

    init(sessionId: String, guestRoot: URL? = nil) {
        self.sessionId = sessionId
        self.rootURL = WanWoPaths.sessionPersistentDir(for: sessionId, bucket: "workspace")
        self.guestRootURL = guestRoot ?? RootfsInstaller.shared.dataPath
        try? Self.fileManager.createDirectory(at: rootURL,
                                              withIntermediateDirectories: true)
    }

    // MARK: - 路径解析与安全

    /// 把 guest/相对路径解析为根内的宿主 URL。
    /// 接受：`/var/wanwo/workspace/<tail>`、`<tail>`（相对根）、`./<tail>`。
    /// 越界（`..` 逃逸）返回 nil。
    func resolve(_ path: String) -> URL? {
        var tail = path
        let prefix = WanWoPaths.workspaceLinuxDir
        if tail == prefix {
            tail = ""
        } else if tail.hasPrefix(prefix + "/") {
            tail = String(tail.dropFirst(prefix.count + 1))
        }
        // 归一：去首部斜杠与 "./"。
        while tail.hasPrefix("/") { tail.removeFirst() }
        while tail.hasPrefix("./") { tail.removeFirst(2) }
        if tail.isEmpty {
            return rootURL
        }
        var candidate = rootURL.appendingPathComponent(tail).standardizedFileURL
        // "/private" 前缀归一（iOS symlink 惯例）后校验仍在根内。
        let root = rootURL.standardizedFileURL.path
        var candidatePath = candidate.path
        if candidatePath.hasPrefix("/private" + root) {
            candidatePath = String(candidatePath.dropFirst("/private".count))
            candidate = URL(fileURLWithPath: candidatePath)
        }
        guard candidatePath == root || candidatePath.hasPrefix(root + "/") else {
            return nil
        }
        return candidate
    }

    // MARK: - 提权感知解析（P0-1：围栏说什么，执行层兑现什么）

    /// 按生效模式把 guest/相对路径解析为宿主 URL（dsh 语义：sandbox 策略是
    /// 唯一边界——gate 放行的路径，执行通道必须能兑现。出处：
    /// tool-fs/sandbox.ts:87-108 resolvePolicy 返回 {...policy, mode: approvedMode}；
    /// fs-sandbox index.ts:1-27「Reads pass through untouched」）。
    ///  - 相对路径与 `/var/wanwo/workspace/**`：工作区桶（既有语义，全模式）。
    ///  - 其他 guest 绝对路径：
    ///      · danger-full-access → guest 全域映射（rootfs data 目录 = guest /
    ///        的宿主落点，RootfsInstaller.dataPath）；
    ///      · workspace-write/read-only 且在 /tmp 白名单内（SandboxPolicy.
    ///        writableRoots——gate 对 workspace-write 放行 /tmp）→ 同一 guest
    ///        映射（修「gate 放行 /tmp、执行层拒绝」的同墙断点）；
    ///      · 其余 → nil（fail closed 兜底；写侧此前已被 SandboxGate 拒绝）。
    ///  `..` 逃逸防护与既有 resolve 同级：规范化后必须仍在映射根内。
    func resolve(_ path: String, mode: SandboxMode) -> URL? {
        // ① 工作区解析命中（workspace 桶 + 相对路径）→ 既有语义直用。
        if let url = resolve(path) { return url }
        var p = path.trimmingCharacters(in: .whitespaces)
        guard p.hasPrefix("/") else { return nil }
        switch mode {
        case .dangerFullAccess:
            return resolveUnderGuestRoot(p)
        case .readOnly, .workspaceWrite:
            guard p == "/tmp" || p.hasPrefix("/tmp/") else { return nil }
            return resolveUnderGuestRoot(p)
        }
    }

    /// 读放行解析（reads pass through：读不设模式门，guest 绝对路径映射全域）。
    func resolveForRead(_ path: String) -> URL? {
        resolve(path, mode: .dangerFullAccess)
    }

    /// guest 绝对路径 → rootfs data 映射根内的宿主 URL（词法 containment 防
    /// `..` 逃逸，与既有 resolve 的 /private 前缀归一同源）。
    private func resolveUnderGuestRoot(_ path: String) -> URL? {
        let root = guestRootURL.standardizedFileURL
        var candidate = root.appendingPathComponent(path).standardizedFileURL
        let rootPath = root.path
        var candidatePath = candidate.path
        if candidatePath.hasPrefix("/private" + rootPath) {
            candidatePath = String(candidatePath.dropFirst("/private".count))
            candidate = URL(fileURLWithPath: candidatePath)
        }
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        return candidate
    }

    func exists(_ path: String) -> Bool {
        guard let url = resolveForRead(path) else { return false }
        return Self.fileManager.fileExists(atPath: url.path)
    }

    // MARK: - 读（dsh fs-sandbox「Reads pass through untouched」：全模式全域放行）

    func readText(_ path: String) throws -> String {
        guard let url = resolveForRead(path) else {
            throw WorkspaceError.pathOutsideRoot(path)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func readData(_ path: String) throws -> Data {
        guard let url = resolveForRead(path) else {
            throw WorkspaceError.pathOutsideRoot(path)
        }
        return try Data(contentsOf: url)
    }

    // MARK: - 写（原子；P0-1：mode 决定解析根——gate granted mode 随行兑现）

    @discardableResult
    func writeText(_ path: String, content: String, mode: SandboxMode) throws -> URL {
        try writeData(path, data: Data(content.utf8), mode: mode)
    }

    @discardableResult
    func writeData(_ path: String, data: Data, mode: SandboxMode) throws -> URL {
        guard let url = resolve(path, mode: mode) else {
            throw WorkspaceError.pathOutsideRoot(path)
        }
        return try writeAt(url, data: data)
    }

    /// 原子写核心（resolve 之后按宿主 URL 落盘；P0-1 从 writeData 抽出共用）。
    private func writeAt(_ url: URL, data: Data) throws -> URL {
        let dir = url.deletingLastPathComponent()
        try Self.fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        // 同名目录冲突先排除。
        var isDir: ObjCBool = false
        let targetExists = Self.fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
        if targetExists && isDir.boolValue {
            try? Self.fileManager.removeItem(at: tmp)
            throw WorkspaceError.isDirectory(url.path)
        }
        // ERR-013：replaceItemAt 要求目标文件已存在，写新文件会抛
        // NSCocoaErrorDomain 260 "no such file"——目标不存在时改走 moveItem。
        if targetExists {
            _ = try Self.fileManager.replaceItemAt(url, withItemAt: tmp)
        } else {
            _ = try Self.fileManager.moveItem(at: tmp, to: url)
        }
        return url
    }

    // MARK: - read-match-write 临界区（编辑族共享锁）

    /// 锁内完成 读 → 校验/变换 → 原子写。transform 抛错则整个调用失败，文件不动。
    /// P0-1：mode 决定解析根（提权批准后可落在工作区外 guest 路径）。
    func mutate(_ path: String, mode: SandboxMode,
                transform: (_ current: String) throws -> String) throws -> String {
        guard let url = resolve(path, mode: mode) else {
            throw WorkspaceError.pathOutsideRoot(path)
        }
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let current = try String(contentsOf: url, encoding: .utf8)
        let next = try transform(current)
        try writeAt(url, data: Data(next.utf8))
        return next
    }

    /// 只读遍历不走 mutationLock；遍历期间 VCS 元数据目录排除（dsh glob 语义）。
    func recursiveFiles() -> [URL] {
        guard let enumerator = Self.fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            // dsh glob VCS 排除六件套 + node_modules（等价 rg 的 gitignore 行为）。
            if name == ".git" || name == ".svn" || name == ".hg" || name == ".bzr"
                || name == ".jj" || name == ".sl" || name == "node_modules" {
                enumerator.skipDescendants(); continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            // ERR-014：enumerator 在 iOS 上常返回带 /private 符号链接前缀的路径，
            // 与 resolve()/rootURL 的口径不一致——glob 的 hasPrefix 过滤依赖
            // 两侧同口径，统一在此归一（与 resolve() 的 /private 处理同源）。
            out.append(Self.stripPrivatePrefix(url))
        }
        return out
    }

    /// 归一 enumerator 返回的路径：剥掉 iOS 符号链接惯例的 "/private" 前缀。
    static func stripPrivatePrefix(_ url: URL) -> URL {
        let p = url.path
        if p.hasPrefix("/private/var/") {
            return URL(fileURLWithPath: String(p.dropFirst("/private".count)))
        }
        return url
    }

    enum WorkspaceError: Error, CustomStringConvertible {
        case pathOutsideRoot(String)
        case isDirectory(String)

        var description: String {
            switch self {
            case .pathOutsideRoot(let p):
                return "path escapes the session workspace root: \(p)"
            case .isDirectory(let p):
                return "target is a directory, not a file: \(p)"
            }
        }
    }
}
