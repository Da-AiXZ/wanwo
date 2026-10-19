//
//  BuildService.swift
//  WanWo
//
//  【N6 · BuildExt 工具面】13 号设计环 N6（阶段 1 交付）：编译服务壳——
//  封装 vendored NXBuilder/NXProject 全链（N5 真机已实证），供 AgentTool
//  族（BuildTools）调用。
//
//  工作区语义（10-design §三拍板）：工程源码目录置于会话工作区桶
//  BuildProjects/<name>/ 下——AI 用 fs 工具族（F014）直接读写源码，
//  NXBuilder 从同一物理路径构建（零拷贝同仓）；编译缓存/中间产物在
//  NXBootstrap rootURL 的 Cache/<name>（对 Builder 生命周期可见，不做
//  会话结束清理——N6 验收补案 3）。
//
//  阶段 2 零返工接口预留（N6 验收补案 1/2）：
//    · BuildResult 从第一天含 bundleURL（未打包 .app）/machoURL/ipaURL/
//      buildLog/projectURL——N7 签名取 bundleURL、N9 取 bundleURL 树、
//      交付取 ipaURL，全部只读不新增参数；
//    · 后置 phase 挂点（sign/install/spawn 三槽位）为空实现在位——
//      WANWO_BUILD_RUN 门控已由 N5 预留，阶段 2 开宏即插即用。
//

import Foundation

// MARK: - BuildResult（阶段 2 零返工接口，N6 验收补案 1）

struct BuildResult: Sendable {
    let success: Bool
    let projectName: String
    let projectURL: URL
    /// 未打包 .app bundle（N7 签名 / N9 guest 承载的取用点）。
    let bundleURL: URL
    /// 主可执行 MachO。
    let machoURL: URL
    /// 交付快照（Payload zip）。
    let ipaURL: URL
    /// 结构化诊断落盘（debug.json；BuildPanelView/build_log 数据源）。
    let buildLogPath: String
    /// 诊断摘要（Internal 桶最近条目——工具输出直给 AI 自修复）。
    let diagnosticsSummary: String
    /// 【N7c】签名编排结果注记（sign=true 时：nil=未请求签名；成功=「签名完成」；
    /// 失败=失败原因——构建本体成功、签名独立报告，AI 可重试签名）。
    let signNote: String?
    let elapsedSeconds: Double
}

// MARK: - BuildService

final class BuildService: @unchecked Sendable {

    static let shared = BuildService()

    /// 诊断级别显示名（压测建议 2：内部枚举 rawValue 不直接喷给用户）。
    static let levelNames: [Int: String] = [3: "error", 2: "warning", 1: "remark", 0: "note"]

    /// 单飞行门（官方 NXBuilder.builds 同语义：并发构建互踩 MDK 线程池/缓存）。
    private var inFlight = false
    private let lock = NSLock()

    /// 工程根（会话工作区桶下）——BuildTools 由 ctx.workspace.rootURL 注入。
    static func projectsRoot(inWorkspace workspaceRoot: URL) -> URL {
        workspaceRoot.appendingPathComponent("BuildProjects", isDirectory: true)
    }

    /// 目录最近修改时间（URLResourceValues 链式表达式独立成函数——防
    /// type-check 超时，run 39024753589 实证）。
    static func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// 构建器初始化链白盒体检（v2：只读四项 + 缓存孤儿差集 + init 链重演）。
    /// 0.0s 失败且零诊断时调用。v1 四项全绿仍失败（BuildSmoke 复测实证），
    /// v2 补两层：①缓存 .o 与当前源文件映射差集（AI 报告的「幽灵 .o」磁盘实据）
    /// ②init 链逐步重演（sync→scanner→PhaseEngine——各步副作用与正式构建
    /// 等价且幂等）。
    static func initChainProbe(project: NXProject) -> String {
        var findings: [String] = []
        let fm = FileManager.default
        let dirExists = fm.fileExists(atPath: project.url.path)
        if !dirExists {
            findings.append("工程目录不存在（" + project.url.path + "）")
        }
        let sourceCount = Self.countCodeFiles(in: project.url)
        if sourceCount == 0 {
            findings.append("源文件 0 个（构建器要求至少 1 个 .swift/.c/.cpp/.m/.mm——删除型测试后的常见残留态）")
        } else if sourceCount < 0 {
            findings.append("源文件扫描失败（工程目录不可枚举）")
        }
        let cacheExists = fm.fileExists(atPath: project.cacheURL.path)
        if !cacheExists {
            findings.append("缓存目录不存在（" + project.cacheURL.path + "）——初始化的缓存同步会静默失败")
        }
        let plistPath = project.url.appendingPathComponent("Config").appendingPathComponent("Project.plist").path
        if !fm.fileExists(atPath: plistPath) {
            findings.append("Config/Project.plist 缺失")
        }
        // ── 缓存孤儿差集（期望 .o = 相对源路径 + ".o"，与官方
        // NXExpectedObjectFileURLForFileURL 一致 NXUtils.m:69-73）──
        if cacheExists {
            let diff = Self.cacheObjectDiff(project: project)
            if diff.ghosts > 0 {
                findings.append("缓存中存在 " + String(diff.ghosts) + " 个已失去源文件的对象（" + diff.ghostList + "）")
            }
        }
        // ── init 链重演（与 NXBuilder.init 顺序对齐；失败即报死点）──
        let syncOK = project.syncFolderStructureToCache()
        if !syncOK {
            findings.append("重演第 1 步失败：syncFolderStructureToCache 返回 NO（缓存同步静默失败——NXBuilder init 会因此静默返回 nil 且零落盘）")
            return Self.renderFindings(findings)
        }
        let scanner: MDKDependencyScanner? = MDKDependencyScanner(arguments: project.projectConfig.compilerFlags)
        if scanner == nil {
            findings.append("重演第 2 步失败：MDKDependencyScanner 创建返回 nil（CC 层初始化异常）")
            return Self.renderFindings(findings)
        }
        do {
            _ = try NXPhaseEngine(project: project)
        } catch {
            findings.append("重演第 3 步失败：NXPhaseEngine 初始化——" + String(describing: error))
            return Self.renderFindings(findings)
        }
        findings.append("init 链重演全通过（sync/scanner/PhaseEngine 均正常）——失败点不在初始化链，疑似构建运行阶段失败且其 Internal 诊断被历史 reuse 洗掉（本版已修复该清洗，下次失败将直显）")
        return Self.renderFindings(findings)
    }

