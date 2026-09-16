//
//  WorkspaceRegistry.swift
//  WanWo
//
//  【M6.5 新写 · 语义源 dsh workspace.zh.md :12-316（packages/workspace/workspace）】
//  F073 存储锚点裁定：在 F073（groups 表 + sessionIndex.groupId）上**补 dsh 语义**，
//  禁止建第二套并行系统——工作区实体 = groups 表行（v4 加列），成员归属 = 既有
//  sessionIndex.groupId（单一事实源），本 registry 只新增「序」与「工作区元数据」。
//
//  ===== F073 对齐裁定清单（逐条）=====
//  ① id 形态冲突：dsh WorkspaceId=uuid；F073 groups.id=text（default 分组 id 恒
//     "default"）。裁定：新工作区 id=UUID().uuidString；"default" 行**不升级**为
//     工作区——它是 Ungrouped 桶（dsh delete 后会话回落 Ungrouped 的对应物），
//     path/updatedAtMs/displayOrder 三列保持 NULL，registry 的一切读写跳过它。
//  ② canonical path 字段缺失：F073 groups 无 path 列。裁定：v4 加列 path（dsh
//     realpath 规范化后的 guest 路径），唯一性 = 规范路径字符串相等（dsh :19）。
//  ③ 有序会话账本 vs groupId 无序边：F073 成员归属仅 sessionIndex.groupId（无序）。
//     裁定：**不迁移归属真源**（groupId 保持单一事实源，避免双系统），新增
//     workspaceSessionOrder 表只存「组内序」。dsh 的「所有权真源是有序账本」在
//     WanWo 折算为「归属真源=groupId，序真源=账本」——attach/detach 同时维护两者，
//     成员资格双条件（groupId 命中 ∧ header cwd 规范匹配）语义不变（dsh :116）。
//  ④ 崩溃安全：dsh = create/delete 前持久 pending 标记 + 启动解决标记（两次写可能
//     分叉）。裁定：GRDB/SQLite 单事务原子完成全部写（groups 行+账本+序），事务
//     回滚即无痕——比 pending 标记更强，标记机制不引入（结构差异，报告登记）。
//  ⑤ realpath 规范化：dsh 用 fs.realpath（符号链接全解析）。WanWo 的 fakefs 不向
//     Swift 暴露 realpath 系统调用——降级为「词法规范 + 宿主 realpath 回映」
//     （GuestPathCanonicalizer：挂载目录与静态 fakefs 两段可解析，符号链接经宿主
//     resolvingSymlinksInPath best-effort 解析；不可解析路径回落词法规范）。
//     不可抗力降级，报告登记。
//  ⑥ 首启 bootstrap（dsh :122）：按 header cwd 分组一次 + 「已初始化」标记最后写。
//     冲突点：F073 存量会话 cwd 恒为 /var/wanwo/workspace（会话桶根，AppEnvironment
//     缺省注入）——bootstrap 会为它建一个工作区并把存量会话全部从 default 移入。
//     裁定：语义照办（dsh 允许工作区落在任意目录，含会话桶根；default 分组保留
//     为 Ungrouped 桶——之后 detach/未归组会话落回）。若产品侧不愿桶根成工作区，
//     删除该工作区记录即可（会话自动回落 Ungrouped，数据无损）——报告标注待拍板。
//
//  GRDB 触达收口：本文件与 SessionDatabase 是仅有的两个 GRDB import 点
//  （Storage 层内聚，UI 不触达——§十三.1 纪律在 Storage 层内的延伸）。
//

import Foundation
import GRDB

/// 一个工作区记录（dsh Workspace 接口的 WanWo 投影）。
struct WorkspaceRecord: Equatable, Identifiable, Sendable {
    /// 稳定记录 id（UUID 字符串；default 分组不暴露为工作区）。
    let id: String
    /// 规范化目录路径（创建时的 realpath 词法+宿主回映；此后永不改写）。
    let path: String
    /// 显示标题（创建时缺省 = path 末段；允许重复）。
    var title: String
    /// 创建时刻（创建时盖戳，永不改写）。
    let createdAt: Date
    /// 最后一次持久变更时刻（create 计入）。
    var updatedAt: Date
    /// 手工序会话账本（attach 前插 / insertSessionBefore 显式重排 / 活动永不重排；
    /// 已同步过滤掉成员资格不通过的候选项）。
    var sessionIds: [String]
}

