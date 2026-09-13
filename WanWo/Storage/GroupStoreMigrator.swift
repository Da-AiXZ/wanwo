//
//  GroupStoreMigrator.swift
//  WanWo
//
//  【M4-E+ P1 新写 · 项目锚点存储半边】出处：m4e-anchor-scope-brief §5.1/§5.2/§六 P1。
//  方案 A：在「会话级」与「全局级」之间插入「分组」存储归属层，默认单分组
//  （M9 前 UI 不做分组管理，全部会话自动归入默认分组），桶路径按分组维度组织。
//  本迁移器把存量会话数据搬入 groups/default/，并回填 GRDB groupId：
//    · 旧 sessionsRoot（base/sessions）下 *.jsonl → groups/default/sessions/
//    · persistentBase 直下「目录名形状为 UUID 且含已知 bucket 子目录至少其一」
//      的会话桶目录 → groups/default/<sid>/
//    · GRDB sessionIndex.groupId IS NULL 回填 'default'
//  硬约束（会话数据零丢失）：先建后搬、同卷 rename 原子迁移（FileManager.
//  moveItem 同卷=原子 rename）、失败不删源（源在即数据在）、幂等（重复运行
//  no-op）、fail-open（单项失败记日志继续其余，App 照常启动，下次启动重试）。
//  非 UUID 目录（config/skills/shared/mcp-servers/memory/spill/groups 本身）
//  一概不触碰（brief §5.4 明确不动面）。
//

import Foundation

/// 分组层常量与路径派生（P1 仅默认单分组；M9 UI 分组管理后按需扩展）。
enum GroupStore {
    /// 默认分组 id（v3 seed 与迁移器回填共用常量；brief §5.1）。
    static let defaultGroupID = "default"
    /// 默认分组显示名（本批无 UI，与 id 同值）。
    static let defaultGroupName = "default"
    /// 会话四桶已知 bucket 名——迁移器识别 UUID 目录是否为会话桶目录的依据；
    /// 与 FsContextRouter.perSessionBuckets 前缀表一致（FsContextRouter.swift:26-32）。
    static let knownBuckets = ["workspace", "attachments", "offloads", "browser"]

    /// 分组根目录：persistentBase/groups/<gid>（brief §5.2 路径模型）。
    static func groupRoot(base: URL, groupID: String) -> URL {
        base.appendingPathComponent("groups", isDirectory: true)
            .appendingPathComponent(groupID, isDirectory: true)
    }

    /// 分组会话目录：persistentBase/groups/<gid>/sessions（SessionStore root 注入点）。
    static func groupSessionsRoot(base: URL, groupID: String) -> URL {
        groupRoot(base: base, groupID: groupID)
            .appendingPathComponent("sessions", isDirectory: true)
    }
}

/// 存量会话数据分组迁移器。触发时机：AppEnvironment init（SessionDatabase
/// v3 迁移后、SessionStore 构造前）同步执行一次（brief §5.2 存量迁移口径）。
struct GroupStoreMigrator {

    /// 迁移结果（os_log 计数呈报 + 测试断言用）。
    struct Report: Equatable {
        var movedJSONLFiles = 0
        var movedBucketDirs = 0
        /// 目标已存在同名（视为已迁移）而跳过的条目数。
        var skippedConflicts = 0
        /// 搬移失败（源保留、下次启动重试）的条目数。
        var failedItems = 0
        /// GRDB groupId 回填行数。
        var backfilledRows = 0
    }

    private static let logger = AppLogger(category: "group-migrator")

    /// persistentBase（WanWoPaths.persistentBase——分组根的挂载基点）。
    let base: URL
    let database: SessionDatabase

    init(base: URL, database: SessionDatabase) {
        self.base = base
        self.database = database
    }

    /// 旧 sessionsRoot（base/sessions——改造前 AppEnvironment.swift:104 形状）。
    private var legacySessionsRoot: URL {
        base.appendingPathComponent("sessions", isDirectory: true)
    }

