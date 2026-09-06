//
//  WanWoPaths.swift
//  WanWo
//
//  【中性适配 · 替代 OpenMinis `src/ios/Agent/Chat/AIChatViewModel+Misc.swift`
//   中的 minis* 路径常量段（L100–140 的 Shared Directory 部分）】
//  OpenMinis 冻结清单不含 AIChatViewModel（附录 A.8 明确排除），但其 ISHRuntime
//  原件（ISHExecutionCoordinator/MinisFsRouter）以静态常量方式引用这些路径；
//  此处按 §十三.8 改名纪律做最小内联替换：仅改产品字符串，不改语义。
//    /var/minis/**            → /var/wanwo/**
//    Library/MinisChat/minis  → Library/WanWo/wanwo
//  目录拓扑照搬 08 §三.4 的四桶 + 静态挂载（10-design §1.1）。
//

import Foundation

enum WanWoPaths {
    // MARK: - Linux (guest) 路径

    static let linuxBaseDir = "/var/wanwo"
    static let attachmentsLinuxDir = "/var/wanwo/attachments"
    static let offloadsLinuxDir = "/var/wanwo/offloads"
    static let workspaceLinuxDir = "/var/wanwo/workspace"
    static let browserLinuxDir = "/var/wanwo/browser"
    static let memoryLinuxDir = "/var/wanwo/memory"
    static let skillsLinuxDir = "/var/wanwo/skills"
    static let sharedLinuxDir = "/var/wanwo/shared"
    static let mcpServersLinuxDir = "/var/wanwo/mcp-servers"
    static let mountsLinuxDir = "/var/wanwo/mounts"

    // MARK: - 宿主持久化路径

    /// iOS persistent base for all wanwo data (Library/WanWo/wanwo/).
    static var persistentBase: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return lib.appendingPathComponent("WanWo/wanwo", isDirectory: true)
    }

    /// 全局（跨会话）静态挂载桶的宿主持久化目录。
    static var memoryPersistentDir: URL {
        persistentBase.appendingPathComponent("memory", isDirectory: true)
    }
    static var skillsPersistentDir: URL {
        persistentBase.appendingPathComponent("skills", isDirectory: true)
    }
    static var sharedPersistentDir: URL {
        persistentBase.appendingPathComponent("shared", isDirectory: true)
    }
    static var mcpServersPersistentDir: URL {
        persistentBase.appendingPathComponent("mcp-servers", isDirectory: true)
    }

    /// 每会话四桶的宿主持久化目录（fs_context 路由目标）。
    static func sessionPersistentDir(for sid: String, bucket: String) -> URL {
        persistentBase
            .appendingPathComponent(sid, isDirectory: true)
            .appendingPathComponent(bucket, isDirectory: true)
    }
}