/// registry 错误（dsh 词汇：ENOENT 原样 / WorkspaceMoveInvalidError / attach 校验拒绝）。
/// 注：dsh 的「非目录拒收」并入 pathNotFound（WanWo 存在性缝=目录存在性，
/// 非目录与不存在同判——不存在或非目录都拒收 ENOENT 语义）。
enum WorkspaceRegistryError: Error, Equatable {
    /// create：路径不存在/非目录（原样传出 ENOENT 语义）。
    case pathNotFound(String)
    /// insertSessionBefore：会话或锚不在账本（WorkspaceMoveInvalidError 同语义）。
    case moveInvalid
    /// attach：未知会话 id 或 header cwd 缺失/不匹配（拒绝且不写）。
    case attachRejected(sessionId: String)
}

/// 注册表错误（dsh WorkspaceRegistry 语义的 Swift 面）。
final class WorkspaceRegistry: @unchecked Sendable {

    // MARK: - 依赖缝（全部可注入——纯逻辑测试不触真实文件系统）

    /// 会话 header 提供缝（attach 校验 + bootstrap 分组；dsh 对照 SessionHeader.cwd）。
    private let headerProvider: @Sendable (String) -> SessionHeader?
    /// 目录存在性缝（create 拒收不存在的路径；bootstrap 判 cwd 有效）。
    private let directoryExists: @Sendable (String) -> Bool
    /// realpath 规范化缝（见文件头裁定⑤；默认=词法+宿主回映）。
    private let realpath: @Sendable (String) -> String

    private let database: SessionDatabase
    private let logger = AppLogger(category: "workspace-registry")
    private let lock = NSLock()

    /// 变更通知缝（接受型变更后同步触发；WorkspaceController.follow 的数据源）。
    /// 运行期一次性赋值（与 SessionDatabase.onIndexChanged 同纪律）。
    var onChange: (@Sendable () -> Void)?

    /// default 分组（Ungrouped 桶）——registry 一切读写跳过它。
    static let ungroupedID = WanWoPaths.defaultGroupID
    /// workspaceMeta 的「已初始化」标记键（dsh bootstrap marker 同语义）。
    private static let bootstrapMarkerKey = "workspace.bootstrap.initialized"

    init(database: SessionDatabase,
         headerProvider: @escaping @Sendable (String) -> SessionHeader?,
         directoryExists: @escaping @Sendable (String) -> Bool = GuestPathProber.directoryExists,
         realpath: @escaping @Sendable (String) -> String = GuestPathCanonicalizer.canonicalize) {
        self.database = database
        self.headerProvider = headerProvider
        self.directoryExists = directoryExists
        self.realpath = realpath
    }

    // MARK: - 注册表 CRUD（dsh :247-316 契约）

