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

    /// 官方全链构建（.export）。completion 在 MDK 线程池线程回调。
    func build(project: NXProject, completion: @escaping (BuildResult) -> Void) {
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

            let buildResult = BuildResult(
                success: result,
                projectName: project.projectConfig.displayName ?? "Unknown",
                projectURL: project.url,
                bundleURL: project.bundleURL,
                machoURL: project.machoURL,
                ipaURL: project.packageURL,
                buildLogPath: project.cacheURL.appendingPathComponent("debug.json").path,
                diagnosticsSummary: summary.isEmpty ? "（无诊断条目）" : summary,
                elapsedSeconds: elapsed)
            _ = self // BuildService 无状态依赖；保留 weak 形态防环
            completion(buildResult)
        }
    }
}

// MARK: - 错误

enum BuildServiceError: Error, CustomStringConvertible {
    case createFailed(name: String)
    case projectNotFound(name: String)
    case fileEscapesProject(name: String, file: String)

    var description: String {
        switch self {
        case .createFailed(let name):
            return "createProject failed for \"\(name)\"（脚手架/模板阶段失败）"
        case .projectNotFound(let name):
            return "project \"\(name)\" not found（先 project_create 或核对 project_list）"
        case .fileEscapesProject(let name, let file):
            return "path \"\(file)\" escapes project \"\(name)\"（拒绝越界访问）"
        }
    }
}
