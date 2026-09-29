//
//  MemoryProjectLayout.swift
//  WanWo
//
//  【M8 批3 件 C1 · 冻结契约】记忆系统项目化——项目记忆桶解析。
//  契约源：analysis/m7-review/batch3-memory-project-dispatch.md（逐字）：
//    memoryBucketURL(forCwd:) = projectsHostRoot(cwd)/wanwo-memory/；
//    cwd 无法解析项目 → nil（调用方回落 legacy 全局桶 /var/wanwo/memory
//    ——只读保留，不迁移不删，登记）。
//  先例接续（B3 同构兄弟桶）：SessionNotesStore.init 桶解析段——
//    WanWoPaths.projectsHostRoot(forGuestPath: cwd) + notesDirName 拼接，
//    同一映射面（WanWoPaths.swift:43 fail closed）。
//  项目身份键口径（登记）：projectKey = 规范化后的 guest cwd 本身（工作区
//    目录即项目——与桶落点同源同真值；尾斜杠/空白归一，空串 → nil）。
//    会话挂项目 → 会话 header cwd 定格（AppEnvironment writer.header.cwd
//    创建时写入），候选匹配口径 = 双方 projectKey 相等（同为 nil = legacy
//    池）。
//  登记适配（批3派单「适配登记」①）：
//    - codex 全局单库（lib.rs:116-118 codex_home/memories）→ 项目分桶 =
//      用户拍板的万我增强（非还原 codex）。
//    - 快照清单落桶内隐藏文件 .memory-snapshot.json：快照扫描
//      skipsHiddenFiles / MemoryBackend hidden 过滤 / resolveScopedPath
//      隐藏组件拒绝三面均豁免（不进基线树、工具面不可见）；随桶同生共灭
//      （删桶 = 清单同删，首次 diff 全量 added 语义自洽）。
//

import Foundation

enum MemoryProjectLayout {

    /// 项目记忆桶目录名（与 SessionNotesConstants.notesDirName "wanwo-notes"
    /// 同构兄弟桶——批3派单冻结契约逐字）。
    static let memoryBucketDirName = "wanwo-memory"

    /// legacy 全局桶清单文件名（AppEnvironment 装配既有值——config/
    /// memory-snapshot.json，适配③快照清单持久位）。
    static let legacyManifestFilename = "memory-snapshot.json"
    /// 项目桶清单文件名（隐藏文件——豁免面见头注登记）。
    static let bucketManifestFilename = ".memory-snapshot.json"

    // MARK: - 冻结契约（batch3-memory-project-dispatch.md 逐字）

    /// 项目记忆桶根（projectsHostRoot(cwd)/wanwo-memory/）；cwd 无法解析
    /// 项目 → nil（调用方回落 legacy 全局桶——只读保留，登记）。
    static func memoryBucketURL(forCwd cwd: String?) -> URL? {
        guard let normalized = normalizedCWD(cwd),
              let projectHost = WanWoPaths.projectsHostRoot(forGuestPath: normalized) else {
            return nil
        }
        return projectHost.appendingPathComponent(memoryBucketDirName, isDirectory: true)
    }

    /// 项目身份键（设置页/账本按此分组）——规范化后的 guest cwd 本身
    /// （口径见头注登记）。
    static func projectKey(forCwd cwd: String?) -> String? {
        normalizedCWD(cwd)
    }

    // MARK: - 供值扩展（管线/工具/注入面消费——C2 消费点，登记）

    /// 项目桶 guest 路径（cwd/wanwo-memory——Phase2 整合 prompt memory_root
    /// 与整合子会话 cwd 用；nil = legacy）。
    static func memoryBucketGuestPath(forCwd cwd: String?) -> String? {
        guard let normalized = normalizedCWD(cwd),
              WanWoPaths.isProjectsGuestPath(normalized) else { return nil }
        return normalized + "/" + memoryBucketDirName
    }

    /// 候选匹配口径（登记）：会话 cwd 与当前工作区 cwd 的 projectKey 相等；
    /// 双方均不可解析项目 = 同属 legacy 池 → 匹配。
    static func isCandidate(sessionCwd: String?, currentCwd: String?) -> Bool {
        projectKey(forCwd: sessionCwd) == projectKey(forCwd: currentCwd)
    }

    /// 管线存储面（桶化落点）：cwd 可解析项目 → 项目桶 MemoryStorage
    /// （清单落桶内隐藏文件）；否则 → legacy 全局桶（与 AppEnvironment
    /// memory 装配段 rootURL/manifestURL 同源——AppEnvironment.swift:406-408）。
    static func storage(forCwd cwd: String?) -> MemoryStorage {
        guard let bucket = memoryBucketURL(forCwd: cwd) else { return legacyStorage }
        return MemoryStorage(
            rootURL: bucket,
            manifestURL: bucket.appendingPathComponent(bucketManifestFilename,
                                                       isDirectory: false))
    }

    /// legacy 全局桶存储面（只读保留——管线/回落统一引用；与 AppEnvironment
    /// 装配段同源，装配点迁移时以此为准）。
    static var legacyStorage: MemoryStorage {
        MemoryStorage(
            rootURL: WanWoPaths.memoryPersistentDir,
            manifestURL: WanWoPaths.configPersistentDir
                .appendingPathComponent(legacyManifestFilename))
    }

    // MARK: - 私有

    /// cwd 归一：trim 空白、去尾斜杠；空串 → nil（SessionHeader.cwd 可空、
    /// 探针面可能带尾斜杠——归一后作身份键，保证跨进程稳定）。
    private static func normalizedCWD(_ cwd: String?) -> String? {
        guard var path = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path == "/" ? nil : path
    }
}
