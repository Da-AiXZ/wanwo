//
//  BuildTools.swift
//  WanWo
//
//  【N6 · BuildExt 工具面】13 号设计环 N6：8 件 AgentTool（批 2 增补
//  project_delete/project_reset + build_ipa optimize/宏预检；build_and_run
//  属阶段 2——WANWO_BUILD_RUN 开启时随 N7-N9 注册）。装配点 AppEnvironment
//  makeAgentStack（BuildTools.registerAll，writer 注入供 extensionEvent）。
//
//  审批：build_ipa/project_delete/project_reset 走 ctx.escalationApprover
//  提权呈现缝（browser_use 同一 ApprovalCoordinator.request 呈现；nil
//  approver → fail closed）。其余低危。
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
    /// 注册 8 件（project_create/project_list/project_read/project_delete/
    /// project_reset/build_ipa/build_log/stop_build——build_and_run 属
    /// 阶段 2）。writer 注入供 build 事件发射。
    static func registerAll(into registry: ToolRegistry,
                            sessionId: String,
                            writer: SessionWriter,
                            sessionCwd: String?) {
        registry.register(ProjectCreateTool(writer: writer, sessionCwd: sessionCwd))
        registry.register(ProjectListTool(sessionCwd: sessionCwd))
        registry.register(ProjectReadTool())
        registry.register(ProjectDeleteTool())
        registry.register(ProjectResetTool(writer: writer, sessionCwd: sessionCwd))
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
            // 【D6 根治】新建工程的目录树补注册 fakefs 元数据（host 直写未经
            // meta.db 注册时 guest ls 不可见——装机审计实锤）；复用路径已注册
            // 过，跳过。
            if created {
                BuildService.registerProjectTreeInFakefs(
                    projectURL: project.url, workspaceRoot: ctx.workspace.rootURL, guestMount: sessionCwd)
            }
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
                Note: external macro plugins are not bundled in this toolchain — #Preview / @Observable / @Model will fail to compile. Use ObservableObject/@Published instead.
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

    private let sessionCwd: String?
    init(sessionCwd: String?) {
        self.sessionCwd = sessionCwd
    }

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        let projects = BuildService.shared.listProjects(workspaceRoot: ctx.workspace.rootURL)
        // 【D6 收尾 2026-10-19】存量工程兜底补注册——建树早于补注册机制的
        // 历史工程（A1 等，装机复测实锤 guest MISSING）在首次 project_list
        // 时自动治好；幂等（ensureFakefsMetadata 内置存在性检查）。
        for item in projects {
            BuildService.registerProjectTreeInFakefs(
                projectURL: item.url, workspaceRoot: ctx.workspace.rootURL, guestMount: sessionCwd)
        }
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

// MARK: - project_delete（危险级：审批——删除工程全部源码）

struct ProjectDeleteTool: AgentTool {
    let name = "project_delete"
    let description = "Delete a build project permanently (all sources, config, and compile cache). "
        + "Use for zombie projects that fail with 0.0s and cannot be recovered by other means. Requires user approval."
    let parameters = JSONValue.schemaObject(
        properties: [
            "name": .stringSchema(description: "Project name to delete."),
        ],
        required: ["name"])

    func isConcurrencySafe(_ args: JSONValue) -> Bool { false }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let name = args.objectValue?["name"]?.stringValue else {
            return .failure("missing \"name\"", code: "INVALID_ARGS")
        }
        // 审批（危险级——删除用户工程不可恢复；nil → fail closed）
        if let approver = ctx.escalationApprover {
            let outcome = await approver("project_delete", ctx.callId,
                                         "删除工程 \"\(name)\"（全部源码/配置/编译缓存，不可恢复）")
            guard outcome == .allowedOnce else {
                return .failure("user did not approve the deletion (outcome: \(outcome.rawValue))",
                                code: "DELETE_NOT_APPROVED", name: "BuildError")
            }
        } else {
            return .failure("no approval service available（fail closed）",
                            code: "DELETE_NOT_APPROVED", name: "BuildError")
        }
        // 构建在途禁删（删目录会让在途构建踩空路径）
        if BuildService.shared.isBuilding {
            return .failure("a build is in flight — delete after it settles（等待构建结束再删）",
                            code: "BUILD_IN_FLIGHT", name: "BuildError")
        }
        do {
            let removed = try BuildService.deleteProjectDirectories(
                workspaceRoot: ctx.workspace.rootURL, name: name)
            let detail = String(removed.projects) + " project dir(s), " + String(removed.caches) + " cache dir(s)"
            return .success("project deleted: " + name + "（" + detail + "）\n"
                + "Next: project_create with the same name rebuilds from scratch, or pick a new name.")
        } catch let e as BuildServiceError {
            return .failure(e.description, code: "PROJECT_ERROR", name: "BuildError")
        } catch {
            return .failure(String(describing: error), code: "DELETE_FAILED")
        }
    }
}

