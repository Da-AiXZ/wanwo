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
            db.reuseDatabase()
            func levelName(_ raw: Int) -> String {
                switch raw { case 3: return "error"; case 2: return "warning"; case 1: return "remark"; default: return "note" }
            }
            // 【N6 压测反馈】诊断可定位化：file:line:col + 路径相对化 +
            // 截断显式（压测 G：40 错静默截断 20 条无提示）。
            let rootPrefix = project.url.standardizedFileURL.path + "/"
            let all = db.debugObjects.values
                .flatMap(\.debugItems)
                .sorted { $0.severity.rawValue > $1.severity.rawValue }
            func render(_ item: DebugItem) -> String {
                var loc = ""
                let sl = item.sourceLocation
                if sl.line > 0 {
                    let file = sl.file.isEmpty ? "" : String(sl.file.dropFirst(rootPrefix.count))
                    loc = "[\(file):\(sl.line):\(sl.column)] "
                }
                return "[\(levelName(item.severity.rawValue))] \(loc)\(item.message)"
                    .replacingOccurrences(
                        of: "/private/var/mobile/Containers/Data/Application/[0-9A-F-]+/Documents/wanwo-build/",
                        with: "wanwo-build/", options: .regularExpression)
            }
            let summary: String
            if all.isEmpty {
                // 【压测 K1】零诊断失败=最贵的失败类型（plist 损坏/init 失败）——
                // 显式指路而非"（无诊断条目）"静默。
                summary = "（零诊断——工程配置解析或构建器初始化失败：检查 Config/Project.plist 的 XML 是否完整有效）"
            } else {
                let shown = all.prefix(50).map(render)
                summary = shown.joined(separator: "\n")
                    + (all.count > 50 ? "\n…（仅显示前 50 条，共 \(all.count) 条——修一批再构建看下一批）" : "")
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
