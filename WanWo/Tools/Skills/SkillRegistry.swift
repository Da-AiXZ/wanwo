//
//  SkillRegistry.swift
//  WanWo
//
//  【M4-D 件 D2+D3 · F030 发现装载 + F034 注册表/invocation】语义移植 · dsh 契约：
//  docs/subsystems/skills.md:64-81（发现 roots/rank/缓存与失效：skills/change、
//  模型 write/edit 命中→失效）、:85（双形态+不递归+kebab-case 身份）、:87-126
//  （SkillSummary/invocation 四组合/两键缺省 true）。
//  codex 防御常量：ext/skills/src/loader/mod.rs:31-32（MAX_SKILLS_DIRS_PER_ROOT=
//  2000）、discovery.rs:17-18（MAX_SKILLS_ENTRIES_PER_ROOT=20_000）。
//
//  三根 rank 映射（简报环 4，平台等价）：project = workspace /.agents/skills
//  （宿主直读，不经 iSH fork）；user = 容器 WanWoPaths.skillsPersistentDir；
//  bundled = 容器 skills/.bundled/（BundledSkillInstaller 幂等安装位）。
//  rank 全序：project < user < bundled（dsh 六档的 WanWo 三档；简报环 4）。
//
//  关键语义判定（lead 亲验裁定）：dsh:85 明确不支持递归发现（**/SKILL.md）——
//  语义层优先取 dsh，WanWo 不递归（每根只扫直接子层两种形态）；codex 递归深度
//  常量（MAX_SCAN_DEPTH=6）不移植（不递归则无深度面）；2000/20000 上限作为
//  防御性预算移植。
//
//  失效三通道（简报环 5）：①组装期刷新（AgentLoop 每步组装前 refresh——C2
//  ToolSearchAssembly 同位模式；脏才重扫，幂等低成本）②write/edit 命中技能根
//  → 失效（dsh:81 语义；观测缝在 WorkspaceFileAccess.writeAt 宿主直读 chokepoint，
//  路径前缀判定在本类 noteHostMutation）③设置页改动（D7：SkillSettingsStore.
//  DisabledIndex.revision 进缓存键——启停/导入改动 revision 递增，所有 registry
//  实例缓存键失配重扫；启停过滤另在快照出口逐读评估，双保险）。
//
//  invocation 两键方案（lead 给两选项，本实现选 B）：D1 解析面零触碰（已 review
//  冻结），D3 侧二次读 frontmatter 原文（invocationFlags）——两键为顶层布尔
//  字面量（disable-model-invocation / user-invocable），独立小解析器足够。
//
//  登记简化：快照恒 complete（dsh 的 incomplete 是 async 并发修订面，WanWo
//  同步组装期发现无此面）；runtime register（dsh:178-188）不做（无消费方，
//  M7 后评估）；SkillSummary.provider 字段=根标识（SkillSource）承载。
//

import Foundation

// MARK: - 源根与 invocation（dsh :87-126 的 WanWo 形态）

/// 技能源根标识（dsh SkillSummary.provider 的 WanWo 形态=根标识承载；
/// rank 全序：project < user < bundled——简报环 4 三根映射）。
enum SkillSource: String, Sendable, Comparable {
    case project, user, bundled

    /// rank 全序（数值仅定序；dsh 六档 100..600 的 WanWo 三档等价压缩）。
    private var rank: Int {
        switch self {
        case .project: return 200
        case .user: return 400
        case .bundled: return 600
        }
    }

    static func < (lhs: SkillSource, rhs: SkillSource) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// invocation 四组合（dsh :94-126：两键缺省 true；`disable-model-invocation: true`
/// ⇒ modelInvocable=false，`user-invocable: false` ⇒ userInvocable=false）。
struct SkillInvocation: Equatable, Sendable {
    let modelInvocable: Bool
    let userInvocable: Bool