// MARK: - project_reset（危险级：审批——删全部源码重铺脚手架）

struct ProjectResetTool: AgentTool {
    let name = "project_reset"
    let description = "Delete a build project and re-create it from the official scaffold under the SAME name "
        + "(all current sources are lost). For zombie/broken projects whose name you want to keep. Requires user approval."
    let parameters = JSONValue.schemaObject(
        properties: [
            "name": .stringSchema(description: "Project name to reset (re-created empty)."),
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
        guard let name = args.objectValue?["name"]?.stringValue else {
            return .failure("missing \"name\"", code: "INVALID_ARGS")
        }
        // 审批（危险级——重置丢弃现源码；nil → fail closed）
        if let approver = ctx.escalationApprover {
            let outcome = await approver("project_reset", ctx.callId,
                                         "重置工程 \"\(name)\"（删除现源码并重铺官方脚手架，不可恢复）")
            guard outcome == .allowedOnce else {
                return .failure("user did not approve the reset (outcome: \(outcome.rawValue))",
                                code: "RESET_NOT_APPROVED", name: "BuildError")
            }
        } else {
            return .failure("no approval service available（fail closed）",
                            code: "RESET_NOT_APPROVED", name: "BuildError")
        }
        if BuildService.shared.isBuilding {
            return .failure("a build is in flight — reset after it settles（等待构建结束再重置）",
                            code: "BUILD_IN_FLIGHT", name: "BuildError")
        }
        do {
            let removed = try BuildService.deleteProjectDirectories(
                workspaceRoot: ctx.workspace.rootURL, name: name)
            let (project, _) = try BuildService.shared.createOrReuseProject(
                workspaceRoot: ctx.workspace.rootURL, name: name,
                interfaceKind: NXProjectInterfaceKind.swiftUI)
            // 【D6 根治】重铺的脚手架目录树补注册 fakefs 元数据
            BuildService.registerProjectTreeInFakefs(
                projectURL: project.url, workspaceRoot: ctx.workspace.rootURL, guestMount: sessionCwd)
            let sources = (try? FileManager.default.contentsOfDirectory(
                at: project.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
                .map { $0.map(\.lastPathComponent).sorted().joined(separator: ", ") } ?? "-"
            let guestHint = BuildTools.guestPathHint(project.url.path, workspaceRoot: ctx.workspace.rootURL,
                                                     sessionCwd: sessionCwd)
            // 元组成员插值拆局部变量（type-check 超时雷区对策：多行插值串内
            // 只放简单变量——swiftc 6.4 四次实证形态纪律）。
            let removedNote = "removed " + String(removed.projects) + " project dir(s), "
                + String(removed.caches) + " cache dir(s)"
            return .success("""
                project reset: \(name)（\(removedNote)）
                project dir: \(project.url.path)\(guestHint)
                sources: \(sources)
                Note: external macro plugins are not bundled in this toolchain — #Preview / @Observable / @Model will fail to compile. Use ObservableObject/@Published instead.
                Next: write source files (fs 工具用 project dir 宿主路径；bash 用 guest bash path), then call build_ipa(name: "\(name)").
                """)
        } catch let e as BuildServiceError {
            return .failure(e.description, code: "PROJECT_ERROR", name: "BuildError")
        } catch {
            return .failure(String(describing: error), code: "RESET_FAILED")
        }
    }
}

// MARK: - build_ipa（危险级：审批 + 单飞行）

struct BuildIPATool: AgentTool {
    let name = "build_ipa"
    let description = "Build the project into an ipa (full official pipeline: swiftc compile → link → Payload package). "
        + "Pre-checks macros (#Preview/@Observable/@Model are unavailable — build would fail). "
        + "Requires user approval (ask once). Returns build result with diagnostics — fix errors and rebuild."
    let parameters = JSONValue.schemaObject(
        properties: [
            "name": .stringSchema(description: "Project name to build."),
            "optimize": .booleanSchema(description: "Compile with -O (faster runtime, slower compile; persisted in project NXSwiftFlags). Default false."),
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
        let optimize = args.objectValue?["optimize"]?.boolValue ?? false

        // 工程定位提前到审批前（批 2：工程不存在/名字错不必让用户白批一次）
        let project: NXProject
        do {
            project = try BuildToolSupport.resolveProject(workspace: ctx.workspace, name: name)
        } catch let e as BuildServiceError {
            return .failure(e.description, code: "PROJECT_ERROR", name: "BuildError")
        } catch {
            return .failure(String(describing: error), code: "PROJECT_ERROR")
        }

        // 【lld 污染拦截】上次 duplicate symbol 链接失败后 lld 内部残留
        //（dupSymDiags 无 clear，上游疏漏）——同进程再次链接大概率 UAF 闪退
        //（.ips 实锤）。lld 内部静态无法从外部清理：事前拦截+引导重启。
        if BuildService.isLldContaminated {
            return .failure(
                "build service contamination: a previous build in this process failed with duplicate symbols, "
                    + "leaking lld linker state (upstream lld never clears its duplicate diagnostics — "
                    + "re-linking in this process would risk a crash). Ask the user to restart the App "
                    + "(kill and relaunch WanWo), then rebuild — the same build will succeed after restart.",
                code: "LLD_CONTAMINATED", name: "BuildError")
        }

        // 宏预检（压测建议 6）：external macro 官方边界必败（§三 f 实证）——
        // 命中即拦下这次必然失败的构建，省一次审批+数分钟 CPU。
        let macroScan = BuildService.scanMacroUsage(project: project)
        if macroScan.files > 0 {
            var macroMsg = "pre-check: " + String(macroScan.files)
                + " source file(s) use macros unavailable in this toolchain"
                + " (#Preview / @Observable / @Model — external macro plugins are not bundled, official boundary)."
                + " The build would fail on external macro. Remove the macros"
                + " (e.g. ObservableObject/@Published instead of @Observable) and rebuild."
            if !macroScan.samples.isEmpty {
                macroMsg = macroMsg + "\nfiles: " + macroScan.samples.joined(separator: ", ")
            }
            return .failure(macroMsg, code: "MACRO_PRECHECK", name: "BuildError")
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

        // -O 参数化（压测建议 12）：持久写入工程 plist NXSwiftFlags。
        // optimize=false 为显式语义（曾开过则移除，保持参数即真值）。
        var optNote = ""
        do {
            let note = try BuildService.setSwiftOptimization(project: project, enabled: optimize)
            optNote = "\noptimize: " + note
        } catch let e as BuildServiceError {
            return .failure(e.description, code: "PROJECT_ERROR", name: "BuildError")
        } catch {
            return .failure(String(describing: error), code: "OPTIMIZE_FAILED")
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
                    // 【D6 根治】host 直写补注册 fakefs 元数据（meta.db paths 表
                    // =guest 目录视图权威）——否则 guest ls 看不到 BuildArtifacts
                    //（装机审计实锤：fs glob 可见、guest ls 不可见）。
                    if let cwd = sessionCwd {
                        let wsRoot = ctx.workspace.rootURL.standardizedFileURL.path
                        let dstStd = dst.standardizedFileURL.path
                        if dstStd.hasPrefix(wsRoot + "/") {
                            let dstRel = String(dstStd.dropFirst(wsRoot.count))
                            IshExecutorBridge.ensureFakefsMetadata(for: cwd + "/BuildArtifacts", isDirectory: true)
                            IshExecutorBridge.ensureFakefsMetadata(for: cwd + dstRel, isDirectory: false)
                        }
                    }
                }
            }
            let artifactLine = artifactPath.map { "\nworkspace ipa: \($0)（文件 App/读工具可直取）" } ?? ""
            return .success("""
                BUILD OK（\(String(format: "%.1fs", result.elapsedSeconds))）· ipa 大小 \(sizeText)\(optNote)
                ipa: \(result.ipaURL.path)\(guestHint)\(artifactLine)
                bundle(.app, N7 签名/N9 guest 取用): \(result.bundleURL.path)
                project: \(result.projectURL.path)
                diagnostics: \(result.diagnosticsSummary)
                """)
        } else {
            return .failure("""
                BUILD FAILED（\(String(format: "%.1fs", result.elapsedSeconds))）\(optNote)
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
