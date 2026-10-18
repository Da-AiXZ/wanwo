//
//  BuildTools.swift
//  WanWo
//
//  【N6 · BuildExt 工具面】13 号设计环 N6：6 件 AgentTool（build_and_run 属
//  阶段 2——WANWO_BUILD_RUN 开启时随 N7-N9 注册）。装配点 AppEnvironment
//  makeAgentStack（BuildTools.registerAll，writer 注入供 extensionEvent）。
//
//  审批：build_ipa 走 ctx.escalationApprover 提权呈现缝（browser_use 同一
//  ApprovalCoordinator.request 呈现；nil approver → fail closed）。其余低危。
//
//  诊断双去向（设计文档 §三）：① DebugDatabase（vendored 件原样持久化）；
//  ② build_ipa 工具输出直给 AI（同回合自修复）+ extensionEvent("build",
//  modelVisible) 持久化（跨回合 replay——AI 下一回合读到编译错误闭环）。
//

import Foundation

// MARK: - 事件注册（M7 件 A 同款装配期幂等）

enum BuildEvents {
    static let eventKind = "build"

    /// 装配期注册（幂等；AppEnvironment.makeAgentStack 调用）。
    static func register() {
        let registry = ExtensionEventRegistry.shared
        guard !registry.isRegistered(eventKind) else { return }
        registry.register(ExtensionEventSchema(
            kind: eventKind,
            requiredFields: [
                ExtensionFieldSchema("name", .string),
                ExtensionFieldSchema("result", .string),      // "success" | "failure"
                ExtensionFieldSchema("phase", .string),       // "export"
                ExtensionFieldSchema("elapsed", .string),
                ExtensionFieldSchema("ipaURL", .string),
                ExtensionFieldSchema("diagnostics", .string), // 摘要（截断）
            ],
            projection: .modelVisible))
    }
}

// MARK: - 工具族装配

enum BuildTools {
    /// 注册 5 件（project_create/project_list/project_read/build_ipa/build_log/
    /// stop_build——build_and_run 属阶段 2）。writer 注入供 build 事件发射。
    static func registerAll(into registry: ToolRegistry,
                            sessionId: String,
                            writer: SessionWriter,
                            sessionCwd: String?) {
        registry.register(ProjectCreateTool(writer: writer, sessionCwd: sessionCwd))
        registry.register(ProjectListTool())
        registry.register(ProjectReadTool())
        registry.register(BuildIPATool(writer: writer, sessionCwd: sessionCwd))
        registry.register(BuildLogTool())
        registry.register(StopBuildTool())
    }

    /// guest bash 视角路径提示（会话桶在 guest 侧的挂载点=sessionCwd）——
    /// 真机实证：project_create 只回宿主路径时 AI 用 bash 盲试 6 次找工程。
    static func guestPathHint(_ hostPath: String, workspaceRoot: URL, sessionCwd: String?) -> String {
        let root = workspaceRoot.standardizedFileURL.path
        let host = URL(fileURLWithPath: hostPath).standardizedFileURL.path
        guard host.hasPrefix(root + "/") || host == root else { return "" }
        let rel = String(host.dropFirst(root.count))
        return "\nguest bash path: \(sessionCwd ?? "/var/wanwo/projects/<session>")\(rel)（guest 内 ls/cat 可见）"
    }
}

// MARK: - 共用执行底座

/// 工具 → BuildService 的桥（workspace 根解析/工程定位/路径安全）。
enum BuildToolSupport {