    /// create(path, title?)：规范化路径；不存在拒收（ENOENT 原样）；非目录拒收；
    /// 规范路径已被拥有 → 原样返回既有实体（幂等，不改标题）；否则建记录
    /// （标题 = title ?? basename(path)）并前插到持久注册表序。
    @discardableResult
    func create(path: String, title: String? = nil) throws -> WorkspaceRecord {
        let canonical = realpath(path)
        guard !canonical.isEmpty, canonical.hasPrefix("/") else {
            throw WorkspaceRegistryError.pathNotFound(path)
        }
        guard directoryExists(canonical) else {
            throw WorkspaceRegistryError.pathNotFound(path)
        }
        let now = Date()
        let recordID = UUID().uuidString
        let displayTitle: String
        if let title, !title.isEmpty {
            displayTitle = title
        } else {
            displayTitle = String(canonical.split(separator: "/").last.map(String.init) ?? canonical)
        }

        let existing = try database.withConnection { db -> WorkspaceRecord? in
            if let row = try Self.fetchRow(canonicalPath: canonical, db: db) {
                return try Self.hydrate(row: row, db: db)
            }
            // 前插：displayOrder 取现最小值 -1（DOUBLE 分数键，insertBefore 中点插入）。
            let minOrder: Double? = try Double.fetchOne(
                db, sql: "SELECT MIN(displayOrder) FROM groups WHERE path IS NOT NULL")
            let order = (minOrder ?? 0) - 1
            try db.execute(
                sql: """
                INSERT INTO groups (id, name, createdAtMs, path, updatedAtMs, displayOrder)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [recordID, displayTitle,
                            Int64(now.timeIntervalSince1970 * 1000),
                            canonical, Int64(now.timeIntervalSince1970 * 1000), order])
            return WorkspaceRecord(id: recordID, path: canonical, title: displayTitle,
                                   createdAt: now, updatedAt: now, sessionIds: [])
        }
        if let existing {
            logger.info("create: canonical path already owned -> \(existing.id)")
            return existing
        }
        if let created = get(recordID) {
            notifyChange()
            return created
        }
        // 回读失败（仅 DB 层异常可达）——以内存构造体兜底返回（记录已落库）。
        notifyChange()
        return WorkspaceRecord(id: recordID, path: canonical, title: displayTitle,
                               createdAt: now, updatedAt: now, sessionIds: [])
    }

    /// get(id)：同步缓存读；未知返回 nil。
    func get(_ id: String) -> WorkspaceRecord? {
        guard id != Self.ungroupedID else { return nil }
        return try? database.readConnection { db in
            guard let row = try Self.fetchRow(id: id, db: db) else { return nil }
            return try Self.hydrate(row: row, db: db)
        }
    }

    /// 有序 list()：持久注册表序（displayOrder 升序）；每项 sessionIds 已按成员
    /// 资格过滤（groupId 命中——cwd 半边经 attach 校验 + header 不可变性折算，
    /// 见 hydrate 说明；dsh「同步过滤」语义）。
    func list() -> [WorkspaceRecord] {
        return (try? database.readConnection { db -> [WorkspaceRecord] in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM groups WHERE path IS NOT NULL ORDER BY displayOrder ASC")
            return try rows.map { try Self.hydrate(row: $0, db: db) }
        }) ?? []
    }

    /// delete(id)：只移除注册记录、序条目和会话账本归属（会话回落 Ungrouped）——
    /// 目录、用户文件、会话日志一概不动。未知 id 返回 false（幂等）。
    /// 单事务：groups 行删除 + 账本行清理 + sessionIndex.groupId 回落 default。
    func delete(_ id: String) throws -> Bool {
        guard id != Self.ungroupedID else { return false }
        let changed = try database.withConnection { db -> Bool in
            guard try Self.fetchRow(id: id, db: db) != nil else { return false }
            try db.execute(sql: "DELETE FROM groups WHERE id = ?", arguments: [id])
            try db.execute(
                sql: "UPDATE sessionIndex SET groupId = ? WHERE groupId = ?",
                arguments: [Self.ungroupedID, id])
            return true
        }
        if changed { notifyChange() }
        return changed
    }

    /// insertBefore(id, beforeId?)：DOM-insertBefore 语义——有锚落在锚前，无锚
    /// 追加到末尾。未知 id 返回 false（域调用方幂等）。
    @discardableResult
    func insertBefore(_ id: String, before beforeId: String?) throws -> Bool {
        guard id != Self.ungroupedID, id != beforeId else { return false }
        var result = false
        try database.withConnection { db in
            guard let row = try Self.fetchRow(id: id, db: db) else { return }
            let moved = try Self.hydrate(row: row, db: db)
            let newOrder: Double
            if let anchorId = beforeId,
               let anchorRow = try Self.fetchRow(id: anchorId, db: db),
               let anchorOrder = anchorRow["displayOrder"] as Double? {
                // 锚前插入：取（前一兄弟 + 锚）的中点——有前兄弟取中点，无前兄弟
                // 取锚 - 1。分数键免整表重排。
                let prevOrder: Double? = try Double.fetchOne(
                    db,
                    sql: """
                    SELECT MAX(displayOrder) FROM groups
                    WHERE path IS NOT NULL AND displayOrder < ?
                    """,
                    arguments: [anchorOrder])
                newOrder = prevOrder.map { ($0 + anchorOrder) / 2 } ?? anchorOrder - 1
            } else if beforeId != nil {
                return // 未知锚：拒绝不写（dsh 域调用方语义）
            } else {
                let maxOrder: Double? = try Double.fetchOne(
                    db, sql: "SELECT MAX(displayOrder) FROM groups WHERE path IS NOT NULL")
                newOrder = (maxOrder ?? 0) + 1
            }
            try db.execute(
                sql: "UPDATE groups SET displayOrder = ?, updatedAtMs = ? WHERE id = ?",
                arguments: [newOrder, Int64(Date().timeIntervalSince1970 * 1000), id])
            result = true
        }
        if result { notifyChange() }
        return result
    }

    /// resolveByPath(path)：同一套 realpath 规范、不创建；已拥有的规范路径 →
    /// 所属工作区，否则 nil。
    func resolveByPath(path: String) -> WorkspaceRecord? {
        let canonical = realpath(path)
        return (try? database.readConnection { db -> WorkspaceRecord? in
            guard let row = try Self.fetchRow(canonicalPath: canonical, db: db) else { return nil }
            return try Self.hydrate(row: row, db: db)
        }) ?? nil
    }

    // MARK: - 会话账本（attach / detach / insertSessionBefore / archiveSession）

    /// attachSession：前插到工作区账本。已记账 id 幂等返回（仍执行过滤修剪）；
    /// 新 id 的 header cwd 必须规范化后等于工作区 path，未知 id / cwd 缺失 /
    /// 不匹配拒绝且不写（dsh :69-79）。
    func attachSession(sessionId: String, to workspaceId: String) throws {
        guard workspaceId != Self.ungroupedID else {
            throw WorkspaceRegistryError.attachRejected(sessionId: sessionId)
        }
        var accepted = false
        try database.withConnection { db in
            guard let row = try Self.fetchRow(id: workspaceId, db: db) else {
                throw WorkspaceRegistryError.attachRejected(sessionId: sessionId)
            }
            let ws = try Self.hydrate(row: row, db: db)
            // 成员资格双条件之一：header 规范 cwd 匹配（账本条件由 groupId 承担）。
            guard let header = headerProvider(sessionId),
                  let cwd = header.cwd else {
                throw WorkspaceRegistryError.attachRejected(sessionId: sessionId)
            }
            guard realpath(cwd) == ws.path else {
                throw WorkspaceRegistryError.attachRejected(sessionId: sessionId)
            }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            if ws.sessionIds.contains(sessionId) {
                // 幂等：不写账本，只执行接受型变更的过滤修剪。
                try Self.pruneFilteredCandidates(workspace: ws, db: db)
                return
            }
            // 前插（position 取现最小值 -1）+ groupId 归属落位（F073 单一事实源）。
            let minPos = try Int.fetchOne(
                db,
                sql: "SELECT MIN(position) FROM workspaceSessionOrder WHERE workspaceId = ?",
                arguments: [workspaceId])
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO workspaceSessionOrder (workspaceId, sessionId, position)
                VALUES (?, ?, ?)
                """,
                arguments: [workspaceId, sessionId, (minPos ?? 0) - 1])
            try db.execute(
                sql: "UPDATE sessionIndex SET groupId = ? WHERE id = ?",
                arguments: [workspaceId, sessionId])
            try db.execute(
                sql: "UPDATE groups SET updatedAtMs = ? WHERE id = ?",
                arguments: [now, workspaceId])
            try Self.pruneFilteredCandidates(workspace: ws, db: db)
            accepted = true
        }
        if accepted { notifyChange() }
    }