    /// 缺省（两键皆缺）= 双 true。
    static let `default` = SkillInvocation(modelInvocable: true, userInvocable: true)
}

/// 已发现技能摘要（dsh skills.md:96-124 SkillSummary 的 WanWo 形态）。
struct SkillSummary: Equatable, Sendable {
    let name: String
    let description: String
    /// dsh whenToUse：frontmatter 无对应键——runtime 注册面字段（简报暴露项 5），
    /// 发现面恒 nil（M4-D 无 runtime 注册消费方，字段定义保留）。
    let whenToUse: String?
    let invocation: SkillInvocation
    let source: SkillSource
    /// 技能目录绝对路径（bundle=技能目录；平铺=所在根目录）——resourceBase=
    /// directory 形态（WanWo 全本地），相对资源经 read 工具自取（渐进三级）。
    let resourceBase: String
    /// 正文文件绝对路径（D5 重读正文消费位；D2/D3 review 后 additive 扩展——
    /// bundle=目录/SKILL.md、平铺=根/<stem>.md；消除 frontmatter name≠目录名
    /// 时平铺正文不可寻的缺口，resourceBase 保留资源引导职责）。
    let bodyPath: String
}

/// 装载快照（不可变）。complete 语义：WanWo 同步组装期发现=恒 complete
/// （dsh 的 incomplete 是 async 并发修订面——登记简化）。
struct SkillSnapshot: Equatable, Sendable {
    /// 合并后按 name 字典序。
    let summaries: [SkillSummary]
    /// 逐技能扫描/解析错误（fail closed：失败技能跳过不崩发现，R5）。
    let errors: [String]
}

// MARK: - SkillRegistry

/// 技能注册表（D2 发现装载 + D3 rank 合并；会话级实例）。
/// 线程安全：NSLock 护缓存态；扫描在锁外执行（幂等，并发 refresh 各自产出
/// 等价快照，后写收敛）。
final class SkillRegistry: @unchecked Sendable {

    /// 发现根（source + 宿主 URL）。
    struct Root: Sendable {
        let source: SkillSource
        let baseURL: URL
    }

    /// 防御预算（codex discovery.rs:17-18 / loader/mod.rs:31-32；
    /// 不递归 ⇒ MAX_SCAN_DEPTH=6 无深度面，不移植）。超限截断 + error 记录。
    static let maxDirsPerRoot = 2000
    static let maxEntriesPerRoot = 20_000

    /// 扫描预算（测试缝：生产默认=codex 常量；语义不变仅可注入小值）。
    struct ScanLimits: Sendable {
        let maxDirs: Int
        let maxEntries: Int
        static let production = ScanLimits(maxDirs: SkillRegistry.maxDirsPerRoot,
                                           maxEntries: SkillRegistry.maxEntriesPerRoot)
    }

    private static let logger = AppLogger(category: "Skills")

    private let lock = NSLock()
    private let roots: [Root]
    /// D7 启停覆盖层宿主（App 级 store；nil=无覆盖层——测试/既有形态不变）。
    private let settings: SkillSettingsStore?
    /// 快照缓存（键=失效标记+覆盖层 revision；根集实例期固定）。
    private var cachedSnapshot: SkillSnapshot?
    /// 覆盖层 revision 对齐键（nil=无 settings；与 settings 版本失配即重扫）。
    private var cachedOverlayRevision: Int?
    /// 初次为脏 → 首个 refresh 即扫描。
    private var invalidated = true

    /// - Parameters:
    ///   - roots: 发现根（rank 合并按 source 全序；实例期固定）。
    ///   - settings: D7 启停覆盖层宿主（App 级注入——消费其 DisabledIndex 的
    ///     contains（出口过滤）与 currentRevision（缓存键），不触碰主线程 UI 面）。
    init(roots: [Root], settings: SkillSettingsStore? = nil) {
        self.roots = roots
        self.settings = settings
    }

    // MARK: 失效三通道

    /// 通道①组装期刷新：每步组装前调用（AgentLoop 与 ToolSearchAssembly.refresh
    /// 同位）；脏才重扫，幂等低成本。
    func refresh() {
        _ = snapshot()
    }

    /// 置脏（D2 通道③预留；D7 落位后设置页改动主走 DisabledIndex.revision
    /// 缓存键——跨实例即时生效，本入口保留为显式失效面，导入页展示重扫用）。
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        invalidated = true
    }