    /// 工程定位：name → 最新 UUID 工程目录的 NXProject。
    static func resolveProject(workspace: WorkspaceFileAccess,
                               name: String) throws -> NXProject {
        // 空名/含分隔符会使 nameDir 退化为根目录（真机实证："" → 解析成
        // "最新工程"触发 0.0s 垃圾构建，压测报告 D9）——fail closed。
        guard !name.isEmpty, !name.contains("/"), name != "." , name != ".." else {
            throw BuildServiceError.projectNotFound(name: name)
        }
        let projectsRoot = BuildService.projectsRoot(inWorkspace: workspace.rootURL)
        let nameDir = projectsRoot.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: nameDir.path),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: nameDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
              let latest = entries.max(by: {
                  BuildService.modificationDate(of: $0) < BuildService.modificationDate(of: $1)
              }),
              let project = NXProject(url: latest) else {
            throw BuildServiceError.projectNotFound(name: name)
        }
        return project
    }

    /// 路径安全：file 必须落在工程目录内（防 ../ 逃逸——WorkspaceFileAccess
    /// 同款 fail-closed 纪律）。
    static func safeFileURL(inProject project: NXProject, file: String) throws -> URL {
        let root = project.url.standardizedFileURL
        let target = root.appendingPathComponent(file).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") || target.path == root.path else {
            throw BuildServiceError.fileEscapesProject(
                name: project.projectConfig.displayName ?? "?", file: file)
        }
        return target
    }
}

// MARK: - project_create（低危）

struct ProjectCreateTool: AgentTool {
    let name = "project_create"
    let description = "Create (or reuse) a build project in the session workspace. "
        + "Scaffolds Config/Project.plist + Entitlements + SwiftUI template sources via the vendored official factory. "
        + "Write your source files into the returned project directory with the fs tools, then call build_ipa."
    let parameters = JSONValue.schemaObject(
        properties: [
            "name": .stringSchema(description: "Project name (alphanumeric; used as directory name and executable name)."),
        ],
        required: ["name"])

    private let writer: SessionWriter
    private let sessionCwd: String?
    init(writer: SessionWriter, sessionCwd: String?) {
        self.writer = writer
        self.sessionCwd = sessionCwd
    }

    func isConcurrencySafe(_ args: JSONValue) -> Bool { false }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let name = args.objectValue?["name"]?.stringValue,
              !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            // 真机实证：非 ASCII 名（如"计算器"）编译过但 ld64.lld 链接失败。
            let hint = "ASCII letters/numbers only (used as dir/executable/linker module name). "
                + "Chinese display name: edit NXDisplayName in Config/Project.plist after create."
            return .failure("missing/invalid \"name\". " + hint, code: "INVALID_ARGS")
        }
        do {
            let (project, created) = try BuildService.shared.createOrReuseProject(
                workspaceRoot: ctx.workspace.rootURL, name: name,
                interfaceKind: NXProjectInterfaceKind.swiftUI)
            let note = created ? "created" : "reused (existing project with same name)"
            let sources = (try? FileManager.default.contentsOfDirectory(
                at: project.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
                .map { $0.map(\.lastPathComponent).sorted().joined(separator: ", ") } ?? "-"
            let guestHint = BuildTools.guestPathHint(project.url.path, workspaceRoot: ctx.workspace.rootURL,
                                               sessionCwd: sessionCwd)
            return .success("""
                project \(note): \(name)
                project dir: \(project.url.path)\(guestHint)
                sources: \(sources)
                Next: write/overwrite .swift files in this directory with the fs tools (fs 工具用 project dir 宿主路径；bash 用 guest bash path), then call build_ipa(name: "\(name)").
                """)
        } catch {
            return .failure(String(describing: error), code: "CREATE_FAILED", name: "BuildError")
        }
    }
}

// MARK: - project_list（低危）

struct ProjectListTool: AgentTool {
    let name = "project_list"
    let description = "List build projects in the session workspace (name, executable, bundle id, deployment target)."
    let parameters = JSONValue.schemaObject(properties: [:], required: [])

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        let projects = BuildService.shared.listProjects(workspaceRoot: ctx.workspace.rootURL)
        if projects.isEmpty {
            return .success("（无工程——先 project_create）")
        }
        let lines = projects.map { item -> String in
            let cfg = item.config
            return "- \(item.name)  exec=\(cfg?.executable ?? "?")  bundle=\(cfg?.bundleid ?? "?")  target=\(cfg?.deploymentTarget ?? "?")\n  \(item.url.path)"
        }
        return .success(lines.joined(separator: "\n"))
    }
}

// MARK: - project_read（低危）