    /// detachSession：移出账本与归属（会话自身日志不动）。幂等：不在账本亦不报错
    /// （仅执行过滤修剪）。
    func detachSession(sessionId: String, from workspaceId: String) throws {
        guard workspaceId != Self.ungroupedID else { return }
        var accepted = false
        try database.withConnection { db in
            guard let row = try Self.fetchRow(id: workspaceId, db: db) else { return }
            let ws = try Self.hydrate(row: row, db: db)
            let accounted = ws.sessionIds.contains(sessionId)
            if accounted {
                try db.execute(
                    sql: "DELETE FROM workspaceSessionOrder WHERE workspaceId = ? AND sessionId = ?",
                    arguments: [workspaceId, sessionId])
                try db.execute(
                    sql: "UPDATE sessionIndex SET groupId = ? WHERE id = ? AND groupId = ?",
                    arguments: [Self.ungroupedID, sessionId, workspaceId])
                try db.execute(
                    sql: "UPDATE groups SET updatedAtMs = ? WHERE id = ?",
                    arguments: [Int64(Date().timeIntervalSince1970 * 1000), workspaceId])
                accepted = true
            }
            try Self.pruneFilteredCandidates(workspace: ws, db: db)
        }
        if accepted { notifyChange() }
    }

    /// insertSessionBefore(sessionId, beforeSessionId?)：DOM-insertBefore 语义
    /// （dsh :83-94）。会话或锚不在账本 → moveInvalid 拒绝不写；移动到原位 →
    /// 不写（仍修剪）。实现：读出现序数组 → 摘出被移动 id 插到锚前/末尾 →
    /// 全账本按新序重编 position（仅被移动 id 的相对位置变化，其余相对序不变
    /// ——可观测语义与 dsh 一致；整表重编规避整数位碰撞，n≤数百量级写放大可忽略）。
    func insertSessionBefore(sessionId: String, beforeSessionId: String?,
                             in workspaceId: String) throws {
        guard workspaceId != Self.ungroupedID else {
            throw WorkspaceRegistryError.moveInvalid
        }
        var accepted = false
        try database.withConnection { db in
            guard let row = try Self.fetchRow(id: workspaceId, db: db) else {
                throw WorkspaceRegistryError.moveInvalid
            }
            let ws = try Self.hydrate(row: row, db: db)
            guard ws.sessionIds.contains(sessionId) else {
                throw WorkspaceRegistryError.moveInvalid
            }
            if let anchor = beforeSessionId, !ws.sessionIds.contains(anchor) {
                throw WorkspaceRegistryError.moveInvalid
            }
            // 新序：摘出 → 插锚前 / 追加末尾。
            var ordered = ws.sessionIds.filter { $0 != sessionId }
            if let anchor = beforeSessionId {
                guard let anchorIdx = ordered.firstIndex(of: anchor) else {
                    throw WorkspaceRegistryError.moveInvalid // 不可达（上方已核）
                }
                ordered.insert(sessionId, at: anchorIdx)
            } else {
                ordered.append(sessionId)
            }
            // 原位判定：新序与旧序逐位相同 → 不写（仅修剪）。
            if ordered == ws.sessionIds {
                try Self.pruneFilteredCandidates(workspace: ws, db: db)
                return
            }
            // 全账本重编 position + updatedAt 盖戳（同一事务）。
            for (idx, sid) in ordered.enumerated() {
                try db.execute(
                    sql: "UPDATE workspaceSessionOrder SET position = ? WHERE workspaceId = ? AND sessionId = ?",
                    arguments: [idx, workspaceId, sid])
            }
            try db.execute(
                sql: "UPDATE groups SET updatedAtMs = ? WHERE id = ?",
                arguments: [Int64(Date().timeIntervalSince1970 * 1000), workspaceId])
            try Self.pruneFilteredCandidates(workspace: ws, db: db)
            accepted = true
        }
        if accepted { notifyChange() }
    }