    /// 通道②write/edit 命中判定（dsh:81 语义）：解析后的宿主路径命中任一根
    /// 前缀（或恰为根）→ 失效。观测缝：WorkspaceFileAccess.writeAt 成功落盘后
    /// 回调（覆盖 write/edit/str_replace editor 全部变更工具——三族都汇于
    /// writeAt/mutate→writeAt 单点）。
    func noteHostMutation(_ url: URL) {
        let path = url.standardizedFileURL.path
        let hit = roots.contains { root in
            let rootPath = root.baseURL.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
        if hit {
            Self.logger.info("skill root mutated by fs write; invalidating")
            invalidate()
        }
    }

    // MARK: 快照

    /// 当前快照（缓存有效即返回缓存；脏/覆盖层 revision 失配则重扫并回填）。
    /// D7 覆盖层：出口逐读过滤已停用名（selection.rs is_skill_enabled 门同位
    /// ——目录/工具/提及三消费面同享）。设置页列表面用 snapshotIncludingDisabled。
    func snapshot(limits: ScanLimits = .production) -> SkillSnapshot {
        let overlayRevision = settings?.disabledIndex.currentRevision
        lock.lock()
        if !invalidated, cachedOverlayRevision == overlayRevision,
           let cached = cachedSnapshot {
            lock.unlock()
            return Self.filterDisabled(cached, index: settings?.disabledIndex)
        }
        lock.unlock()
        let fresh = Self.scan(roots: roots, limits: limits)
        lock.lock()
        invalidated = false
        cachedSnapshot = fresh
        cachedOverlayRevision = overlayRevision
        lock.unlock()
        return Self.filterDisabled(fresh, index: settings?.disabledIndex)
    }

    /// 含已停用的完整快照（D7 设置页列表面——覆盖层不滤，需能重新启用）。
    func snapshotIncludingDisabled(limits: ScanLimits = .production) -> SkillSnapshot {
        lock.lock()
        let cached = invalidated ? nil : cachedSnapshot
        lock.unlock()
        if let cached { return cached }
        let fresh = Self.scan(roots: roots, limits: limits)
        lock.lock()
        invalidated = false
        cachedSnapshot = fresh
        cachedOverlayRevision = settings?.disabledIndex.currentRevision
        lock.unlock()
        return fresh
    }

    /// D7 出口过滤（纯函数）：无覆盖层原样；有则剔除已停用名（errors 保留）。
    static func filterDisabled(_ snapshot: SkillSnapshot,
                               index: SkillSettingsStore.DisabledIndex?) -> SkillSnapshot {
        guard let index else { return snapshot }
        guard snapshot.summaries.contains(where: { index.contains($0.name) }) else {
            return snapshot
        }
        return SkillSnapshot(summaries: snapshot.summaries.filter { !index.contains($0.name) },
                             errors: snapshot.errors)
    }

    // MARK: 扫描（纯函数；不递归——dsh:85）

    /// 三根扫描 + rank 合并：根按 rank 升序遍历、同名先见者胜（跨根=rank 小者胜；
    /// 同根=扫描序确定性首见，children 按 lastPathComponent 排序）；产物按 name
    /// 字典序。
    static func scan(roots: [Root], limits: ScanLimits = .production) -> SkillSnapshot {
        var errors: [String] = []
        var byName: [String: SkillSummary] = [:]
        for root in roots.sorted(by: { $0.source < $1.source }) {
            scanRoot(root, limits: limits, into: &byName, errors: &errors)
        }
        let summaries = byName.values.sorted { $0.name < $1.name }
        return SkillSnapshot(summaries: summaries, errors: errors)
    }

    /// 单根扫描：直接子层的两种形态（`<name>/SKILL.md` bundle + `<name>.md`
    /// 平铺）；隐藏条目跳过（`.bundled` 安装位与 marker 天然不在 user 根计列）。
    private static func scanRoot(_ root: Root,
                                 limits: ScanLimits,
                                 into byName: inout [String: SkillSummary],
                                 errors: inout [String]) {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        // 根不存在 = 空技能集（非错误——workspace 可无 .agents/skills）。
        guard fileManager.fileExists(atPath: root.baseURL.path, isDirectory: &isDir),
              isDir.boolValue else { return }
        guard let children = try? fileManager.contentsOfDirectory(
            at: root.baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            errors.append("\(root.source.rawValue): failed to list \(root.baseURL.path)")
            return
        }

        var dirCount = 0
        var entryCount = 0
        // 扫描序确定性：按条目名排序（同根重名首见语义的序基础）。
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            entryCount += 1
            if entryCount > limits.maxEntries {
                errors.append("\(root.source.rawValue): entry limit \(limits.maxEntries) "
                    + "reached; scan truncated")
                return
            }
            var childIsDir: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &childIsDir) else {
                continue
            }
            if childIsDir.boolValue {
                dirCount += 1
                if dirCount > limits.maxDirs {
                    errors.append("\(root.source.rawValue): directory limit \(limits.maxDirs) "
                        + "reached; scan truncated")
                    return
                }
                // bundle 形态：<name>/SKILL.md；identity 名=目录名（kebab）。
                loadSkill(contentsAt: child.appendingPathComponent("SKILL.md"),
                          identityName: child.lastPathComponent,
                          source: root.source,
                          resourceBase: child.path,
                          into: &byName, errors: &errors)
            } else {
                // 平铺形态：<name>.md；identity 名=去扩展名（kebab）。
                let fileName = child.lastPathComponent
                guard fileName.hasSuffix(".md") else { continue }
                loadSkill(contentsAt: child,
                          identityName: String(fileName.dropLast(".md".count)),
                          source: root.source,
                          resourceBase: root.baseURL.path,
                          into: &byName, errors: &errors)
            }
        }
    }

    /// 逐技能装载：kebab 校验（发现面，skills.md:85）→ 读 SKILL.md → D1 解析
    /// （defaultName 回退=目录/文件名，D1 的 default_name 闭包在此消费）→
    /// invocation 两键二次读 → Summary（同名先见者胜=插入防覆盖）。
    private static func loadSkill(contentsAt url: URL,
                                  identityName: String,
                                  source: SkillSource,
                                  resourceBase: String,
                                  into byName: inout [String: SkillSummary],
                                  errors: inout [String]) {
        let label = "\(source.rawValue)/\(identityName)"
        guard isKebabCase(identityName) else {
            errors.append("\(label): skill name must match " +
                          "^[a-z0-9]+(?:-[a-z0-9]+)*$ (kebab-case, skills.md:85)")
            return
        }
        // bundle 目录无 SKILL.md = 非技能（dsh:85"目录含 SKILL.md 才是技能"直读）
        // → 静默跳过（skills 根内的 assets/references 等伴生目录不刷错误）。
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            errors.append("\(label): failed to read SKILL.md")
            return
        }
        do {
            let parsed = try SkillParser.parseSkillFrontmatterMetadata(contents) {
                // 缺省回退 = 目录/文件名（codex default_name 闭包的发现面消费位）
                identityName
            }
            let summary = SkillSummary(
                name: parsed.name,
                description: parsed.description,
                whenToUse: nil,
                invocation: invocationFlags(fromFrontmatter: contents),
                source: source,
                resourceBase: resourceBase,
                bodyPath: url.path)
            // 同名先见者胜（跨根=rank 小者胜、同根=扫描序首见——scan 的遍历序承载）。
            if byName[summary.name] == nil {
                byName[summary.name] = summary
            }
        } catch {
            errors.append("\(label): \(error)")
        }
    }

    // MARK: kebab-case 契约（skills.md:85；D1 明确不加、D2 发现面承接）

    /// `^[a-z0-9]+(?:-[a-z0-9]+)*$` 逐字。
    static func isKebabCase(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$",
                   options: .regularExpression) != nil
    }

    // MARK: invocation 两键（dsh :94-126；方案 B 二次读，见文件头）

    /// 从 frontmatter 原文提取 invocation 组合：顶层键 `disable-model-invocation` /
    /// `user-invocable`（缩进 0 才有效；嵌套/续行忽略）。缺省双 true；布尔字面量
    /// 之外的值（含引号包裹）按缺省处理（登记：无效值不报错不失败，宽解析）。
    static func invocationFlags(fromFrontmatter contents: String) -> SkillInvocation {
        guard let frontmatter = SkillParser.extractFrontmatter(contents) else {
            return .default
        }
        var disableModel = false
        var userInvocable = true
        for line in frontmatter.components(separatedBy: "\n") {
            // 顶层键：首字符非空白（缩进 0）；空行/续行跳过。
            guard let first = line.first, !(first == " " || first == "\t") else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "disable-model-invocation":
                disableModel = parseYAMLBool(value) ?? false
            case "user-invocable":
                userInvocable = parseYAMLBool(value) ?? true
            default:
                break
            }
        }
        return SkillInvocation(modelInvocable: !disableModel, userInvocable: userInvocable)
    }

    /// YAML 1.2 core 布尔字面量（serde_yaml 同族：true/True/TRUE/false/False/FALSE）；
    /// 其余一律 nil。
    static func parseYAMLBool(_ value: String) -> Bool? {
        switch value {
        case "true", "True", "TRUE": return true
        case "false", "False", "FALSE": return false
        default: return nil
        }
    }
}
