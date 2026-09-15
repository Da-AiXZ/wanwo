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

    /// M6.4（B3）：App 配置根（mounted-folders.json 等 App 元数据宿主面）。
    /// Library 不在 iOS Files 暴露面（UIFileSharingEnabled 只暴露 Documents/），
    /// 与 OpenMinis 把 mounts 元数据放进 MinisConfig（FileProvider 暴露根之外）
    /// 的意图一致。
    static var configPersistentDir: URL {
        persistentBase.appendingPathComponent("config", isDirectory: true)
    }

    // MARK: - 分组维度路径（M4-E+ P2：会话四桶分组化——brief §5.2 路径模型）
    //
    // 分组常量与派生的单一事实源居本文件（ISHRuntime 层）：Storage 层的
    // GroupStore 以同名字面薄壳转发引用（顺着 Storage→ISHRuntime 既有依赖
    // 方向），避免 ISHRuntime 反向依赖 Storage（派单锚点 1 的层依赖裁定）。

    /// 分组根目录名（persistentBase/groups）。
    static let groupsDirName = "groups"
    /// 默认分组 id（M9 前 UI 不做分组管理，全部会话归默认分组——brief §5.1）。
    static let defaultGroupID = "default"
    /// 默认分组显示名（本批无 UI，与 id 同值）。
    static let defaultGroupName = "default"
    /// 会话四桶已知 bucket 名（GroupStoreMigrator 识别依据；与
    /// FsContextRouter.perSessionBuckets 前缀表一致）。
    static let knownSessionBuckets = ["workspace", "attachments", "offloads", "browser"]

    /// 分组根目录：persistentBase/groups/<gid>。base 参数化——迁移器测试
    /// 注入临时根（GroupStoreMigratorTests fixture）。
    static func groupRoot(base: URL, groupID: String) -> URL {
        base.appendingPathComponent(groupsDirName, isDirectory: true)
            .appendingPathComponent(groupID, isDirectory: true)
    }

    /// 分组会话目录：persistentBase/groups/<gid>/sessions（SessionStore root 注入点）。
    static func groupSessionsRoot(base: URL, groupID: String) -> URL {
        groupRoot(base: base, groupID: groupID)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    // MARK: 分组级技能根（M4-E+ P3：workspace 根升格——brief §5.3）

    /// 分组级技能根 guest 前缀（dsh project 根形状 /var/wanwo/workspace/
    /// .agents/skills——P3 后 guest 心智一字不变；宿主翻译目标见
    /// groupSkillsProjectRoot）。
    static let projectSkillsLinuxDir = workspaceLinuxDir + "/.agents/skills"

    /// project 资源相对 groups/<gid>/ 的尾径（"workspace/.agents/skills"）——
    /// FsContextRouter 反向解析用；由 guest 前缀派生避免双真值。
    static let projectSkillsGroupTail = String(
        projectSkillsLinuxDir.dropFirst(linuxBaseDir.count + 1))

    /// 分组 workspace 桶根（无 sid 层——分组级跨会话共享；P3 技能根升格落点）。
    static func groupWorkspaceRoot(base: URL, groupID: String) -> URL {
        groupRoot(base: base, groupID: groupID)
            .appendingPathComponent("workspace", isDirectory: true)
    }

    /// 分组级技能根：groups/<gid>/workspace/.agents/skills（dsh project 根语义
    /// ——guest 路径 /var/wanwo/workspace/.agents/skills 的 P3 翻译目标；
    /// guest 写路径形状不变，翻译由 FsContextRouter/WorkspaceFileAccess 特判）。
    static func groupSkillsProjectRoot(base: URL, groupID: String) -> URL {
        groupWorkspaceRoot(base: base, groupID: groupID)
            .appendingPathComponent(".agents/skills", isDirectory: true)
    }

    /// 分组级 agent 资源根：groups/<gid>/workspace/.agents（M4-E 验收修复：
    /// fakefs/Swift 翻译粒度从 .agents/skills 提升为 .agents 整树——skills 粒度
    /// 会让父目录 .agents 落会话桶（AI 终端 find 即报不存在，误判写失败），
    /// 且 mkdir -p 逐级创建会跨宿主劈裂。skills 子目录语义不变（registry 扫描
    /// 与失效判定仍锚 .agents/skills）。
    static func groupAgentResourcesRoot(base: URL, groupID: String) -> URL {
        groupWorkspaceRoot(base: base, groupID: groupID)
            .appendingPathComponent(".agents", isDirectory: true)
    }

    /// 每会话四桶的宿主持久化目录（fs_context 路由目标）。
    /// M4-E+ P2：会话桶挂分组下——persistentBase/groups/<gid>/<sid>/<bucket>
    /// （brief §5.2；groupID 默认值保既有调用面零改动自动跟随默认分组；
    /// P3 将把无 sid 层的分组桶根升格为技能根，本函数届时不动）。
    static func sessionPersistentDir(for sid: String, bucket: String,
                                     groupID: String = defaultGroupID) -> URL {
        groupRoot(base: persistentBase, groupID: groupID)
            .appendingPathComponent(sid, isDirectory: true)
            .appendingPathComponent(bucket, isDirectory: true)
    }
}
