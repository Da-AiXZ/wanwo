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
    /// 【批 3 · P1】补齐 vendored MDKDiagnosticLevel 全枚举（fatal=4/unknown=5
    /// ——MDKDiagnostic.h:39-45；旧表 0-3 在 build_log 渲染面会漏映射）。
    static let levelNames: [Int: String] = [0: "note", 1: "remark", 2: "warning",
                                            3: "error", 4: "fatal", 5: "unknown"]

    /// 单飞行门（官方 NXBuilder.builds 同语义：并发构建互踩 MDK 线程池/缓存）。
    private var inFlight = false
    /// 【N9b】guest run 在途标志（与 inFlight 同锁）。
    private var runInFlight = false
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
    /// 【N10e 修 A】schemeKind 透传：官方工厂全参数本就在位（NXProject.m:169-178，
    /// 万我此前固定传 .app），本参数只是把工具面的 scheme 选择透传下去。
    /// App 形态默认值=旧行为零回归。Utility 时 interfaceKind 强制
    /// NXProjectInterfaceKind.unknown——官方合法性矩阵
    /// NXProjectConfigurationIsValid（NXType.m:157-199）要求 Utility+Unknown
    ///（Utility+SwiftUI 不合法，工厂 assert(NXProjectConfigurationIsValid)
    /// NXProject.m:178 断言会炸宿主进程）；模板寻径 interface=nil 分支按
    /// scheme/language 两级（NXCodeTemplate.m:26-45），Templates.bundle/
    /// Templates/Utility/Swift/Main.swift 在位（顶层代码形态）。
    /// Utility 创建后 D2/出厂 gate 两个 best-effort 覆写仍执行：输出路径覆写
    /// 对 Utility 是 no-op（guard 只匹配官方 App 默认形态
    /// "$(CACHEROOT)/Payload/$(NXDisplayName).app/$(NXExecutable)"——官方
    /// utility 值 "$(CACHEROOT)/$(NXExecutable)" 不命中，NXProject.m:279-283
    /// 原样保留）；出厂 gate false 对 Utility 同样成立（万我 utility token 步
    /// prepareUtilityRun 无条件执行，不读该键—— vendored NXBuilder
    /// WANWO_BUILD_RUN 防撞语义与 scheme 无关）。
    func createOrReuseProject(workspaceRoot: URL,
                              name: String,
                              schemeKind: NXProjectSchemeKind = NXProjectSchemeKind.app,
                              interfaceKind: NXProjectInterfaceKind) throws -> (NXProject, Bool) {
        // Utility → interfaceKind=unknown（官方合法性矩阵唯一 Utility 合法形态，
        // 见上注——不收口会撞 NXProject.m:178 断言炸宿主）。
        var effectiveInterfaceKind = interfaceKind
        if schemeKind != NXProjectSchemeKind.app {
            effectiveInterfaceKind = NXProjectInterfaceKind.unknown
        }
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
            withSchemeKind: schemeKind,
            withLanguageKind: NXProjectLanguageKind.swift,
            withInterfaceKind: effectiveInterfaceKind) else {
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
        // 【批 3 · P2】新建 App 工程脚手架补键（CFBundleDevelopmentRegion/
        // CFBundlePackageType——官方模板 NXBundleInfo 不含，guest 启动告警
        // 实测）。只对新建工程；复用路径不动（避免意外改用户既有工程——
        // 本行只在 created 分支到达）。Utility 工程无 bundle 面不触碰。
        if schemeKind == NXProjectSchemeKind.app {
            _ = Self.injectDefaultBundleKeys(project: project)
        }
        return (project, true)
    }

    /// 【批 3 · P2】新建 App 工程脚手架补键：向 Config/Project.plist 的
    /// NXBundleInfo 注入 CFBundleDevelopmentRegion=en、CFBundlePackageType=
    /// APPL（guest Info.plist 由 NXBundleInfo 渲染——vendored NXProject.m:90
    /// _infoDictionary 装载链实测两键缺失=启动告警）。只补缺失键（已存在
    /// 不覆盖——防冲用户自定义）；幂等 best effort（任何失败返回 false，
    /// 不阻塞创建——语义等价旧行为）。
    static func injectDefaultBundleKeys(project: NXProject) -> Bool {
        let plistURL = project.url.appendingPathComponent("Config").appendingPathComponent("Project.plist")
        guard let read = NSDictionary(contentsOf: plistURL) else { return false }
        var bundleInfo = read["NXBundleInfo"] as? [String: Any] ?? [:]
        var changed = false
        if bundleInfo["CFBundleDevelopmentRegion"] == nil {
            bundleInfo["CFBundleDevelopmentRegion"] = "en"
            changed = true
        }
        if bundleInfo["CFBundlePackageType"] == nil {
            bundleInfo["CFBundlePackageType"] = "APPL"
            changed = true
        }
        if !changed { return true }
        let dict = NSMutableDictionary(dictionary: read)
        dict["NXBundleInfo"] = bundleInfo
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return false
        }
        return project.reload()
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
    /// 【第四轮】「无法验证其完整性」真因=InitSimple 不填 m_strProvData
    ///（profile 永久缺失）+CodeResources 空壳（GenerateCodeResources 被官方
    /// 注释）→ 资源 seal 缺失。修复=openssl.cpp InitSimple 补存 prov +
    /// bundle.cpp 恢复 GenerateCodeResources（均条件化于 wanwo_zsign_host_
    /// identity 开关）；本方法的后置 profile 补写删除（zsign 内部接管）。
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
        // ② ZSign 签名（官方同款 semaphore 形态）。
        //    【第四轮后时序语义】profile 由 zsign 内部写入（InitSimple 补存
        //    m_strProvData → ConfigureFolderSign 的「prov 非空才写」恢复生效
        //    → RemoveFileV 后写入，先于 CodeResources 枚举——清单含 profile）；
        //    CodeResources 由标准模式恢复的 GenerateCodeResources 生成（完整
        //    资源 seal）；zsign_cache.json 仍由 StartSign 末尾写出——清理须在
        //    ZSign 之后（见③）。第二、三轮的「签名前/后补写 profile」方案均
        //    被第四轮取代（前者被 ConfigureFolderSign 删除、后者缺资源 seal）。
        //    zsign.mm:121 对 signFailedFiles 非空仍回调 success=YES——error
        //    非空时如实上报。
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
        // ③ 【第四轮修正】embedded.mobileprovision 由 zsign 内部写入（本轮
        //    修复 InitSimple 补存 m_strProvData 后 ConfigureFolderSign 的
        //    「prov 非空才写」条件恢复生效——且写入先于 CodeResources 生成，
        //    资源 seal 完整覆盖）；CodeResources 由恢复的 GenerateCodeResources
        //    生成（标准模式）。仅清理 zsign_cache.json（StartSign 末尾写出）。
        let junkURL = project.bundleURL.appendingPathComponent("zsign_cache.json")
        try? FileManager.default.removeItem(at: junkURL)
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

    // MARK: N9a · guest 承载签名与安装编排（与 signAndRepackage 并列、互不污染）

    struct GuestRunPreparation {
        let ok: Bool
        let message: String
        /// token 位图（十六进制串——诊断/事件注记用）。
        let entitlementBits: String
        /// guest bundle id（工程值——磁盘 Info.plist/installd 注册/spawn
        /// 查找三方同源；签名 identifier=宿主 id 属 zsign 容器模式覆写，
        /// 不落盘——官方 0.10.3 容器形态同构）。
        let bundleID: String
        /// 【N9d 诊断增强】prepare 细目（a-e 步骤结构化诊断——BuildResult
        /// 同款只增不改；失败时含失败点浅因）。
        let detail: String
    }

    /// 官方 .run 签名编排等义（0.10.3 Builder.swift:292-357，semaphore 形态
    /// 照抄 N7c 先例）。调用前提：build(.export) 已成功、bundleURL 树就绪。
    /// 步骤（官方顺序，逐段）：
    ///   ① 补片（LCUtils.signAppBundleWithZSign 补片段——GuestRunSupport）；
    ///   ② 容器模式 ZSign：wanwo_setHostIdentityOverride(true) 显式开 →
    ///      ZSigner.sign → 签名完复位 NO（开关仅 run 路径内在位；标准交付
    ///      signAndRepackage 路径零变化）。容器模式语义（zsign 内部三消费
    ///      点）：签名 identifier=宿主 id（【N9 修】仅 identifier——executable
    ///      路径恢复 zsign 上游语义，主二进制按 guest folder 内真实可执行
    ///      文件签名）/ CodeResources 跳过 / embedded.mobileprovision 不写
    ///      ——prov 传【宿主本体嵌入的 embedded.mobileprovision】（官方
    ///      LCUtils.m:95-96 原样语义——iLoader 重签宿主时嵌入的开发档
    ///      profile，TeamId 与宿主 id 同体系；TeamId+entitlements 提取必需，
    ///      openssl.cpp InitSimple:732-743 对 prov 的读取不经开关）；
    ///      guest 签名私钥=CertificateStore 的 p12+密码（官方同构：导入
    ///      p12 出私钥、宿主自带 profile 出身份——私钥与 profile 可不同源，
    ///      用户 0.10.3 亲测背书）。交付路线（signAndRepackage）仍用用户
    ///      导入 profile——双轨制互不污染；
    ///   ③ macho_after_sign 追加 NXTR token（entitlement=工程 Entitlements
    ///      .plist 位图映射——vendored NXEntitlementsConfig 无 entitlement
    ///      属性（§N4N5 适配删除），位图映射在 GuestRunSupport 万我层重建）；
    ///   ④ installApplication（N9d 起经 GuestRunSupport 自有包装——官方
    ///      LDEApplicationWorkspace.installApplicationAtBundlePath 等义重写，
    ///      XPC→installd daemon，2s 超时=官方硬编码 LDEApplicationWorkspace.m:117，
    ///      返回枚举区分 reply(NO)/超时/XPC 错误回调。【N9 装后通知层修复
    ///      （L2 实锤轮）】连接 observer 挂 WanWoGuestInstallObserver +
    ///      exportedInterface=LDEApplicationWorkspaceProtocol（原 observer=nil
    ///      形态被 daemon 装后广播 applicationWasInstalled:(LDEApplicationObject*)
    ///      击穿——导出面无该选择器→连接失效→reply 丢失→xpcError；install
    ///      本体在 daemon 侧每次都成功，判别探针 YES 实锤）。
    /// 与标准签名路径的三点差异（防混淆）：不做 profile bundle id 对齐（容器
    /// 模式磁盘 Info.plist 保持工程 id）；不重打包 ipa（安装取 bundleURL 树）；
    /// 不清 zsign_cache.json（容器模式 zsign 不写缓存产物路径不同——实测
    /// 无残留；如有再收）。
    /// 【N9d 诊断增强版】prepare 细目按 a-e 步骤结构化采集（纯诊断——
    /// 签名方式/身份对齐/标准路径零变化，只把每步结果与浅因如实透出）：
    ///   a 补片成功/失败；
    ///   b 宿主实际 bundle id（设备上可能为重签后缀形态）vs 宿主 embedded
    ///     profile 解析 app-id（BuildService.bundleIdFromProfile 现成）并列
    ///     展示（两 id 同体系=健康——【N9 修】profile 改宿主本体嵌入档）；
    ///   c 容器签名 ZSigner 回调如实透出（signFailedFiles 非空=N7c 二轮
    ///     同族静默失败证据）；
    ///   d token 追加；
    ///   e installApplication 经 GuestRunSupport 自有包装区分 reply(NO) vs
    ///     2s 超时 vs XPC 错误回调（vendored 版三态同显 NO）。
    /// S1/S2 签名自查已回退（2026-10-20 真机双闪退实锤雷区——同进程
    /// F_ADDFILESIGS→改文件→mmap = 内核 CS_KILL Invalid Page，见
    /// docs/gpl-compliance.md §N9「S1/S2 回退」，禁再引入）。
    /// 失败即停沿用既有失败点。
    static func prepareGuestRun(project: NXProject) -> GuestRunPreparation {
        let bundleID = project.projectConfig.bundleid ?? ""
        guard !bundleID.isEmpty else {
            return GuestRunPreparation(ok: false,
                                       message: "guest 工程bundle id 缺失（Project.plist NXBundleIdentifier）",
                                       entitlementBits: "-",
                                       bundleID: bundleID,
                                       detail: "prepare 细目：[b 未达——工程 bundle id 缺失]")
        }
        // 【N9 修】运行路线签名材料双轨制：私钥=用户导入 p12+密码
        //（CertificateStore——官方同构：LCUtils 的 certificateData/
        // certificatePassword 同为用户导入形态）；profile=宿主本体嵌入的
        // embedded.mobileprovision（官方 LCUtils.m:95-96 原样语义——
        // iLoader 重签宿主时嵌入的开发档 profile，TeamId 与宿主 id 同
        // 体系）。用户导入 profile 不再参与运行路线（交付路线零改动）。
        guard let p12 = CertificateStore.loadCertificateData(),
              let password = CertificateStore.loadPassword() else {
            return GuestRunPreparation(ok: false,
                                       message: "未配置签名私钥——guest 容器签名需要 p12+密码（设置→签名证书；运行路线 profile 取宿主本体嵌入档，无需用户描述文件）",
                                       entitlementBits: "-",
                                       bundleID: bundleID,
                                       detail: "prepare 细目：[b 未达——签名私钥未配置]")
        }
        // 宿主 embedded.mobileprovision 缺失=独立失败态（重签工具未嵌入）
        guard let embeddedProfileURL = Bundle.main.url(
                  forResource: "embedded", withExtension: "mobileprovision"),
              let hostProfile = try? Data(contentsOf: embeddedProfileURL),
              !hostProfile.isEmpty else {
            return GuestRunPreparation(ok: false,
                                       message: "宿主本体未嵌入描述文件（embedded.mobileprovision 缺失或不可读）——运行路线要求宿主带开发档 profile；请用重签工具重装宿主",
                                       entitlementBits: "-",
                                       bundleID: bundleID,
                                       detail: "prepare 细目：[b 未达——宿主 embedded.mobileprovision 缺失]")
        }

        var segments: [String] = []
        let machoPath = project.machoURL.path

        // ① 补片（官方 LCUtils.signAppBundleWithZSign 补片段等义）——步骤 a
        do {
            try GuestRunSupport.patchGuestExecutable(
                atPath: machoPath,
                bundleURL: project.bundleURL)
            segments.append("[a 补片 OK]")
        } catch {
            segments.append("[a 补片 失败]")
            return Self.guestPrepFailure(
                segments: segments,
                step: "a 补片",
                reason: "guest 可执行补片失败（MH_EXECUTE→MH_DYLIB/arm64e fixup）：" + String(describing: error),
                entitlementBits: "-",
                bundleID: bundleID)
        }

        // 步骤 b：宿主实际 bundle id vs 宿主 embedded profile 解析 app-id
        // 并列（【N9 修】profile 改宿主本体嵌入档——两 id 同体系=一致健康；
        // 候选①身份链错配时此处一目了然）。
        let hostBundleID = Bundle.main.bundleIdentifier ?? "未知"
        var profileAppID = "解析失败（Entitlements.application-identifier 不可得）"
        if let parsed = Self.bundleIdFromProfile(hostProfile) {
            if parsed.isWildcard {
                profileAppID = parsed.bundleId + "（通配）"
            } else {
                profileAppID = parsed.bundleId
            }
        }
        segments.append("[b 宿主id=" + hostBundleID + " | 宿主embedded profile app-id=" + profileAppID + "]")

        // ② 容器模式 ZSign（官方 Builder.swift:301 同款 semaphore 形态）——步骤 c
        ZSigner.wanwo_setHostIdentityOverride(true)
        let semaphore = DispatchSemaphore(value: 0)
        var signOK = false
        var signMessage = ""
        var signPartial = false
        _ = ZSigner.sign(withAppPath: project.bundleURL.path,
                         prov: hostProfile, key: p12, pass: password,
                         completionHandler: { success, error in
            if success {
                if let err = error, !err.localizedDescription.isEmpty {
                    signOK = true
                    signPartial = true
                    signMessage = "签名完成，但部分文件签名失败（产物可能不可用）：" + err.localizedDescription
                } else {
                    signOK = true
                    signMessage = "容器签名完成（identifier=宿主身份，LC 容器模式）"
                }
            } else {
                signOK = false
                signMessage = "容器签名失败：" + (error?.localizedDescription ?? "未知错误")
            }
            semaphore.signal()
        })
        semaphore.wait()
        // 签名完复位（run 路径专用——标准交付路径默认 NO 不受影响）
        ZSigner.wanwo_setHostIdentityOverride(false)
        guard signOK else {
            segments.append("[c 容器签名 失败 err=" + signMessage + "]")
            return Self.guestPrepFailure(
                segments: segments,
                step: "c 容器签名",
                reason: signMessage,
                entitlementBits: "-",
                bundleID: bundleID)
        }
        // （S1 签名自查已回退——2026-10-20 真机 CS_KILL 雷区：S1 的
        //  F_ADDFILESIGS 让内核装载校验该文件签名后，同进程 macho_after_sign
        //  修改文件，cd_hash mmap 触页即 Invalid Page 击杀本进程。禁再引入。）
        var cSeg = "[c 容器签名 OK"
        if signPartial {
            // signFailedFiles 非空=签名静默失败直接证据（N7c 二轮同族——
            // zsign.mm:121 对非空仍回 YES），如实透出。
            cSeg = "[c 容器签名 OK(err=" + signMessage + ")"
        }
        cSeg = cSeg + "]"
        segments.append(cSeg)

        // ③ NXTR token（官方 Builder.swift:304-307 同序）——步骤 d
        // （NSMutableDictionary → [AnyHashable: Any] 直标不可转——桥接经
        //  NSDictionary 条件转换，run 39368919449 实证）
        let plistDict: NSDictionary = project.entitlementsConfig.dictionary
        let bits = GuestRunSupport.entitlementBits(
            fromEntitlementsPlist: plistDict as? [AnyHashable: Any] ?? [:])
        let bitsHex = "0x" + String(bits, radix: 16)
        do {
            try GuestRunSupport.appendEntitlementToken(
                atPath: machoPath,
                entitlement: PEEntitlement(rawValue: bits))
        } catch {
            segments.append("[d token 失败]")
            return Self.guestPrepFailure(
                segments: segments,
                step: "d token 追加",
                reason: "NXTR token 追加失败：" + String(describing: error),
                entitlementBits: bitsHex,
                bundleID: bundleID)
        }
        // （S2 签名自查已回退——同上 CS_KILL 雷区，禁再引入。）
        segments.append("[d token OK]")

        // ④ 安装（官方 Builder.swift:315 同义——经 GuestRunSupport 自有
        //    包装区分 reply(NO)/2s 超时/XPC 错误回调）——步骤 e
        var installError: NSError?
        let installResult = GuestRunSupport.installApplication(
            atPath: project.bundleURL.path,
            error: &installError)
        if installResult != .installed {
            segments.append("[e install=" + Self.installResultText(installResult) + "]")
            return Self.guestPrepFailure(
                segments: segments,
                step: "e installApplication",
                reason: Self.installShallowCause(installResult, installError),
                entitlementBits: bitsHex,
                bundleID: bundleID)
        }

        segments.append("[e install=installed]")
        let detail = "prepare 细目：" + segments.joined(separator: " ")
        // 【N9 装后通知层修复（L2 实锤轮）】成功消息带实际注册 id：容器模式
        // 不改写磁盘 Info.plist（buildService 细目 b/c 段实证链），daemon 按
        // 磁盘 Info.plist 的 CFBundleIdentifier 注册——实际注册 id=工程 id，
        // spawn 段（GuestRunService.spawnRun 的 bundleID=prep.bundleID，
        // BuildTools.swift :785）直接使用本值，传参链自洽。
        let installedMessage = signMessage + "；token " + bitsHex
            + "；guest 已安装（bundle id=" + bundleID
            + "，daemon 侧实际注册 id=磁盘 Info.plist id——容器模式不改写，spawn 段按此 id 查找）"
        return GuestRunPreparation(ok: true,
                                   message: installedMessage,
                                   entitlementBits: bitsHex,
                                   bundleID: bundleID,
                                   detail: detail)
    }

    // MARK: N10c · utility 终端路线签名编排（官方 Builder.swift:358-373 对齐）

    struct UtilityRunPreparation {
        let ok: Bool
        let message: String
        /// fastpath 安装后的 daemon 侧路径（NXWindowSessionTerminal 的
        /// PEExecutablePath——官方 Builder.swift:366-368 同源取法）。
        let utilityPath: String
        /// prepare 细目（a-d 步骤结构化诊断——GuestRunPreparation 同款）。
        let detail: String
    }

    /// 官方 .run utility 签名编排等义（0.10.3 Builder.swift:358-373 逐段；
    /// 与 app 路线 prepareGuestRun 并列、互不污染——utility 无 .app bundle，
    /// 无容器 ZSign/installApplication 面）。调用前提：build(.export) 已成功
    /// （utility 的 machoURL = NXOutputPath=$(CACHEROOT)/$(NXExecutable)——
    /// NXProject.m:281/:514 官方同款取法）。步骤（官方顺序，逐段）：
    ///   ① 补片（LCUtils.signMachOAtURL 补片段——单 macho LCPatchExecSlice，
    ///      无 bundle arm64e fixup——GuestRunSupport 薄壳）；
    ///   ② 单 macho ZSign（LCUtils.signMachOAtURL 签名段等义：prov=宿主
    ///      embedded profile + 私钥=用户导入 p12+密码——万我双轨制同 app
    ///      运行路线；wanwo_setHostIdentityOverride 为 bundle 身份覆写开关，
    ///      单 macho 无 bundle 面不参与）；
    ///   ③ NXTR token（官方 Builder.swift:364 同序——macho_after_sign）；
    ///   ④ fastpathUtility（官方 Builder.swift:366 同义——daemon 复制+签名，
    ///      返回运行路径=PEExecutablePath）。
    /// S1/S2 签名自查不引入（N9 CS_KILL 雷区——见 §N9「S1/S2 回退」）。
    static func prepareUtilityRun(project: NXProject) -> UtilityRunPreparation {
        let machoPath = project.machoURL.path
        // 证书三件门（运行路线双轨制同 app：私钥=用户导入 p12+密码——
        // CertificateStore；prov=宿主本体嵌入 embedded.mobileprovision——
        // 官方 LCUtils.signMachOAtURL:126-127 同源取法）。
        guard let p12 = CertificateStore.loadCertificateData(),
              let password = CertificateStore.loadPassword() else {
            return UtilityRunPreparation(ok: false,
                                         message: "未配置签名私钥——utility 签名需要 p12+密码（设置→签名证书）",
                                         utilityPath: "",
                                         detail: "prepare 细目：[未达——签名私钥未配置]")
        }
        guard let embeddedProfileURL = Bundle.main.url(
                  forResource: "embedded", withExtension: "mobileprovision"),
              let hostProfile = try? Data(contentsOf: embeddedProfileURL),
              !hostProfile.isEmpty else {
            return UtilityRunPreparation(ok: false,
                                         message: "宿主本体未嵌入描述文件（embedded.mobileprovision 缺失或不可读）——utility 运行路线要求宿主带开发档 profile；请用重签工具重装宿主",
                                         utilityPath: "",
                                         detail: "prepare 细目：[未达——宿主 embedded.mobileprovision 缺失]")
        }

        var segments: [String] = []

        // ① 补片（官方 LCUtils.signMachOAtURL 补片段等义）——步骤 a
        do {
            try GuestRunSupport.patchGuestExecutableOnly(atPath: machoPath)
            segments.append("[a 补片 OK]")
        } catch {
            segments.append("[a 补片 失败]")
            return Self.utilityPrepFailure(segments: segments,
                                           reason: "utility 可执行补片失败（MH_EXECUTE→MH_DYLIB/arm64）："
                                               + String(describing: error))
        }

        // ② 单 macho ZSign（官方 signMachOAtURL 签名段等义）——步骤 b
        do {
            try GuestRunSupport.signUtilityMachO(atPath: machoPath,
                                                 prov: hostProfile,
                                                 key: p12,
                                                 pass: password)
            segments.append("[b 单macho签名 OK]")
        } catch {
            segments.append("[b 单macho签名 失败]")
            return Self.utilityPrepFailure(segments: segments,
                                           reason: "utility ZSign 签名失败：" + String(describing: error))
        }

        // ③ NXTR token（官方 Builder.swift:364 同序）——步骤 c
        // （NSMutableDictionary → [AnyHashable: Any] 直标不可转——桥接经
        //  NSDictionary 条件转换，run 39368919449 实证）
        let plistDict: NSDictionary = project.entitlementsConfig.dictionary
        let bits = GuestRunSupport.entitlementBits(
            fromEntitlementsPlist: plistDict as? [AnyHashable: Any] ?? [:])
        let bitsHex = "0x" + String(bits, radix: 16)
        do {
            try GuestRunSupport.appendEntitlementToken(
                atPath: machoPath,
                entitlement: PEEntitlement(rawValue: bits))
        } catch {
            segments.append("[c token 失败]")
            return Self.utilityPrepFailure(segments: segments,
                                           reason: "NXTR token 追加失败：" + String(describing: error))
        }
        segments.append("[c token OK " + bitsHex + "]")

        // ④ fastpathUtility（官方 Builder.swift:366 同义——daemon 复制+签名，
        //    2s 超时=官方硬编码）——步骤 d
        let fastPath = LDEApplicationWorkspace.shared().fastpathUtility(machoPath)
        guard let fastPath = fastPath, !fastPath.isEmpty else {
            segments.append("[d fastpath 失败]")
            return Self.utilityPrepFailure(segments: segments,
                                           reason: "fastpathUtility 失败（daemon 未复制/未签名/2s 超时——installd 存活态 pe_smoke mode=status）")
        }
        segments.append("[d fastpath OK]")

        let detail = "prepare 细目：" + segments.joined(separator: " ")
        let okMessage = "utility 签名/token/fastpath 全通过；daemon 侧运行路径=" + fastPath
        return UtilityRunPreparation(ok: true,
                                     message: okMessage,
                                     utilityPath: fastPath,
                                     detail: detail)
    }

    /// utility prepare 失败汇总（guestPrepFailure 同构——无 bundleID/位图位）。
    private static func utilityPrepFailure(segments: [String],
                                           reason: String) -> UtilityRunPreparation {
        var detail = "prepare 细目：" + segments.joined(separator: " ")
        detail = detail + "；失败点（浅因：" + reason + "）"
        return UtilityRunPreparation(ok: false,
                                     message: detail,
                                     utilityPath: "",
                                     detail: detail)
    }

    // MARK: N9d · prepare 细目组装辅助（平铺——swiftc 雷区纪律：无嵌套函数）

    /// prepare 失败汇总：细目（已完成步骤 + 失败步骤标记）+ 失败点浅因。
    private static func guestPrepFailure(segments: [String],
                                         step: String,
                                         reason: String,
                                         entitlementBits: String,
                                         bundleID: String) -> GuestRunPreparation {
        var detail = "prepare 细目：" + segments.joined(separator: " ")
        detail = detail + "；失败点：" + step + "（浅因：" + reason + "）"
        return GuestRunPreparation(ok: false,
                                   message: detail,
                                   entitlementBits: entitlementBits,
                                   bundleID: bundleID,
                                   detail: detail)
    }

    private static func installResultText(_ result: WanWoGuestInstallResult) -> String {
        switch result {
        case .installed: return "installed"
        case .rejected: return "rejected"
        case .timeout: return "timeout"
        case .xpcError: return "xpcError"
        case .noConnection: return "noConnection"
        case .invalidInput: return "invalidInput"
        @unknown default: return "unknown(" + String(result.rawValue) + ")"
        }
    }

    /// install 失败浅因（候选指向：rejected→①身份链错配/解压；timeout→④
    /// XPC 2s 超时；其余按包装错误文案如实透出）。
    private static func installShallowCause(_ result: WanWoGuestInstallResult,
                                            _ error: NSError?) -> String {
        switch result {
        case .rejected:
            return "installd 明确回绝（reply=NO——信任校验/解压失败，非超时；候选①身份链错配高概率：对照 b 段宿主 id 与 profile app-id）"
        case .timeout:
            return "2s XPC 超时（installd 无响应——daemon 未起/忙/解压超 2s；候选④）"
        case .xpcError:
            return "XPC 错误回调：" + (error?.localizedDescription ?? "未知")
                + "（【N9 装后通知层修复（L2 实锤轮）】后 install 连接已挂 observer + 导出面=LDEApplicationWorkspaceProtocol——残余 xpcError 属意外态，按连接层态排查：installd daemon 存活态 pe_smoke mode=status）"
        case .noConnection:
            return "XPC 连接不可达（endpoint/proxy 缺失——installd daemon 未起？pe_smoke mode=status）"
        case .invalidInput:
            return "安装入参/archive 构造失败：" + (error?.localizedDescription ?? "未知")
        default:
            return error?.localizedDescription ?? "未知安装失败"
        }
    }

    /// 【N9b】run 在途时同样拒绝（run 期间禁新 build——build_and_run 全
    /// 生命周期持有 run 门，build_ipa 与之互斥；stop_build 在 run 态下转
    /// 语义为终止 guest 并放行）。
    func beginBuild() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if inFlight || runInFlight { return false }
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

    // MARK: N9b · guest run 门（与构建门同锁、互斥语义）

    /// run 门（build_and_run 全生命周期持有：build→容器签名→token→安装→
    /// spawn→退出码收尾）。run 期间 beginBuild 拒绝（run 中禁新 build，
    /// N9 方案 §三 7 拍板语义）；beginRun 拒绝并发 run 与并发 build。
    /// stop_build 在 run 态下由工具层转语义（终止 guest→endRun）。
    func beginRun() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if inFlight || runInFlight { return false }
        runInFlight = true
        return true
    }

    func endRun() {
        lock.lock(); defer { lock.unlock() }
        runInFlight = false
    }

    var isRunInFlight: Bool {
        lock.lock(); defer { lock.unlock() }
        return runInFlight
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