    /// 目标分组根（groups/default）。
    private var defaultGroupRoot: URL {
        GroupStore.groupRoot(base: base, groupID: GroupStore.defaultGroupID)
    }

    /// 执行迁移（幂等：源不存在/已迁移/无 NULL 行 → no-op）。
    func migrate() -> Report {
        var report = Report()
        // 先建后搬：目标骨架（groups/default/sessions）先行。创建失败不 raise
        // ——单项搬移届时自然报错进入 fail-open 计数，App 照常启动。
        try? FileManager.default.createDirectory(
            at: defaultGroupRoot.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true)

        migrateLegacyJSONL(&report)
        migrateLegacyBucketDirs(&report)
        report.backfilledRows = database.backfillGroupIDs(
            groupID: GroupStore.defaultGroupID)

        // 有实际动静才记日志（常态第二次启动起静默）。
        if report.movedJSONLFiles > 0 || report.movedBucketDirs > 0
            || report.skippedConflicts > 0 || report.failedItems > 0
            || report.backfilledRows > 0 {
            Self.logger.info(
                "group store migration: jsonl=\(report.movedJSONLFiles) "
                    + "buckets=\(report.movedBucketDirs) "
                    + "conflicts=\(report.skippedConflicts) "
                    + "failed=\(report.failedItems) "
                    + "backfilled=\(report.backfilledRows)")
        }
        return report
    }

    // MARK: - 搬移阶段

    /// 旧 sessionsRoot 下 *.jsonl → groups/default/sessions/（仅 jsonl；其余
    /// 文件不动）。
    private func migrateLegacyJSONL(_ report: inout Report) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: legacySessionsRoot, includingPropertiesForKeys: nil) else {
            return // 旧目录不存在（新装/已迁空）→ no-op
        }
        let targetRoot = defaultGroupRoot.appendingPathComponent(
            "sessions", isDirectory: true)
        for item in items where item.pathExtension == "jsonl" {
            move(item: item,
                 to: targetRoot.appendingPathComponent(item.lastPathComponent),
                 isJSONL: true,
                 report: &report)
        }
    }

    /// persistentBase 直下「UUID 形状 + 含已知 bucket 子目录至少其一」的会话
    /// 桶目录 → groups/default/<sid>/。目录名不是 UUID（config/skills/shared/
    /// mcp-servers/memory/spill/groups）一概跳过。
    private func migrateLegacyBucketDirs(_ report: inout Report) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil) else { return }
        for child in children {
            let name = child.lastPathComponent
            // 只认 UUID 形状的目录名。
            guard UUID(uuidString: name) != nil else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            // 至少含一个已知 bucket 子目录才认定为会话桶目录（防误伤
            // spill/<sid> 等 UUID 形状但非四桶的目录）。
            let isSessionBucket = GroupStore.knownBuckets.contains { bucket in
                fm.fileExists(
                    atPath: child.appendingPathComponent(bucket, isDirectory: true).path)
            }
            guard isSessionBucket else { continue }
            move(item: child,
                 to: defaultGroupRoot.appendingPathComponent(name, isDirectory: true),
                 isJSONL: false,
                 report: &report)
        }
    }

    // MARK: - 单项搬移（同卷 rename 原子语义）

    /// 同卷 rename（FileManager.moveItem 同卷=原子 rename）：
    ///   · 目标已存在 = 已迁移（幂等）→ 跳过，源原样保留；
    ///   · 失败 → 记日志继续其余，绝不删除源（源在即数据在）。
    private func move(item: URL, to target: URL, isJSONL: Bool,
                      report: inout Report) {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            report.skippedConflicts += 1
            Self.logger.warning("group migration: target exists, skip "
                + "\(item.lastPathComponent)")
            return
        }
        do {
            try fm.moveItem(at: item, to: target)
            if isJSONL { report.movedJSONLFiles += 1 } else { report.movedBucketDirs += 1 }
        } catch {
            report.failedItems += 1
            Self.logger.error("group migration: move \(item.lastPathComponent) "
                + "failed: \(String(describing: error))——源保留，下次启动重试")
        }
    }
}