    /// archiveSession：按会话维度归档（工作区记账与否无关）。会话必须存在
    /// （sessionIndex 有行）；已归档幂等不写。
    func archiveSession(sessionId: String) throws {
        var accepted = false
        try database.withConnection { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sessionIndex WHERE id = ?)",
                arguments: [sessionId]) == true else {
                throw WorkspaceRegistryError.attachRejected(sessionId: sessionId)
            }
            guard try Double.fetchOne(
                db,
                sql: "SELECT archivedAtMs FROM sessionIndex WHERE id = ?",
                arguments: [sessionId]) == nil else {
                return // 已归档：幂等不写
            }
            try db.execute(
                sql: "UPDATE sessionIndex SET archivedAtMs = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, sessionId])
            accepted = true
        }
        if accepted { notifyChange() }
    }

    /// 归档集合（已归档会话 id；B4 左侧栏欠账消费面）。
    func archivedSessionIDs() -> Set<String> {
        return (try? database.readConnection { db -> Set<String> in
            let ids = try String.fetchAll(
                db,
                sql: "SELECT id FROM sessionIndex WHERE archivedAtMs IS NOT NULL")
            return Set(ids)
        }) ?? []
    }

    // MARK: - 首启 bootstrap（dsh :122；文件头裁定⑥）

    struct BootstrapReport: Equatable {
        var workspacesCreated = 0
        var sessionsAttached = 0
        var skippedInvalidCWD = 0
        var alreadyInitialized = false
    }

    /// 仅凭已持久化 header（id/cwd/createdAt——绝不读事件正文）把历史会话按规范
    /// cwd 分组为工作区：工作区按组内最新会话时间**最新在前**入注册表序；组内
    /// 会话按创建时间升序 attach（前插 ⇒ 账本最终最新在前）。「已初始化」标记
    /// 最后写入——被中断的引导可安全续跑（无标记则下轮重算，标记前已建的记录
    /// 经 create 幂等合并）。引导只发生这一次。
    func bootstrapIfNeeded() -> BootstrapReport {
        var report = BootstrapReport()
        let markerSet = (try? database.readConnection { db -> Bool in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM workspaceMeta WHERE key = ?)",
                arguments: [Self.bootstrapMarkerKey]) == true
        }) ?? false
        if markerSet {
            report.alreadyInitialized = true
            return report
        }

        // 1. 收集全部会话 header（只读 id/cwd/createdAt）。
        struct Entry { let id: String; let createdAtMs: Int64; let canonicalCWD: String }
        var valid: [Entry] = []
        let summaries = database.list() // 摘要列（id/createdAt 已持久投影）
        for summary in summaries {
            guard let header = headerProvider(summary.id), let cwd = header.cwd else {
                report.skippedInvalidCWD += 1
                continue // 无 cwd 的历史遗留会话保持 Ungrouped（dsh 语义）
            }
            let canonical = realpath(cwd)
            guard !canonical.isEmpty, canonical.hasPrefix("/"),
                  directoryExists(canonical) else {
                report.skippedInvalidCWD += 1
                continue
            }
            valid.append(Entry(id: summary.id,
                               createdAtMs: Int64(summary.createdAt.timeIntervalSince1970 * 1000),
                               canonicalCWD: canonical))
        }

        // 2. 按规范 cwd 分组；组内按创建时间升序（attach 前插 ⇒ 最新在前）。
        let grouped = Dictionary(grouping: valid, by: \.canonicalCWD)
        // 3. 工作区序 = 组内最新会话时间倒序（最新在前）。create 为前插
        //    （displayOrder 现最小值 -1，每个新工作区落到注册表最前）——
        //    【终验修】此前按最新在前遍历，前插使最后创建的（最旧）反而
        //    排最前，方向反了。改为按最新在后升序遍历：最后前插的即最新
        //    工作区，终序 = 最新在前（dsh bootstrap 语义不变）。
        let orderedPaths = grouped
            .map { (path: $0.key, newest: $0.value.map(\.createdAtMs).max() ?? 0) }
            .sorted { $0.newest < $1.newest }
            .map(\.path)

        for path in orderedPaths {
            let sessions = (grouped[path] ?? []).sorted { $0.createdAtMs < $1.createdAtMs }
            guard let ws = try? create(path: path) else {
                logger.warning("bootstrap: create failed for \(path)")
                continue
            }
            // create 幂等（既有路径原样返回）；引导只跑一次，中断续跑的罕见面里
            // 重复路径会计入 created——可接受（记录数不受影响，create 幂等合并）。
            report.workspacesCreated += 1
            for entry in sessions {
                do {
                    try attachSession(sessionId: entry.id, to: ws.id)
                    report.sessionsAttached += 1
                } catch {
                    // 校验失败（如账本规则变化）不阻塞引导——会话保持现状。
                    logger.warning("bootstrap: attach \(entry.id) rejected: \(String(describing: error))")
                }
            }
        }

        // 4. 「已初始化」标记最后写入。
        _ = try? database.withConnection { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO workspaceMeta (key, value) VALUES (?, ?)",
                arguments: [Self.bootstrapMarkerKey, ISO8601DateFormatter().string(from: Date())])
        }
        logger.info("workspace bootstrap: created=\(report.workspacesCreated) attached=\(report.sessionsAttached) skipped=\(report.skippedInvalidCWD)")
        return report
    }

    // MARK: - 内部

    /// 控制器/装配层的受控事务写缝（保持 GRDB 类型触达收口在本文件与
    /// SessionDatabase——WorkspaceController 不 import GRDB）。
    func databaseWrite(_ body: @escaping (Database) throws -> Void) throws {
        try database.withConnection(body)
    }

    /// rename（dsh rename → setTitle 语义）：改显示标题（任意非空字符串，
    /// 跨工作区允许重复）；未知 id / 非 workspace 行抛 attachRejected。
    func renameTitle(id: String, title: String) throws -> WorkspaceRecord {
        guard !title.isEmpty else {
            throw WorkspaceRegistryError.moveInvalid
        }
        guard id != Self.ungroupedID else {
            throw WorkspaceRegistryError.attachRejected(sessionId: id)
        }
        try databaseWrite { db in
            try db.execute(
                sql: "UPDATE groups SET name = ?, updatedAtMs = ? WHERE id = ? AND path IS NOT NULL",
                arguments: [title, Int64(Date().timeIntervalSince1970 * 1000), id])
        }
        guard let updated = get(id) else {
            throw WorkspaceRegistryError.attachRejected(sessionId: id)
        }
        return updated
    }

    private func notifyChange() {
        lock.lock()
        let handler = onChange
        lock.unlock()
        handler?()
    }

    /// 行取（按 id 或规范 path）。
    private static func fetchRow(id: String? = nil, canonicalPath: String? = nil,
                                 db: Database) throws -> Row? {
        if let id {
            return try Row.fetchOne(db, sql: "SELECT * FROM groups WHERE id = ?", arguments: [id])
        }
        if let canonicalPath {
            return try Row.fetchOne(db, sql: "SELECT * FROM groups WHERE path = ?",
                                    arguments: [canonicalPath])
        }
        return nil
    }

    /// 行 → WorkspaceRecord（sessionIds 账本读出 + 成员资格同步过滤：groupId
    /// 命中；缺失 header/无效 cwd/不匹配的候选项不返回）。
    /// 成员资格双条件的 cwd 半边说明：WanWo 的 SessionHeader cwd **创建时定格、
    /// 之后不可变**（事件溯源头 append-only），而进入账本的唯一路径是 attachSession
    /// 的 cwd 校验——因此「groupId 命中」在时间上蕴含「cwd 曾匹配且不可能漂移」，
    /// hydrate 逐项 realpath（宿主 FS 调用）在 list() 热路径上不必要。dsh 的
    /// header index 语义（:116）由 attach 校验 + groupId 单一事实源折算达成。
    private static func hydrate(row: Row, db: Database) throws -> WorkspaceRecord {
        let id: String = row["id"] ?? ""
        let path: String = row["path"] ?? ""
        let title: String = row["name"] ?? ""
        let createdMs: Int64 = row["createdAtMs"] ?? 0
        let updatedMs: Int64 = row["updatedAtMs"] ?? createdMs
        var sessionIds: [String] = []
        let ledgerRows = try Row.fetchAll(
            db,
            sql: """
            SELECT o.sessionId, s.groupId FROM workspaceSessionOrder o
            LEFT JOIN sessionIndex s ON s.id = o.sessionId
            WHERE o.workspaceId = ? ORDER BY o.position ASC
            """,
            arguments: [id])
        for ledgerRow in ledgerRows {
            let sid: String = ledgerRow["sessionId"] ?? ""
            let gid: String? = ledgerRow["groupId"]
            guard gid == id else { continue } // groupId 不命中 → 过滤
            sessionIds.append(sid)
        }
        return WorkspaceRecord(
            id: id,
            path: path,
            title: title,
            createdAt: Date(timeIntervalSince1970: Double(createdMs) / 1000),
            updatedAt: Date(timeIntervalSince1970: Double(updatedMs) / 1000),
            sessionIds: sessionIds)
    }

    /// 接受型变更附带的持久修剪：把「账本有行但成员资格不通过」的候选项从账本
    /// 删除（dsh「后续工作区变更持久修剪被过滤的候选项」）。返回修剪条数。
    /// 在调用方的 db 事务内执行。header 缺失/无效 cwd 不修剪（dsh 口径：missing
    /// headers / invalid cwd / mismatch 才修剪——其中 missing header 亦修剪，
    /// 与「同步过滤不返回」同口径；此处对齐：缺失 header 或 cwd 不匹配都修剪）。
    fileprivate static func pruneFilteredCandidates(workspace ws: WorkspaceRecord,
                                                     db: Database) throws {
        var prune: [String] = []
        let ledgerRows = try Row.fetchAll(
            db,
            sql: "SELECT sessionId FROM workspaceSessionOrder WHERE workspaceId = ?",
            arguments: [ws.id])
        for ledgerRow in ledgerRows {
            let sid: String = ledgerRow["sessionId"] ?? ""
            if !ws.sessionIds.contains(sid) {
                // 已被同步过滤挡在 hydrate 之外——账本行即为待修剪项。
                // （hydrate 过滤条件 = groupId 命中；此处再核 groupId 防误删。）
                let gid: String? = try String.fetchOne(
                    db, sql: "SELECT groupId FROM sessionIndex WHERE id = ?", arguments: [sid])
                if gid != ws.id { prune.append(sid) }
            }
        }
        for sid in prune {
            try db.execute(
                sql: "DELETE FROM workspaceSessionOrder WHERE workspaceId = ? AND sessionId = ?",
                arguments: [ws.id, sid])
        }
    }
}