struct ProjectReadTool: AgentTool {
    let name = "project_read"
    let description = "Read a file inside a build project (path relative to the project directory). "
        + "For writing source files prefer the fs tools with the project directory path returned by project_create."
    let parameters = JSONValue.schemaObject(
        properties: [
            "name": .stringSchema(description: "Project name."),
            "file": .stringSchema(description: "File path relative to the project directory (e.g. \"ContentView.swift\")."),
        ],
        required: ["name", "file"])

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let name = args.objectValue?["name"]?.stringValue,
              let file = args.objectValue?["file"]?.stringValue else {
            return .failure("missing \"name\"/\"file\"", code: "INVALID_ARGS")
        }
        do {
            let project = try BuildToolSupport.resolveProject(workspace: ctx.workspace, name: name)
            let fileURL = try BuildToolSupport.safeFileURL(inProject: project, file: file)
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            return .success(text)
        } catch let e as BuildServiceError {
            return .failure(e.description, code: "PROJECT_ERROR", name: "BuildError")
        } catch {
            return .failure(String(describing: error), code: "READ_FAILED")
        }
    }
}

// MARK: - build_ipa（危险级：审批 + 单飞行）

struct BuildIPATool: AgentTool {
    let name = "build_ipa"
    let description = "Build the project into an ipa (full official pipeline: swiftc compile → link → Payload package). "
        + "Requires user approval (ask once). Returns build result with diagnostics — fix errors and rebuild."
    let parameters = JSONValue.schemaObject(
        properties: [
            "name": .stringSchema(description: "Project name to build."),
        ],
        required: ["name"])

    private let writer: SessionWriter
    private let sessionCwd: String?
    init(writer: SessionWriter, sessionCwd: String?) {
        self.writer = writer
        self.sessionCwd = sessionCwd
    }

    /// 编译占线程池与缓存目录——exclusive 车道串行。
    func isConcurrencySafe(_ args: JSONValue) -> Bool { false }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let name = args.objectValue?["name"]?.stringValue else {
            return .failure("missing \"name\"", code: "INVALID_ARGS")
        }

        // 审批（危险级 askOnce——提权呈现缝，browser_use 同一呈现；nil → fail closed）
        if let approver = ctx.escalationApprover {
            let outcome = await approver("build_ipa", ctx.callId,
                                         "编译工程 \"\(name)\" 为 ipa（占用设备 CPU 数分钟）")
            guard outcome == .allowedOnce else {
                return .failure("user did not approve the build (outcome: \(outcome.rawValue))",
                                code: "BUILD_NOT_APPROVED", name: "BuildError")
            }
        } else {
            return .failure("no approval service available（fail closed）",
                            code: "BUILD_NOT_APPROVED", name: "BuildError")
        }

        // 单飞行门
        guard BuildService.shared.beginBuild() else {
            return .failure("another build is already in flight（等待其结束或 stop_build 后重试）",
                            code: "BUILD_IN_FLIGHT", name: "BuildError")
        }
        defer { BuildService.shared.endBuild() }

        let project: NXProject
        do {
            project = try BuildToolSupport.resolveProject(workspace: ctx.workspace, name: name)
        } catch let e as BuildServiceError {
            return .failure(e.description, code: "PROJECT_ERROR", name: "BuildError")
        } catch {
            return .failure(String(describing: error), code: "PROJECT_ERROR")
        }

        // 官方全链（MDK 线程池；阻塞本工具车道直到完成）
        let result: BuildResult = await withCheckedContinuation { cont in
            BuildService.shared.build(project: project) { r in
                cont.resume(returning: r)
            }
        }

        // 诊断双去向 ②：build 事件持久化（modelVisible——AI 下一回合读到）
        let eventPayload: JSONValue = .object([
            "name": .string(name),
            "result": .string(result.success ? "success" : "failure"),
            "phase": .string("export"),
            "elapsed": .string(String(format: "%.1fs", result.elapsedSeconds)),
            "ipaURL": .string(result.ipaURL.path),
            "diagnostics": .string(String(result.diagnosticsSummary.prefix(2000))),
        ])
        _ = try? await writer.append(.extensionEvent(
            kind: BuildEvents.eventKind,
            payload: eventPayload))