    static func renderFindings(_ findings: [String]) -> String {
        return findings.joined(separator: "；")
    }

    /// 缓存孤儿对象差集。ghosts=数量；ghostList=前 5 个相对路径。
    static func cacheObjectDiff(project: NXProject) -> (ghosts: Int, ghostList: String) {
        let fm = FileManager.default
        var expected: Set<String> = []
        guard let srcEn = fm.enumerator(at: project.url, includingPropertiesForKeys: nil) else {
            return (0, "")
        }
        for case let fileURL as URL in srcEn {
            let path = fileURL.path
            if path.contains("/Resources") || path.contains("/Config") {
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            if ext == "swift" || ext == "c" || ext == "cpp" || ext == "m" || ext == "mm" {
                let rel = path.hasPrefix(project.url.path) ? String(path.dropFirst(project.url.path.count + 1)) : path
                expected.insert(rel + ".o")
            }
        }
        var ghostNames: [String] = []
        var ghostCount = 0
        guard let cacheEn = fm.enumerator(at: project.cacheURL, includingPropertiesForKeys: nil) else {
            return (0, "")
        }
        for case let fileURL as URL in cacheEn {
            if fileURL.pathExtension != "o" {
                continue
            }
            let rel = fileURL.path.hasPrefix(project.cacheURL.path) ? String(fileURL.path.dropFirst(project.cacheURL.path.count + 1)) : fileURL.path
            if !expected.contains(rel) {
                ghostCount += 1
                if ghostNames.count < 5 {
                    ghostNames.append(rel)
                }
            }
        }
        let list = ghostNames.joined(separator: "、")
        return (ghostCount, list)
    }

    /// 工程源文件计数（.swift/.c/.cpp/.m/.mm，排除 Resources/Config；-1=不可枚举）。
    static func countCodeFiles(in dir: URL) -> Int {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return -1
        }
        var count = 0
        for case let fileURL as URL in en {
            let path = fileURL.path
            if path.contains("/Resources") || path.contains("/Config") {
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            if ext == "swift" || ext == "c" || ext == "cpp" || ext == "m" || ext == "mm" {
                count += 1
            }
        }
        return count
    }

    /// 取（或经官方工厂创建）工程。同名已存在 → 复用（AI 增量写码场景）。
    /// 返回 (project, created)。
    func createOrReuseProject(workspaceRoot: URL,
                              name: String,
                              interfaceKind: NXProjectInterfaceKind) throws -> (NXProject, Bool) {
        let projectsRoot = Self.projectsRoot(inWorkspace: workspaceRoot)
        let nameDir = projectsRoot.appendingPathComponent(name, isDirectory: true)

        // 同名复用：目录下已有 UUID 子目录 → 取最新工程
        if FileManager.default.fileExists(atPath: nameDir.path),
           let entries = try? FileManager.default.contentsOfDirectory(
               at: nameDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
           let latest = entries.sorted(by: {
               Self.modificationDate(of: $0) > Self.modificationDate(of: $1)
           }).first,
           let reused = NXProject(url: latest) {
            return (reused, false)
        }

        guard let project = NXProject.createProject(
            at: nameDir,
            withName: name,
            withOrganizationIdentifier: "com.wanwo",
            withBundleIdentifier: "com.wanwo.\(name.lowercased())",
            withSchemeKind: NXProjectSchemeKind.app,
            withLanguageKind: NXProjectLanguageKind.swift,
            withInterfaceKind: interfaceKind) else {
            throw BuildServiceError.createFailed(name: name)
        }
        // 【批 2 · D2 出厂模板修正 2026-10-18】官方 App 模板 NXOutputPath 把
        // .app 目录挂在 $(NXDisplayName) 上——显示名含空格/中文时 .app 目录
        // 与 macho 名不一致（压测 D2 实证；AI 变通=手改 $(NXExecutable)）。
        // 新建即覆写为 $(NXExecutable) 形态（best effort：失败不阻塞创建，
        // 语义等价旧行为）；NXDisplayName 仍独立服务 CFBundleDisplayName
        //（合规 §三 g 实证的官方正确姿势）。
        _ = Self.overwriteOutputPathTemplate(project: project)
        _ = Self.overwriteSigningGateTemplate(project: project)
        return (project, true)
    }

    /// 列会话桶下全部工程（name → 最新 UUID 工程目录）。
    func listProjects(workspaceRoot: URL) -> [(name: String, url: URL, config: NXProjectConfig?)] {
        let projectsRoot = Self.projectsRoot(inWorkspace: workspaceRoot)
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [(String, URL, NXProjectConfig?)] = []
        for nameDir in names.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: nameDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
                !entries.isEmpty else { continue }
            let latest = entries.max(by: {
                Self.modificationDate(of: $0) < Self.modificationDate(of: $1)
            }) ?? entries[0]
            let project = NXProject(url: latest)
            out.append((nameDir.lastPathComponent, latest, project?.projectConfig))
        }
        return out.map { ($0.0, $0.1, $0.2) }
    }

    // MARK: 批 2 · 工程生命周期（D5 缓解 / -O 参数化 / D2 模板 / 宏预检）

    /// 删除工程（D5 缓解：僵尸工程/损坏 plist 0.0s 不可恢复 → 可删可重建）。
    /// 范围 = BuildProjects/<name>/ 整目录 + Cache/<uuid>（每个 UUID 工程目录
    /// 对应一份编译缓存，NXProject.m:151 构造规则）。刻意不依赖 NXProject
    /// 可解析——僵尸工程（init 返回 nil）同样可删。返回 (工程目录数, 缓存目录数)。
    static func deleteProjectDirectories(workspaceRoot: URL, name: String) throws -> (projects: Int, caches: Int) {
        // 名称校验同 resolveProject（防空名/分隔符退化——nameDir==根 fail closed）
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw BuildServiceError.projectNotFound(name: name)
        }
        let projectsRoot = Self.projectsRoot(inWorkspace: workspaceRoot)
        let nameDir = projectsRoot.appendingPathComponent(name, isDirectory: true)
        // 双保险：目标必须真落在 projectsRoot 内
        let targetPath = nameDir.standardizedFileURL.path
        let rootPath = projectsRoot.standardizedFileURL.path
        guard targetPath.hasPrefix(rootPath + "/") else {
            throw BuildServiceError.fileEscapesProject(name: name, file: nameDir.path)
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: targetPath) else {
            throw BuildServiceError.projectNotFound(name: name)
        }
        let entries = (try? fm.contentsOfDirectory(
            at: nameDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var cacheCount = 0
        if !entries.isEmpty {
            let cacheRoot = NXBootstrap.shared().rootURL.appendingPathComponent("Cache", isDirectory: true)
            for entry in entries {
                let cacheDir = cacheRoot.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
                if fm.fileExists(atPath: cacheDir.path) {
                    try? fm.removeItem(at: cacheDir)
                    cacheCount += 1
                }
            }
        }
        try fm.removeItem(at: nameDir)
        return (entries.count, cacheCount)
    }

    /// D2 出厂模板修正：官方 App 模板 NXOutputPath = `$(CACHEROOT)/Payload/
    /// $(NXDisplayName).app/$(NXExecutable)`（NXProject.m:276）——显示名空格/
    /// 中文 → .app 目录与 macho 名不一致。新建工程覆写为 $(NXExecutable) 形态。
    /// 幂等：值非官方默认形态（AI 已自定义）不动。best effort：任何失败返回
    /// false，不阻塞创建。
    static func overwriteOutputPathTemplate(project: NXProject) -> Bool {
        let plistURL = project.url.appendingPathComponent("Config").appendingPathComponent("Project.plist")
        guard let read = NSDictionary(contentsOf: plistURL) else { return false }
        let current = read["NXOutputPath"] as? String ?? ""
        // 官方 App 默认形态才覆写（幂等 + 不碰 AI 自定义值）
        guard current == "$(CACHEROOT)/Payload/$(NXDisplayName).app/$(NXExecutable)" else { return true }
        let dict = NSMutableDictionary(dictionary: read)
        dict["NXOutputPath"] = "$(CACHEROOT)/Payload/$(NXExecutable).app/$(NXExecutable)"
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return false
        }
        return project.reload()
    }

    /// -O 参数化（压测建议 12）：NXSwiftFlags 追加/移除 "-O" 并写回 plist +
    /// reload 生效。官方默认数组无优化等级（swiftc 默认 -Onone）；AI 实测
    /// -O 编译 1.9s→6.7s 换运行性能。持久写入=参数即真值语义。无变化时
    /// 不写盘直接返回。
    static func setSwiftOptimization(project: NXProject, enabled: Bool) throws -> String {
        let plistURL = project.url.appendingPathComponent("Config").appendingPathComponent("Project.plist")
        guard let read = NSDictionary(contentsOf: plistURL) else {
            throw BuildServiceError.plistUnreadable(path: plistURL.path)
        }
        var flags = (read["NXSwiftFlags"] as? [String]) ?? []
        let hasO = flags.contains("-O")
        if enabled && !hasO {
            flags.append("-O")
        } else if !enabled && hasO {
            flags.removeAll { $0 == "-O" }
        } else {
            if enabled {
                return "-O already present（无变化）"
            }
            return "-O not present（无变化）"
        }
        let dict = NSMutableDictionary(dictionary: read)
        dict["NXSwiftFlags"] = flags
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        let ok = project.reload()
        if !ok {
            throw BuildServiceError.plistReloadFailed(path: plistURL.path)
        }
        if enabled {
            return "-O written to NXSwiftFlags（编译较慢、运行更快；持久生效）"
        }
        return "-O removed from NXSwiftFlags（回到默认 -Onone）"
    }

    /// 宏预检（压测建议 6）：枚举 .swift 源文件统计设备端不可用宏的字面出现
    ///（#Preview/@Observable/@Model——external macro 官方边界，§三 f 实证
    /// 必败）。字面匹配不解析语法：注释/字符串误报可接受（提示语已注明）。
    /// 返回 (命中文件数, 前 5 个相对路径)。
    static func scanMacroUsage(project: NXProject) -> (files: Int, samples: [String]) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: project.url, includingPropertiesForKeys: nil) else {
            return (0, [])
        }
        var hitFiles = 0
        var samples: [String] = []
        // 【批 2 修 2026-10-18】rootPath 与枚举路径双侧 resolvingSymlinksInPath
        // 对齐真实路径——装机审计实锤：/var/mobile（符号链接形态）与
        // /private/var/mobile（真实形态）混用致 hasPrefix 失配，files 列表
        // 退化成绝对路径直出（拦截功能不受影响，纯输出质量）。
        let rootPath = project.url.standardizedFileURL.resolvingSymlinksInPath().path
        for case let fileURL as URL in en {
            let path = fileURL.resolvingSymlinksInPath().path
            if path.contains("/Resources") || path.contains("/Config") {
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            if ext != "swift" {
                continue
            }
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            let hitPreview = text.contains("#Preview")
            let hitObservable = text.contains("@Observable")
            let hitModel = text.contains("@Model")
            if hitPreview || hitObservable || hitModel {
                hitFiles += 1
                if samples.count < 5 {
                    let rel = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count + 1)) : path
                    samples.append(rel)
                }
            }
        }
        return (hitFiles, samples)
    }

    // MARK: 批 2 收官 · fakefs 元数据补注册（D6 根治）+ lld 污染标志

    /// 【D6 根治 2026-10-18】guest rootfs = iSH fakefs 混合模式：目录元数据在
    /// meta.db 的 paths 表、文件内容在真实 FS——host（Swift/fs 工具/构建管线）
    /// 直写真实目录树而不注册元数据时，guest readdir（ls/find）看不到新目录
    ///（装机审计实锤：新建工程 ls 不可见、cat 完整路径可读）。枚举工程目录树
    /// 逐项补注册，复用 IshExecutorBridge.ensureFakefsMetadata 既有钩子（与
    /// 挂载/adopt 同源），零 vendored 改动。guestMount = 工作区在 guest 侧的
    /// 挂载根（与 guestPathHint 同源 sessionCwd）；nil 则保守跳过（仅失去
    /// guest 可见性，构建本身不受影响）。
    static func registerProjectTreeInFakefs(projectURL: URL, workspaceRoot: URL, guestMount: String?) {
        guard let guestMount, !guestMount.isEmpty else { return }
        let fm = FileManager.default
        let wsRoot = workspaceRoot.standardizedFileURL.path
        let projPath = projectURL.standardizedFileURL.path
        guard projPath.hasPrefix(wsRoot + "/") else { return }
        // 相对工作区根 = "/BuildProjects/<name>/<uuid>"
        let projRel = String(projPath.dropFirst(wsRoot.count))
        // 父链先行：nameDir（/BuildProjects/<name>）首次创建也未注册
        let nameDirRel = (projRel as NSString).deletingLastPathComponent
        IshExecutorBridge.ensureFakefsMetadata(for: guestMount + nameDirRel, isDirectory: true)
        IshExecutorBridge.ensureFakefsMetadata(for: guestMount + projRel, isDirectory: true)
        guard let en = fm.enumerator(at: projectURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        for case let fileURL as URL in en {
            let path = fileURL.standardizedFileURL.path
            guard path.hasPrefix(projPath + "/") else { continue }
            let rel = String(path.dropFirst(projPath.count))
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            IshExecutorBridge.ensureFakefsMetadata(for: guestMount + projRel + rel, isDirectory: isDir)
        }
    }

    // MARK: lld 污染标志（上游 dupSymDiags 残留的事前拦截）
    // lld/MachO/SymbolTable.cpp 的 dupSymDiags（D134794 引入）文件级静态且无
    // clear（对照 undefs 有 clear——疏漏）。同进程第二次链接时 Writer::run
    // 无条件重放残留诊断，toString(*悬空 sym) 读第一次链接已释放的 arena →
    // UAF/闪退（.ips：memmove←__assign_external←reportPendingDuplicateSymbols，
    // 0x157538000 恰落已回收 MALLOC_LARGE 64K 块边界）。lld CLI 单进程单链接
    // 不触发，上游无感知至今未修。万我无法从外部清理 lld 内部静态——精确
    // 止损：诊断含 duplicate symbol → 置进程级标志 → 后续构建事前拦截并引导
    // 重启 App（把随机闪退转成明确失败+指引）。
    private static let contaminationLock = NSLock()
    private static var lldContaminated = false

    static var isLldContaminated: Bool {
        contaminationLock.lock(); defer { contaminationLock.unlock() }
        return lldContaminated
    }

    static func markLldContaminatedIfDuplicate(_ summary: String) {
        guard summary.contains("duplicate symbol:") else { return }
        contaminationLock.lock(); defer { contaminationLock.unlock() }
        lldContaminated = true
    }

    // MARK: N7c · 签名编排（用户导入证书 → ZSign 签 bundle → 重打包 ipa）

    /// 从 mobileprovision 数据解析 Entitlements 的 application-identifier
    /// → 提取 bundle id 部分。mobileprovision = CMS(DER) 二进制容器包裹的
    /// 明文 plist——【装机复测修】String(utf8) 解码整包会因 CMS 二进制
    /// 字节失败（轻松签实测解析失败实证）→ 改 Data 字节级搜索（range(of:)
    /// 二进制安全）定位 <?xml … </plist> 段后 PropertyListSerialization
    /// 解析，零外部依赖。
    /// 返回 (bundleId, isWildcard)：application-identifier 形如
    /// "TEAMID.com.xxx" → bundleId="com.xxx"；以 "*" 结尾 = 通配 profile。
    static func bundleIdFromProfile(_ data: Data) -> (bundleId: String, isWildcard: Bool)? {
        guard let startRange = data.range(of: Data("<?xml".utf8)),
              let endRange = data.range(of: Data("</plist>".utf8)),
              endRange.upperBound > startRange.lowerBound else {
            return nil
        }
        let xmlData = data.subdata(in: startRange.lowerBound..<endRange.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(
            from: xmlData, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        guard let entitlements = plist["Entitlements"] as? [String: Any],
              let appId = entitlements["application-identifier"] as? String else {
            return nil
        }
        let isWildcard = appId.hasSuffix("*")
        // TEAMID.bundleid → 去掉第一段
        guard let dot = appId.firstIndex(of: ".") else { return nil }
        let bundleId = String(appId[appId.index(after: dot)...])
        if bundleId.isEmpty { return nil }
        return (bundleId, isWildcard)
    }

    /// 【N7c】对构建产出的 .app 做 ZSign 签名并重打包 ipa。证书三件来自
    /// CertificateStore（N7b：p12+profile 沙盒文件、密码 Keychain）。官方
    /// 对照：0.10.3 Builder.install(.RunningApp) 签名段（semaphore 等待
    /// ZSigner 回调形态，semaphore.wait 阻塞 MDK 线程为官方同款）；prov=
    /// 用户导入 profile（万我 unsigned 分发无宿主 embedded——导入式语义）；
    /// 不 patch（LCPatchExecSlice 属 LC 容器化运行，归 N9）。签名改变
    /// bundle 内容 → ipa 必须重 zip（官方 package() 同款
    /// zipDirectoryAtPath——桥接头 <LindChain/Utils/Zip.h>）。
    ///
    /// 【装机复测修 2026-10-19 · 第一轮】轻松签实测「装上后点开无法安装」
    /// 三根因：①zsign.mm:65 硬编码不生成 embedded.mobileprovision ②profile
    /// 的 application-identifier（非通配）与包 CFBundleIdentifier 错配 → 签
    /// 名前把 Info.plist 改写为 profile 的 bundle id ③zsign.mm:121 对
    /// signFailedFiles 非空仍回调 YES → 如实上报。
    /// 【装机复测修 · 第二轮】复测仍失败——事件流取证
    /// signFailedFiles="TestApp.app//private/var/.../WanWo.app/WanWo"（宿主
    /// 可执行路径被拼进签名对象）→ 源码对质 bundle.cpp:53-54：0.10.3 把
    /// Info.plist 的 CFBundleExecutable/CFBundleIdentifier **覆写为宿主
    /// App 值**（getExecutablePath/getBundleIdentifier——LiveContainer 容
    /// 器化魔改：guest 签名身份=LC 宿主）→ 签名 identifier=宿主 id+主二进
    /// 制路径解析失败（TestApp 在 files 循环被错身份签名）→ 修复=vendored
    /// 删除两行覆写恢复 zsign 上游语义（diff 登记 gpl-compliance §N7c；
    /// 上轮的 Info.plist 对齐修复在删除后**才真正生效**——此前被覆写绕过）
    /// ④profile 的 utf8 解码失败（CMS 二进制包裹）→ bundleIdFromProfile
    /// 改 Data 字节级搜索 ⑤补写 profile/清 zsign_cache.json 必须**在 ZSign
    /// 之后**（ConfigureFolderSign 先 RemoveFileV 删 profile 再按 flag 跳过
    /// 重写；zsign_cache.json 由 StartSign 完成时写出——签名前操作全部无效）。
    /// 返回 (成功, 描述)。
    static func signAndRepackage(project: NXProject) -> (ok: Bool, message: String) {
        guard let p12 = CertificateStore.loadCertificateData(),
              let profile = CertificateStore.loadProfileData(),
              let password = CertificateStore.loadPassword() else {
            return (false, "未配置签名证书——请到 设置→签名证书 导入 p12+描述文件+密码")
        }
        // ① bundle id 对齐 profile（非通配时改写 Info.plist——签名 zsign 从
        //    Info.plist 读 identifier，entitlements 来自 profile，两者必须
        //    同源；CFBundleIdentifier 变更=交付产物身份即 profile 身份）
        var alignmentNote = ""
        if let parsed = Self.bundleIdFromProfile(profile) {
            if parsed.isWildcard {
                alignmentNote = "；profile 为通配（bundle id 保持工程值）"
            } else {
                let infoURL = project.bundleURL.appendingPathComponent("Info.plist")
                if let read = NSDictionary(contentsOf: infoURL) {
                    let current = read["CFBundleIdentifier"] as? String ?? ""
                    if current != parsed.bundleId {
                        let dict = NSMutableDictionary(dictionary: read)
                        dict["CFBundleIdentifier"] = parsed.bundleId
                        do {
                            let data = try PropertyListSerialization.data(
                                fromPropertyList: dict, format: .xml, options: 0)
                            try data.write(to: infoURL, options: .atomic)
                            alignmentNote = "；bundle id 已对齐证书（" + parsed.bundleId + "）"
                        } catch {
                            return (false, "签名前置失败：Info.plist 改写错误（" + error.localizedDescription + "）")
                        }
                    }
                }
            }
        } else {
            alignmentNote = "；⚠️ 描述文件解析失败，bundle id 未对齐——产物可能因身份不匹配无法安装"
        }
        // ② 【时序关键】ZSign 签名（官方同款 semaphore 形态）。
        //    embedded.mobileprovision 补写与 zsign_cache.json 清理都必须在
        //    ZSign **之后**：ConfigureFolderSign 内部先 RemoveFileV 删
        //    embedded.mobileprovision、再按 bDontGenerateEmbeddedMobileProvision=
        //    YES（zsign.mm:65 官方硬编码）跳过重写——签名前补写会被内部删除；
        //    zsign_cache.json 由 StartSign 完成时写出（bundle.cpp:711）——签名
        //    前清理无效。profile 文件（非代码资源）不被签名 blob 覆盖，后写
        //    安全；系统安装/启动时读取它。
        let semaphore = DispatchSemaphore(value: 0)
        var signOK = false
        var signMessage = ""
        _ = ZSigner.sign(withAppPath: project.bundleURL.path,
                         prov: profile, key: p12, pass: password,
                         completionHandler: { success, error in
            if success {
                if let err = error, !err.localizedDescription.isEmpty {
                    signOK = true
                    signMessage = "签名完成，但部分文件签名失败（产物可能不可用）：" + err.localizedDescription
                } else {
                    signOK = true
                    signMessage = "签名完成（证书已嵌入，可安装）"
                }
            } else {
                signOK = false
                signMessage = "签名失败：" + (error?.localizedDescription ?? "未知错误")
            }
            semaphore.signal()
        })
        semaphore.wait()
        guard signOK else {
            return (false, signMessage)
        }
        // ③ ZSign 后补写 embedded.mobileprovision + 清理 zsign_cache.json
        //   （都在 zip 前落定——见②时序说明）
        do {
            try profile.write(
                to: project.bundleURL.appendingPathComponent("embedded.mobileprovision"),
                options: .atomic)
        } catch {
            return (false, "签名后置失败：描述文件写入错误（" + error.localizedDescription + "）")
        }
        let junkNames = ["zsign_cache.json", "zsign_cache"]
        for junk in junkNames {
            let junkURL = project.bundleURL.appendingPathComponent(junk)
            try? FileManager.default.removeItem(at: junkURL)
        }
        if !alignmentNote.isEmpty {
            signMessage = signMessage + alignmentNote
        }
        // ④ 重打包（签名改变 bundle 内容——ipa 必须重 zip；官方 package()
        //    同款函数）
        zipDirectoryAtPath(project.payloadURL.path, project.packageURL.path, true)
        return (true, signMessage)
    }

    /// 【N7c 出厂 gate】新建工程显式写 NXSignMachOWithNyxianEntitlements=false
    ///（官方默认 true——NXProject.m:82）。语义：vendored NXBuilder 的
    /// .export/.run 分支在 WANWO_BUILD_RUN 开宏后会调 trust_nxt2_sign
    ///（ksurface token 追加——N7 无消费方，token 体系归 N8/N9）；出厂 false
    /// 保证宏开启当天不撞未落位符号。D2 同款 best effort 幂等。
    static func overwriteSigningGateTemplate(project: NXProject) -> Bool {
        let plistURL = project.url.appendingPathComponent("Config").appendingPathComponent("Project.plist")
        guard let read = NSDictionary(contentsOf: plistURL) else { return false }
        // 只在键缺失时写入（幂等：AI 显式改 true 的尊重之——N8/N9 启用 token 时走显式路径）
        guard read["NXSignMachOWithNyxianEntitlements"] == nil else { return true }
        let dict = NSMutableDictionary(dictionary: read)
        dict["NXSignMachOWithNyxianEntitlements"] = false
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return false
        }
        return project.reload()
    }

    /// 单飞行门。返回 false = 已有构建在途（stop_build/等待后重试）。
    func beginBuild() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if inFlight { return false }
        inFlight = true
        return true
    }

    func endBuild() {
        lock.lock(); defer { lock.unlock() }
        inFlight = false
    }

    /// 是否有构建在途（批 2：project_delete/reset 前置检查——构建中删
    /// 工程目录会让在途构建踩空路径）。
    var isBuilding: Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight
    }

    /// 官方全链构建（.export）。completion 在 MDK 线程池线程回调。
    /// 【N7c】sign=true 且构建成功 → ZSign 签名 bundle（用户导入证书）+
    /// 重打包 ipa——官方对照：0.10.3 Builder.install(.RunningApp) 签名段
    ///（semaphore 等待 ZSigner 回调形态；不 patch——LCPatchExecSlice 属
    /// LC 容器化运行归 N9）。
    func build(project: NXProject, sign: Bool = false, completion: @escaping (BuildResult) -> Void) {
        let started = Date()
        NXBuilder.buildProject(withProject: project, buildType: .export) { [weak self] result, _ in
            let elapsed = Date().timeIntervalSince(started)
            let db = DebugDatabase.getDatabase(
                ofPath: project.cacheURL.appendingPathComponent("debug.json").path)
            // 【0.0s 透明化 2026-10-18】此处原调 db.reuseDatabase()——它把 Internal
            // 桶整个重置为空（Project+Debug.swift:236-238），而初始化/运行失败的
            // 诊断（"Nothing to build"/"Failed to run project" 等）恰恰落在
            // Internal 桶——读取前清空=永远「零诊断」（BuildSmoke 0.0s 实证）。
            // 编译诊断在 File 桶不受影响，故呈二分：编译失败可见、init 失败静默。
            // 删掉展示层这次 reuse（官方 NXBuilder init 的 reuse 保留——每轮构建
            // 开始仍会重置 Internal，展示层不再二次清洗）。
            // 诊断可定位化（保守形态重做——嵌套函数+正则链
            // 疑触发 swiftc 崩溃 run 39032097279/rerun，见 §三 g）。
            let rootPrefix = project.url.standardizedFileURL.path + "/"
            // file 在 DebugObject 的键上（MDKSourceLocation 只有行列）。
            struct Rendered { let level: String; let file: String; let line: Int; let col: Int; let message: String }
            var rendered: [Rendered] = []
            for (title, object) in db.debugObjects {
                // 全部拆单步局部变量（type-check 超时惯犯：构造器内嵌三元/
                // 下标链/?? 混合——第 5 次实证）。
                let file = title.hasPrefix("/") ? String(title.dropFirst(rootPrefix.count)) : title
                for item in object.debugItems {
                    let levelKey = Int(item.severity.rawValue)
                    let level = Self.levelNames[levelKey] ?? "note"
                    let lineNum = Int(item.sourceLocation.line)
                    let colNum = Int(item.sourceLocation.column)
                    let msg = item.message
                    rendered.append(Rendered(level: level, file: file, line: lineNum,
                                             col: colNum, message: msg))
                }
            }
            // 两步稳定排序替代三元混合比较闭包。
            rendered.sort { $0.file < $1.file }
            rendered.sort { $0.level < $1.level }
            // 【压测报告 D8】同位置重复诊断去重（宏错误连喷 2-3 条实证）。
            var seenKeys = Set<String>()
            var uniq: [Rendered] = []
            for r in rendered {
                let key = r.file + ":" + String(r.line) + ":" + String(r.col) + ":" + r.message
                if seenKeys.insert(key).inserted { uniq.append(r) }
            }
            // 【污染检测 2026-10-18】同进程内一次链接失败后 CC/lld 全局状态残留
            //（复现实证：空符号名 8 连发 + A1/Verify2 构建报 Demo 工程的 .o 路径
            //（不同缓存目录、物理上不可能是真实链接输入）+ stop_build 无效 +
            // 重启 App 即愈）。两个特征任一命中即提示重启，避免 AI 反复盲试。
            var contaminationHint = ""
            if !result {
                let ownUUID = project.cacheURL.lastPathComponent
                var suspect = false
                for r in uniq {
                    let msg = r.message
                    if msg.contains("duplicate symbol: \n") || msg.hasSuffix("duplicate symbol: ") {
                        suspect = true
                    }
                    if (msg.contains("/Cache/") || msg.contains("Cache//")) && !msg.contains(ownUUID) {
                        suspect = true
                    }
                }
                if suspect {
                    contaminationHint = "\n⚠️ 检测到构建服务状态污染特征（空符号名/他工程缓存路径）——同进程残留影响，重启 App 后可恢复；stop_build 无法清除。"
                }
            }
            // 零插值形态（type-check 超时第 4 次实证——插值链全部改拼接）。
            var lines2: [String] = []
            for r in uniq.prefix(50) {
                var line = "[" + r.level + "] "
                if r.line > 0 {
                    line = line + "[" + r.file + ":" + String(r.line) + ":" + String(r.col) + "] "
                }
                line = line + r.message
                line = line.replacingOccurrences(
                    of: "/private/var/mobile/Containers/Data/Application/",
                    with: "wanwo-build-sandbox/")
                lines2.append(line)
            }
            let summary: String
            if lines2.isEmpty {
                if result {
                    // 【压测报告 D3】零诊断文案分 success/failure 两态——success 空
                    // 诊断是正常态，误显失败指路文案纯属噪音（真机实证）。
                    summary = "构建成功，无诊断"
                } else {
                    // 【0.0s 透明化 2026-10-18】失败且零诊断=大概率初始化阶段静默
                    // 失败（NXBuilder init 的 sync 失败路径 return nil 零落盘；实测
                    // BuildSmoke：plist 正常仍 0.0s，原"检查 XML"指路误导）。
                    var zeroDiag = "（零诊断失败——大概率构建器初始化阶段静默失败。白盒体检："
                    zeroDiag = zeroDiag + Self.initChainProbe(project: project)
                    zeroDiag = zeroDiag + "。进一步：build_log 查看本工程 debug.json（阶段引擎失败会留 Internal 条目）；或换新工程名重建——同名复用不会重置已损坏工程）"
                    summary = zeroDiag
                }
            } else {
                var tail = ""
                if uniq.count > 50 {
                    tail = "\n…（仅显示前 50 条，共 " + String(uniq.count) + " 条——修一批再构建看下一批）"
                }
                summary = lines2.joined(separator: "\n") + tail + contaminationHint
            }

            // 【lld 污染标志】链接阶段 duplicate symbol 失败 → lld 静态残留
            //（dupSymDiags 无 clear），同进程后续链接有 UAF 闪退风险——置位
            // 供工具层事前拦截（BuildIPATool）。
            Self.markLldContaminatedIfDuplicate(summary)
            // 【N7c 签名编排】构建成功才签（失败产物无 bundle 可签）；签名
            // 失败不翻构建结果——ipa（未签名版）仍有效，AI 可修证书后重试。
            var signNote: String? = nil
            if result && sign {
                let outcome = Self.signAndRepackage(project: project)
                signNote = outcome.message
            }
            let finalResult = BuildResult(
                success: result,
                projectName: project.projectConfig.displayName ?? "Unknown",
                projectURL: project.url,
                bundleURL: project.bundleURL,
                machoURL: project.machoURL,
                ipaURL: project.packageURL,
                buildLogPath: project.cacheURL.appendingPathComponent("debug.json").path,
                diagnosticsSummary: summary.isEmpty ? "（无诊断条目）" : summary,
                signNote: signNote,
                elapsedSeconds: elapsed)
            completion(finalResult)
        }
    }
}

// MARK: - 错误

enum BuildServiceError: Error, CustomStringConvertible {
    case createFailed(name: String)
    case projectNotFound(name: String)
    case fileEscapesProject(name: String, file: String)
    case plistUnreadable(path: String)
    case plistReloadFailed(path: String)

    var description: String {
        switch self {
        case .createFailed(let name):
            return "createProject failed for \"\(name)\"（脚手架/模板阶段失败）"
        case .projectNotFound(let name):
            return "project \"\(name)\" not found（先 project_create 或核对 project_list）"
        case .fileEscapesProject(let name, let file):
            return "path \"\(file)\" escapes project \"\(name)\"（拒绝越界访问）"
        case .plistUnreadable(let path):
            return "project plist unreadable（\(path)）"
        case .plistReloadFailed(let path):
            return "project reload failed after plist write（\(path)）"
        }
    }
}