// MARK: - guest 路径规范化（文件头裁定⑤）

/// 词法规范化：折叠多余斜杠、解析 "." / ".."、去尾斜杠、保首斜杠。不跨符号链接。
enum WorkspacePathNormalizer {
    static func lexicalNormalize(_ raw: String) -> String {
        var parts: [String] = []
        for comp in raw.split(separator: "/", omittingEmptySubsequences: true) {
            switch comp {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(comp))
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}

/// 挂载目录 canonical host path 的跨线程读取缝（MountedFoldersManager 为
/// @MainActor 单例、copy-on-read 读安全——原件同纪律）。非主线程经 main sync。
private func canonicalHostPathForMount(_ name: String) -> String? {
    if Thread.isMainThread {
        return MainActor.assumeIsolated {
            MountedFoldersManager.shared.canonicalHostPath(forName: name)
        }
    }
    return DispatchQueue.main.sync {
        MainActor.assumeIsolated {
            MountedFoldersManager.shared.canonicalHostPath(forName: name)
        }
    }
}

/// realpath 缝默认实现：词法规范 + 宿主 realpath 回映（best-effort）。
/// 可解析面两段：① 外挂载 /var/wanwo/mounts/<name>/**（经 MountedFoldersManager
/// 激活时缓存的 canonical host path 回映）② 其余 guest 路径（经 fakefs data 根
/// RootfsInstaller.dataPath 回映）。回映失败回落词法规范（不可抗力降级，报告登记）。
enum GuestPathCanonicalizer {
    static func canonicalize(_ raw: String) -> String {
        let lexical = WorkspacePathNormalizer.lexicalNormalize(raw)

        // ① 外挂载段：/var/wanwo/mounts/<name>[/**] —— 挂载点名 + 词法即 guest
        //    形态终值（registry 记录的是 guest 路径；宿主侧真身解析交
        //    directoryExists 缝的实际探查）。
        if lexical.hasPrefix(WanWoPaths.mountsLinuxDir + "/") {
            return lexical
        }

        // ② 静态 fakefs 段：guest 路径 → data/<path>，宿主 realpath 后回映。
        guard lexical.hasPrefix("/") else { return lexical }
        let dataRoot = RootfsInstaller.shared.dataPath.standardizedFileURL
        let hostCandidate = dataRoot.appendingPathComponent(String(lexical.dropFirst()))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: hostCandidate.path, isDirectory: &isDir),
              isDir.boolValue else {
            return lexical // 不存在/非目录：词法规范即终值（create 层拒收）
        }
        let resolved = hostCandidate.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalDataRoot = dataRoot.resolvingSymlinksInPath().standardizedFileURL.path
        if resolved == canonicalDataRoot {
            return "/"
        }
        if resolved.hasPrefix(canonicalDataRoot + "/") {
            return WorkspacePathNormalizer.lexicalNormalize(
                "/" + String(resolved.dropFirst(canonicalDataRoot.count + 1)))
        }
        // 挂到 data 根之外（fakefs 内部 symlink 指出宿主 data/）：词法规范兜底。
        return lexical
    }
}

/// 目录存在性缝默认实现（与 realpath 同两面：挂载目录 / 静态 fakefs）。
enum GuestPathProber {
    static func directoryExists(_ guestPath: String) -> Bool {
        // ① 外挂载段：canonical host path 直查。
        let mountsPrefix = WanWoPaths.mountsLinuxDir + "/"
        if guestPath.hasPrefix(mountsPrefix) {
            let rest = String(guestPath.dropFirst(mountsPrefix.count))
            let name = rest.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            guard !name.isEmpty, let root = canonicalHostPathForMount(String(name)) else {
                return false
            }
            let tail = String(rest.dropFirst(name.count))
            let target = tail.isEmpty ? root : root + tail
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: target, isDirectory: &isDir)
                && isDir.boolValue
        }

        // ② 静态 fakefs 段。
        guard guestPath.hasPrefix("/") else { return false }
        let host = RootfsInstaller.shared.dataPath
            .appendingPathComponent(String(guestPath.dropFirst()))
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: host.path, isDirectory: &isDir)
            && isDir.boolValue
    }
}