        if result.success {
            let guestHint = BuildTools.guestPathHint(result.ipaURL.path, workspaceRoot: ctx.workspace.rootURL,
                                               sessionCwd: sessionCwd)
            var sizeText = "-"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: result.ipaURL.path),
               let size = attrs[.size] as? NSNumber {
                sizeText = ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
            }
            // 【压测报告 D1】ipa 复制进会话工作区桶 BuildArtifacts/——guest/文件
            // App/fs 工具立即可取（真机实证：Cache 在 guest/工作区视图均不可见，
            // "构建成功"只能信返回值）。
            var artifactPath: String? = nil
            if FileManager.default.fileExists(atPath: result.ipaURL.path) {
                let artDir = ctx.workspace.rootURL.appendingPathComponent("BuildArtifacts", isDirectory: true)
                try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
                let dst = artDir.appendingPathComponent(result.projectName + ".ipa")
                try? FileManager.default.removeItem(at: dst)
                if (try? FileManager.default.copyItem(at: URL(fileURLWithPath: result.ipaURL.path), to: dst)) != nil {
                    artifactPath = dst.path
                }
            }
            let artifactLine = artifactPath.map { "\nworkspace ipa: \($0)（文件 App/读工具可直取）" } ?? ""
            return .success("""
                BUILD OK（\(String(format: "%.1fs", result.elapsedSeconds))）· ipa 大小 \(sizeText)
                ipa: \(result.ipaURL.path)\(guestHint)\(artifactLine)
                bundle(.app, N7 签名/N9 guest 取用): \(result.bundleURL.path)
                project: \(result.projectURL.path)
                diagnostics: \(result.diagnosticsSummary)
                """)
        } else {
            return .failure("""
                BUILD FAILED（\(String(format: "%.1fs", result.elapsedSeconds))）
                —— 按以下诊断修复源码后重新 build_ipa：
                \(result.diagnosticsSummary)
                build log: \(result.buildLogPath)
                """, code: "BUILD_FAILED", name: "BuildError")
        }
    }
}

// MARK: - build_log（低危）

struct BuildLogTool: AgentTool {
    let name = "build_log"
    let description = "Read the full structured build diagnostics (debug.json) of a project."
    let parameters = JSONValue.schemaObject(
        properties: ["name": .stringSchema(description: "Project name.")],
        required: ["name"])

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let name = args.objectValue?["name"]?.stringValue else {
            return .failure("missing \"name\"", code: "INVALID_ARGS")
        }
        do {
            let project = try BuildToolSupport.resolveProject(workspace: ctx.workspace, name: name)
            let db = DebugDatabase.getDatabase(
                ofPath: project.cacheURL.appendingPathComponent("debug.json").path)
            // 【0.0s 透明化 2026-10-18】原此处调 db.reuseDatabase()——读取前把
            // Internal 桶清空，而 init/运行失败诊断恰在 Internal 桶（BuildSmoke
            // 0.0s 实证：build_log 永远「无诊断条目」）。删除之——build_log 现在
            // 能看到初始化/运行失败的 Internal 条目（官方 NXBuilder init 每轮
            // 构建开始仍会重置 Internal，历史不跨构建累积）。
            let items = db.debugObjects.values.flatMap(\.debugItems)
            if items.isEmpty { return .success("（无诊断条目）") }
            let lines = items.map { "[\($0.severity)] \($0.message)" }
            return .success(lines.joined(separator: "\n"))
        } catch let e as BuildServiceError {
            return .failure(e.description, code: "PROJECT_ERROR", name: "BuildError")
        } catch {
            return .failure(String(describing: error), code: "LOG_FAILED")
        }
    }
}

// MARK: - stop_build（低危）

struct StopBuildTool: AgentTool {
    let name = "stop_build"
    let description = "Release the build slot if a build finished abnormally. "
        + "Note: an in-flight build cannot be interrupted (official NXBuilder has no cancel API) — this only clears a stale slot."
    let parameters = JSONValue.schemaObject(properties: [:], required: [])

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        BuildService.shared.endBuild()
        return .success("构建槽位已复位（说明：编译进行中无法中途取消——官方构建器无取消接口；本操作仅用于异常残留后放行下一次构建）")
    }
}
