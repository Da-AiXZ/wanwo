//
//  BuildTools.swift
//  WanWo
//
//  【N6 · BuildExt 工具面】13 号设计环 N6：8 件 AgentTool（批 2 增补
//  project_delete/project_reset + build_ipa optimize/宏预检）。【N9b】新增
//  build_and_run（10 件——guest 承载全链：编译→LC 容器签名→NXTR token→
//  安装→spawn→stdio 回流→退出码收尾；运行编排见 GuestRunService.swift，
//  签名/安装编排见 BuildService.prepareGuestRun）。装配点 AppEnvironment
//  makeAgentStack（BuildTools.registerAll，writer 注入供 extensionEvent）。
//  【N10d · C v2】app 路线重定义：spawn 成功工具立即返回（RunSession 常驻
//  收尾——退出后经 guest_run 事件回报三态退出+输出尾段+run_log 副本）；
//  默认不限时（timeout_ms 可选保护上限）；重复运行报错带活跃 pid 不自动
//  停旧起新；stop_build 语义不变（terminate→收尾段放行 run 门）。
//
//  审批：build_ipa/build_and_run/project_delete/project_reset 走
//  ctx.escalationApprover 提权呈现缝（browser_use 同一 ApprovalCoordinator
//  .request 呈现；nil approver → fail closed）。其余低危。
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
    /// 【N9b】guest run 事件 kind（guest_run）在本装配点同步注册。
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
        RunEvents.register()
    }
}

// MARK: - 工具族装配

enum BuildTools {
    /// 注册 10 件（project_create/project_list/project_read/project_delete/
    /// project_reset/build_ipa/build_log/stop_build/pe_smoke/build_and_run）。
    /// writer 注入供 build 事件发射。
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
        // N8c：运行侧底座冒烟（形态 A——方案拍板项 4；recycle 审批级）
        registry.register(PESmokeTool())
        // N9b：guest 承载全链（编译→容器签名→token→安装→spawn→stdio→退出码）
        registry.register(BuildAndRunTool(writer: writer, sessionCwd: sessionCwd))
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

    /// 【N1】build log 路径行（run_log 工作区副本路径行同款文案模式）：
    /// "build log (workspace copy, AI readable): <路径>"。日志未落盘
    ///（workspaceBuildLogPath 空——未请求/创建失败静默降级）返回空串，
    /// 结果文本不出现该行。
    static func buildLogPathLine(_ result: BuildResult) -> String {
        if result.workspaceBuildLogPath.isEmpty {
            return ""
        }
        return "\nbuild log (workspace copy, AI readable): " + result.workspaceBuildLogPath
    }

    /// 【N1】build 调用日志参数（BuildArtifacts 目录 + 工程名——两工具
    /// 同缝装配，避免调用点重复拼装）。
    static func buildLogArguments(workspaceRoot: URL, projectName: String) -> (directory: URL, name: String) {
        return (workspaceRoot.appendingPathComponent("BuildArtifacts", isDirectory: true), projectName)
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
        + "Scaffolds Config/Project.plist + Entitlements + template sources via the vendored official factory. "
        + "scheme=\"Application\" (default) scaffolds a SwiftUI window app; scheme=\"Utility\" scaffolds an official native "
        + "command-line project (no -parse-as-library in NXSwiftFlags, bare NXOutputPath, no bundle keys) — run it in an "
        + "interactive terminal window via build_and_run. "
        + "Write your source files into the returned project directory with the fs tools, then call build_ipa (Application) "
        + "or build_and_run (Utility)."
    let parameters = JSONValue.schemaObject(
        properties: [
            "name": .stringSchema(description: "Project name (alphanumeric; used as directory name and executable name)."),
            "scheme": .stringSchema(description: "Project scheme: \"Application\" (default, SwiftUI window app) or \"Utility\" (command-line guest run in a terminal window)."),
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
        // 【N10e 修 A】scheme 参数（可选，默认 Application）：仅两值白名单，
        // 其他值 INVALID_ARGS 失败、不静默纠正（scheme 决定模板/flags/输出
        // 路径全表形态——N10d 实锤「App 模板+sed 改 scheme」半改造态三段失败，
        // fail closed）。
        var schemeKind: NXProjectSchemeKind = NXProjectSchemeKind.app
        var schemeName = "Application"
        if let scheme = args.objectValue?["scheme"]?.stringValue {
            if scheme == "Utility" {
                schemeKind = NXProjectSchemeKind.utility
                schemeName = "Utility"
            } else if scheme != "Application" {
                return .failure("invalid \"scheme\": \"\(scheme)\". Allowed values: \"Application\" (default) or \"Utility\" — no other values are accepted.",
                                code: "INVALID_ARGS")
            }
        }
        do {
            let (project, created) = try BuildService.shared.createOrReuseProject(
                workspaceRoot: ctx.workspace.rootURL, name: name,
                schemeKind: schemeKind,
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
            // 【N10e 修 A】scheme 形态+NXOutputPath 模板形态如实报告。复用路径
            // 按工程实际 scheme 报告（同名旧工程 scheme 可能与本次请求不同）。
            var actualSchemeName = "unknown"
            if project.projectConfig.schemeKind == NXProjectSchemeKind.utility {
                actualSchemeName = "Utility"
            } else if project.projectConfig.schemeKind == NXProjectSchemeKind.app {
                actualSchemeName = "Application"
            }
            var schemeLines = "scheme: " + actualSchemeName + "\n"
            var schemeNote = ""
            var nextLine = "Next: write/overwrite .swift files in this directory with the fs tools (fs 工具用 project dir 宿主路径；bash 用 guest bash path), then call build_ipa(name: \"\(name)\")."
            if actualSchemeName == "Utility" {
                schemeLines = schemeLines
                    + "NXOutputPath: $(CACHEROOT)/$(NXExecutable)（官方 utility 裸路径——无 .app bundle/Payload 目录，编译产物即单 macho）\n"
                schemeNote = "Note (Utility): the official utility Swift template is top-level code (import Foundation + print(...)); this toolchain does not add -parse-as-library for Utility+Swift, so top-level statements compile. An @main struct also works.\n"
                    + "【N10e 修 H】utility 终端为 raw 模式（官方终端模拟器语义：无行缓冲/无内核回显）——交互程序需自管回显与行编辑（或逐字节读+写回，参考设备 AI 已验证的自绘回显模式）。\n"
                nextLine = "Next: write/overwrite .swift files in this directory with the fs tools (fs 工具用 project dir 宿主路径；bash 用 guest bash path), then call build_and_run(name: \"\(name)\") — it opens an interactive terminal window."
            }
            var mismatchNote = ""
            if !created && actualSchemeName != schemeName {
                mismatchNote = "Warning: requested scheme=\(schemeName) but the existing project has scheme=\(actualSchemeName) — reused as-is (project_reset to re-scaffold).\n"
            }
            return .success("""
                project \(note): \(name)
                \(mismatchNote)\(schemeLines)\(schemeNote)project dir: \(project.url.path)\(guestHint)
                sources: \(sources)
                Note: external macro plugins are not bundled in this toolchain — #Preview / @Observable / @Model will fail to compile. Use ObservableObject/@Published instead.
                \(nextLine)
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
            // 【批A · U1/P3-8a】产物清理结果进结果文本（ipa + 工程名关联
            // run_log 副本；删除失败静默容忍）。
            let detail = String(removed.projects) + " project dir(s), " + String(removed.caches)
                + " cache dir(s), " + String(removed.artifacts)
                + " artifact file(s) cleaned（BuildArtifacts/<name>.ipa + run_log-<name>-*.txt）"
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
            // 【批A · U1/P3-8a】产物清理结果进结果文本（同 project_delete）。
            let removedNote = "removed " + String(removed.projects) + " project dir(s), "
                + String(removed.caches) + " cache dir(s), "
                + String(removed.artifacts) + " artifact file(s) cleaned"
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
        + "Optionally signs the .app with the imported certificate (sign=true — Settings → Signing Certificate). "
        + "Requires user approval (ask once). Returns build result with diagnostics — fix errors and rebuild."
    let parameters = JSONValue.schemaObject(
        properties: [
            "name": .stringSchema(description: "Project name to build."),
            "optimize": .booleanSchema(description: "Compile with -O (faster runtime, slower compile; persisted in project NXSwiftFlags). Default false."),
            "sign": .booleanSchema(description: "After a successful build, sign the .app with the imported certificate (Settings → Signing Certificate) and repackage the ipa — installable output. Requires a configured certificate; skipped on build failure. Default false."),
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
        let sign = args.objectValue?["sign"]?.boolValue ?? false

        // 【N7c】sign=true 且证书未配置 → 构建前快速失败（不浪费数分钟 CPU
        // 才发现签不了；引导文案指向设置导入）。
        if sign && !CertificateStore.isConfigured {
            return .failure(
                "signing requested but no certificate is configured — ask the user to import "
                    + "p12 + mobileprovision + password in Settings → 签名证书 (Signing Certificate), "
                    + "then rebuild with sign=true.",
                code: "SIGN_NOT_CONFIGURED", name: "BuildError")
        }

        // 工程定位提前到审批前（批 2：工程不存在/名字错不必让用户白批一次）
        let project: NXProject
        do {
            project = try BuildToolSupport.resolveProject(workspace: ctx.workspace, name: name)
        } catch let e as BuildServiceError {
            return .failure(e.description, code: "PROJECT_ERROR", name: "BuildError")
        } catch {
            return .failure(String(describing: error), code: "PROJECT_ERROR")
        }

        // 【批 3 · P3 伪 ipa 拦截】Utility 工程产出=裸 Mach-O（NXOutputPath=
        // $(CACHEROOT)/$(NXExecutable)，无 Payload/.app 目录结构）——打包出
        // 的 .ipa 实为改名裸二进制（实测 cffaedfe 头/unzip short read），误导
        // 性产物。消费形态参照 BuildAndRunTool 的 schemeKind 分叉先例。
        if project.projectConfig.schemeKind == NXProjectSchemeKind.utility {
            return .failure(
                "UTILITY 工程（scheme=Utility）产出为裸可执行文件，不打包 .ipa——"
                    + "用 build_and_run 直接运行；需要分发时改用 Application scheme 工程"
                    + "（project_create scheme=\"Application\"）。",
                code: "UTILITY_NOT_IPA", name: "BuildError")
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
            let actionText = sign ? "编译并签名工程 \"\(name)\" 为 ipa（占用设备 CPU 数分钟；签名用已导入证书）"
                                  : "编译工程 \"\(name)\" 为 ipa（占用设备 CPU 数分钟）"
            let outcome = await approver("build_ipa", ctx.callId, actionText)
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
        // 【N1】构建日志落盘（BuildArtifacts/build-<名>-<HHmmss>.log——
        // 开始建、结束关，路径行随结果文本回传 AI）。
        let logArgs = BuildTools.buildLogArguments(workspaceRoot: ctx.workspace.rootURL, projectName: name)
        let result: BuildResult = await withCheckedContinuation { cont in
            BuildService.shared.build(project: project, sign: sign,
                                      logDirectory: logArgs.directory,
                                      logProjectName: logArgs.name) { r in
                cont.resume(returning: r)
            }
        }

        // 诊断双去向 ②：build 事件持久化（modelVisible——AI 下一回合读到）
        var eventFields: [String: JSONValue] = [
            "name": .string(name),
            "result": .string(result.success ? "success" : "failure"),
            "phase": .string("export"),
            "elapsed": .string(String(format: "%.1fs", result.elapsedSeconds)),
            "ipaURL": .string(result.ipaURL.path),
            "diagnostics": .string(String(result.diagnosticsSummary.prefix(2000))),
        ]
        if let signNote = result.signNote {
            eventFields["sign"] = .string(signNote)
        }
        _ = try? await writer.append(.extensionEvent(
            kind: BuildEvents.eventKind,
            payload: .object(eventFields)))

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
            // 【N1】build log 路径行（插值内函数调用拆局部变量——swiftc
            // type-check 雷区纪律）。
            let logLine = BuildTools.buildLogPathLine(result)
            // 【N7c】签名注记（sign=true 时：成功/失败原因；nil=未请求）。
            var signLine = ""
            if let signNote = result.signNote {
                signLine = "\nsign: " + signNote
            }
            // 【批A · S3 / N1·文案一致批 2026-10-23】缓存状态恒有行（三态
            // 恒非空——增量也显式呈现，设备验收 O-2）。
            let cacheLine = "\n缓存状态: " + result.cacheNote
            return .success("""
                BUILD OK（\(String(format: "%.1fs", result.elapsedSeconds))）· ipa 大小 \(sizeText)\(optNote)\(signLine)\(cacheLine)
                ipa: \(result.ipaURL.path)\(guestHint)\(artifactLine)
                bundle(.app, N9 guest 取用): \(result.bundleURL.path)
                project: \(result.projectURL.path)
                diagnostics: \(result.diagnosticsSummary)\(logLine)
                """)
        } else {
            // 【批A · S2/P3-7】截断提示条件化——BuildResult.diagnosticsTruncated
            // 为 true（uniq>50 真截断）才追加，5 条全列出时不再出现噪声提示。
            // 【批A · U3/P3-8b】debug.json 无工作区副本（仅 ipa/run_log 有副本
            // 语义）——宿主路径如实标注 guest 不可读 + 指路 build_log 工具。
            // 【批A · S3】缓存状态提示（冷缓存首建 43s 级耗时——AI 误判卡死
            // 对策，BUILD OK/BUILD FAILED 双态同提示）。
            var failText = "BUILD FAILED（" + String(format: "%.1fs", result.elapsedSeconds) + "）" + optNote
            failText = failText + "\n缓存状态: " + result.cacheNote
            failText = failText + "\n—— 按以下诊断修复源码后重新 build_ipa：\n"
            failText = failText + result.diagnosticsSummary
            failText = failText + "\nbuild log: " + result.buildLogPath
                + "（宿主路径——guest 不可读；用 build_log 工具读取）"
            // 【N1】构建日志工作区副本路径行（run_log 副本同款文案模式——
            // AI fs/read 直取，编译全程诊断可回看）。
            failText = failText + BuildTools.buildLogPathLine(result)
            if result.diagnosticsTruncated {
                failText = failText + "\n（诊断可能未列全——完整列表见 build_log）"
            }
            return .failure(failText, code: "BUILD_FAILED", name: "BuildError")
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
            //
            // 【批 3 · P1 渲染修复】旧形态 "[\($0.severity)] \($0.message)"
            // 直出枚举描述（实测 "[MDKDiagnosticLevel(rawValue: 3)] cannot
            // convert..."）且无 file:line。修复（对齐 BuildService.build 渲染
            // 同源口径）：severity 经 BuildService.levelNames 映射等级名
            // （error/warning/remark/note/fatal/unknown）；file=debugObjects
            // 键（DebugObject.title——DebugItem 自身只存行列，MDKSourceLocation
            // 无文件字段）；message 前附 file:line:col（行号>0 才附——Internal
            // 桶消息无位置）。
            // 排序（如实报告）：按文件标题稳定化（Swift 字典遍历序不确定——
            // 不排序则输出顺序每次漂移）；同文件条目保持落盘序不强改。
            // 与 build_ipa 摘要顺序差异的根源=build() 额外做了 level 二次
            // 稳定排序（file→level 双键）——本处保持 file 单键，两输出顺序
            // 不一致为既有设计，不强改序。
            // 【批A · S1/P2-5 回归根治】路径渲染改走
            // BuildService.shortDiagnosticPath（单一渲染源——旧
            // hasPrefix(rootPrefix) 精确剥离对 /private/var 形态不命中致宿主
            // 绝对路径直出；title 真实形态考古与渲染序见该 helper 注记）。
            var titles: [String] = []
            for (title, _) in db.debugObjects {
                titles.append(title)
            }
            titles.sort()
            var lines: [String] = []
            var itemCount = 0
            for title in titles {
                guard let object = db.debugObjects[title] else { continue }
                let file = BuildService.shortDiagnosticPath(title: title, projectRoot: project.url)
                for item in object.debugItems {
                    let levelRaw = Int(item.severity.rawValue)
                    let level = BuildService.levelNames[levelRaw] ?? "note"
                    var line = "[" + level + "] "
                    let lineNum = Int(item.sourceLocation.line)
                    let colNum = Int(item.sourceLocation.column)
                    if lineNum > 0 {
                        line = line + file + ":" + String(lineNum) + ":" + String(colNum) + " "
                    }
                    line = line + item.message
                    lines.append(line)
                    itemCount = itemCount + 1
                }
            }
            if itemCount == 0 { return .success("（无诊断条目）") }
            return .success(lines.joined(separator: "\n"))
        } catch let e as BuildServiceError {
            return .failure(e.description, code: "PROJECT_ERROR", name: "BuildError")
        } catch {
            return .failure(String(describing: error), code: "LOG_FAILED")
        }
    }
}

// MARK: - stop_build（低危；N9b 扩 run 转语义）

struct StopBuildTool: AgentTool {
    let name = "stop_build"
    let description = "Release the build slot if a build finished abnormally, or stop the running guest app (build_and_run). "
        + "Note: an in-flight build cannot be interrupted (official NXBuilder has no cancel API) — this only clears a stale slot. "
        + "During a guest run this terminates the guest process (SIGKILL); the run session then finalizes in the background "
        + "(exit event with exit code/output tail/run_log copy reported via guest_run) and releases the run gate. "
        + "Also terminates ALL registered utility-terminal processes (批 3 修 O2 full sweep — array registration defensively "
        + "recovers every instance, normally at most one) — each terminal window closes automatically with its process and a "
        + "guest_run exit event reports the outcome (N10e 修 F/G — same as the app route)."
    let parameters = JSONValue.schemaObject(properties: [:], required: [])

    func isConcurrencySafe(_ args: JSONValue) -> Bool { true }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        // 【N9b】run 态转语义：终止 guest（run 门全生命周期持有——stop 后
        // 放行下一次 build/run，N9 方案 §三 7 拍板语义）。
        // 【N10c】utility 终端路线接线：run 门不长期持有（官方 .run utility
        // 段开窗即返回），活跃进程登记仍在——按登记终止 utility 进程（窗口
        // 随 exitingCallback 关闭——官方同款），无 run 门可放行。
        // 【N10d · C v2】run 门由 RunSession 收尾段放行（stop→terminate→
        // exit 回调→收尾→endRun）；本处仅在「无活跃会话登记的异常残留态」
        // 兜底放行，防 run 门永久卡死。
        if BuildService.shared.isRunInFlight || GuestRunService.shared.hasActiveRegisteredProcess {
            let note = GuestRunService.shared.stopActiveRun()
            if GuestRunService.shared.activeRunInfo() == nil, BuildService.shared.isRunInFlight {
                BuildService.shared.endRun()
            }
            return .success("guest run 已终止——" + note)
        }
        BuildService.shared.endBuild()
        return .success("构建槽位已复位（说明：编译进行中无法中途取消——官方构建器无取消接口；本操作仅用于异常残留后放行下一次构建）")
    }
}

// MARK: - build_and_run（危险级：审批 + run 门；N9b）

struct BuildAndRunTool: AgentTool {
    let name = "build_and_run"
    let description = "Full guest hosting pipeline (N9/N10): compile the project → LC container signing (host identity mode) → "
        + "NXTR entitlement token → installApplication via installd → spawn. "
        + "App-scheme projects: the tool returns immediately after a successful spawn — an NXWindow floating window appears as a "
        + "persistent interactive surface the user can interact with directly. When the guest later exits (on its own, via stop_build, "
        + "or via the floating window close button — official semantics: closing the window terminates the process), a guest_run event "
        + "reports the three-state exit (natural exit code / timeout / terminated), the last ≤80 output lines, and the run_log "
        + "workspace copy (AI-readable). Full output is persisted to run_log.txt (Cache path) and copied to the workspace "
        + "(BuildArtifacts/run_log-<project name>-<HHmmss>.txt). "
        + "Utility-scheme projects open an interactive terminal window (NXWindowSessionTerminal + SwiftTerm, TTY三映射——官方 .run utility 同款) "
        + "and return immediately. 【N10e 修 H】The utility terminal is raw mode (official terminal emulator semantics: no line buffering / no kernel echo) — "
        + "interactive programs must manage their own echo and line editing (e.g. read byte-by-byte and write back; self-drawn echo is a verified working pattern). "
        + "【N10e 修 F/G/I】On process exit (natural or via stop_build) the terminal window closes automatically (same as the app route) and a guest_run exit event "
        + "reports the outcome; raw terminal output is teed to the workspace "
        + "BuildArtifacts/run_log-<project name>-<HHmmss>.txt (AI-readable, contains ANSI control sequences). "
        + "Default: no timeout — the guest keeps running until it exits or is stopped; timeout_ms is an optional protective cap. "
        + "One run at a time: a second build_and_run while a run is in flight fails with the active pid (stop_build to terminate, or wait for exit). "
        + "批 3 修 O1: only one utility process at a time as well — a second build_and_run on a Utility project while a utility process is running fails "
        + "with its pid (stop_build to terminate or wait for natural exit); utility and app runs may coexist (independent window domains). "
        + "Requires user approval (ask once)."
    let parameters = JSONValue.schemaObject(
        properties: [
            "name": .stringSchema(description: "Project name to build and run as a guest app."),
            "timeout_ms": .numberSchema(description: "Optional protective cap in milliseconds (range 5000-960000). "
                + "Default: none — the guest runs until it exits on its own or stop_build/the window close button terminates it "
                + "(the floating window is a persistent interactive surface, so an indefinite run is expected). "
                + "When provided, the guest is terminated on timeout and the exit event reports the partial output."),
        ],
        required: ["name"])

    private let writer: SessionWriter
    private let sessionCwd: String?
    init(writer: SessionWriter, sessionCwd: String?) {
        self.writer = writer
        self.sessionCwd = sessionCwd
    }

    /// 编译占线程池与缓存目录 + run 门（spawn 成功后由 RunSession 收尾持门
    /// 至退出）——exclusive 车道串行。
    func isConcurrencySafe(_ args: JSONValue) -> Bool { false }

    // MARK: 观测链补全（N9 spawn 段真机首抵后——AI 可读性收口；C v2 起
    // 副本落盘移由 RunSession 收尾段消费，工具层保留实现供其调用）

    /// run_log 副本落工作区：源=Cache/<uuid>/run_log.txt（宿主私有路径，
    /// guest bash 与 AI 的 fs 工具都读不到）→ 副本=workspace/BuildArtifacts/
    /// run_log-<工程名>-<HHmmss>.txt（AI read 直取）。源路径为空（spawn 前
    /// 失败，无 run_log 落盘）或复制失败返回空串——结果文本不带副本路径行。
    /// 【批A · U1/P3-8a】副本命名补工程名段——工程删除/重置
    ///（deleteProjectDirectories）据此清工程名关联的 run_log 副本。
    /// 【C v2】internal：RunSession 常驻收尾段（GuestRunService，工具返回
    /// 后）同样消费——退出事件带工作区副本路径。
    /// 【D1 2026-10-22】副本只含最近一次运行：源 run_log.txt 为多轮追加
    /// 累积（GuestRunService 每次 spawn 追加「run start <ISO> bundle=… pid=…」
    /// 头行），全量拷贝会让 AI 读到旧轮日志被误导。定位源内容中最后一个
    /// 「run start 」行（本轮起点——与 GuestRunService.swift spawn 段写入
    /// 格式逐字对齐），从该行起拷贝到文件尾，副本头加注记行。找不到起点行
    ///（异常截断/历史格式）退为全量拷贝 + 累积快照注记（如实告知 AI 以
    /// 最后一段为本次运行）；拷贝实现本身异常再退回原样整文件 copyItem。
    static func copyRunLogToWorkspace(sourcePath: String,
                                      projectName: String,
                                      workspaceRoot: URL) -> String {
        guard !sourcePath.isEmpty else { return "" }
        let fm = FileManager.default
        let dir = workspaceRoot.appendingPathComponent("BuildArtifacts", isDirectory: true)
        try? fm.createDirectory(atPath: dir.path, withIntermediateDirectories: true)
        // 【N11 · O3】工程名段统一走 BuildService.artifactSafeName（与
        // project_delete 清理前缀同一命名函数——非 ASCII 工程名两侧口径
        // 统一，防孤儿副本；原内联 ASCII 兜底语义原样收编进该 helper）。
        let safeName = BuildService.artifactSafeName(projectName)
        let dest = dir.appendingPathComponent("run_log-" + safeName + "-" + Self.runLogStamp() + ".txt")
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(atPath: dest.path)
            }
            // 【D1 2026-10-22】优先只拷最近一次运行段；内容改写路径异常时
            // 退回旧全量 copyItem（保底不劣化）。
            do {
                try Self.writeRunLogLastRunCopy(sourcePath: sourcePath, destPath: dest.path)
            } catch {
                try fm.copyItem(atPath: sourcePath, toPath: dest.path)
            }
            return dest.path
        } catch {
            return ""
        }
    }

    /// 【D1 2026-10-22】副本改写实现：读源全文 → 定位最后一个「run start 」
    /// 行 → 从该行截到尾 → 头部注记后写盘。平铺实现、单步局部变量（swiftc
    /// 雷区纪律：无嵌套函数、无多行插值）。
    private static func writeRunLogLastRunCopy(sourcePath: String, destPath: String) throws {
        let header = "# 本副本仅含最近一次运行的日志（完整历史见 Cache/run_log.txt）\n"
        let fallbackHeader = "# 本副本为累积快照，含多轮运行日志，以最后一段为本次运行（完整历史见 Cache/run_log.txt）\n"
        let full = try String(contentsOfFile: sourcePath, encoding: .utf8)
        // 逐行扫描，记录最后一个「run start 」行的起始偏移（单步局部变量）。
        var lastStartIndex: String.Index? = nil
        var lineStart = full.startIndex
        var scanning = true
        while scanning {
            let newlineRange = full.range(of: "\n", range: lineStart..<full.endIndex)
            let lineEnd = newlineRange?.lowerBound ?? full.endIndex
            let line = full[lineStart..<lineEnd]
            if line.hasPrefix("run start ") {
                lastStartIndex = lineStart
            }
            if newlineRange == nil {
                scanning = false
            } else {
                lineStart = full.index(after: lineEnd)
            }
        }
        if let start = lastStartIndex {
            let body = String(full[start...])
            try (header + body).write(toFile: destPath, atomically: true, encoding: .utf8)
        } else {
            // 无起点行（异常/历史格式）——全量内容 + 累积快照注记。
            try (fallbackHeader + full).write(toFile: destPath, atomically: true, encoding: .utf8)
        }
    }

    /// 副本文件名时间戳（HHmmss——平铺函数，swiftc 雷区纪律）。
    private static func runLogStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return f.string(from: Date())
    }

    func presentCall(_ args: JSONValue) -> ToolCardIntent? {
        ToolCardIntent(kind: .terminal,
                       title: "build_and_run",
                       detail: args.objectValue?["name"]?.stringValue ?? "")
    }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let name = args.objectValue?["name"]?.stringValue else {
            return .failure("missing \"name\"", code: "INVALID_ARGS")
        }
        // 【C-a 拍板】默认不限时；timeout_ms 可选保留为保护上限。
        var timeoutSeconds: TimeInterval? = nil
        if let t = args.objectValue?["timeout_ms"]?.intValue {
            timeoutSeconds = min(960, max(5, Double(t) / 1000.0))
        }

        // 工程定位提前到审批前（build_ipa 同缝——工程不存在/名字错不必白批）
        let project: NXProject
        do {
            project = try BuildToolSupport.resolveProject(workspace: ctx.workspace, name: name)
        } catch let e as BuildServiceError {
            return .failure(e.description, code: "PROJECT_ERROR", name: "BuildError")
        } catch {
            return .failure(String(describing: error), code: "PROJECT_ERROR")
        }

        // ── N10c：utility 工程 → 终端路线（NXWindowSessionTerminal——官方
        // .run utility 段语义；app 工程继续走下方 N9 管道路线零回归）。
        // 分叉点在 ① 编译成功之后（签名编排/开窗形态不同，编译/审批/宏预检/
        // lld 门共用）——见 ① 段后的 isUtilityProject 分支。
        let isUtilityProject = project.projectConfig.schemeKind != NXProjectSchemeKind.app

        // ── 【批 3 · 修 O1】utility-vs-utility 并发 gate ──────────────────
        // 提前到审批/编译前（不白批一次+不浪费数分钟 CPU 才发现被拒）。
        // 旧形态缺陷（测试1 P0-1 定罪）：registerUtilityProcess 单槽覆写
        // activeProcess——第二次 utility run 直接覆盖登记，首个进程失管成
        // 孤儿。修复语义对齐 app 路线 C-b 拍板：明确失败带活跃 pid，不自动
        // 停旧起新。
        // 域划分依据（utility-vs-app 不拒绝）：app 路线 C v2 开窗即返后 run
        // 门已放行——app 长活会话（浮窗常驻交互面）与 utility 终端各自独立
        // 窗口域，无 run 门互持；两者登记/回收互相独立（批 3 修 O2 后
        // utility 走独立数组登记，不再覆写 app 的 activeProcess 槽）。
        if isUtilityProject, let activeUtility = GuestRunService.shared.utilityActiveInfo() {
            let gateMsg = "RUN_IN_FLIGHT：utility 进程运行中（pid=" + String(activeUtility.pid)
                + " 工程=" + activeUtility.projectName
                + "）——stop_build 终止或等其自然退出"
            return .failure(gateMsg, code: "RUN_IN_FLIGHT", name: "BuildError")
        }

        // 证书前置快速失败（build_ipa 同缝——不浪费数分钟 CPU 才发现签不了）
        if !CertificateStore.isConfigured {
            return .failure(
                "no certificate is configured — guest container signing requires p12 + mobileprovision + password "
                    + "(Settings → 签名证书), then retry.",
                code: "SIGN_NOT_CONFIGURED", name: "BuildError")
        }

        // 宏预检（build_ipa 同缝——external macro 必败，拦下省一次审批+CPU）
        let macroScan = BuildService.scanMacroUsage(project: project)
        if macroScan.files > 0 {
            var macroMsg = "pre-check: " + String(macroScan.files)
                + " source file(s) use macros unavailable in this toolchain"
                + " (#Preview / @Observable / @Model — external macro plugins are not bundled, official boundary)."
                + " Remove the macros and retry."
            if !macroScan.samples.isEmpty {
                macroMsg = macroMsg + "\nfiles: " + macroScan.samples.joined(separator: ", ")
            }
            return .failure(macroMsg, code: "MACRO_PRECHECK", name: "BuildError")
        }

        // lld 污染拦截（build_ipa 同缝——上次 duplicate symbol 失败后同进程
        // 再链接大概率 UAF 闪退）
        if BuildService.isLldContaminated {
            return .failure(
                "build service contamination: a previous build in this process failed with duplicate symbols, "
                    + "leaking lld linker state. Ask the user to restart the App (kill and relaunch WanWo), then retry.",
                code: "LLD_CONTAMINATED", name: "BuildError")
        }

        // 审批（危险级 askOnce——总纲纪律 3：guest spawn 默认询问；nil → fail closed）
        if let approver = ctx.escalationApprover {
            let actionText = "编译并拉起 guest 工程 \"" + name
                + "\"（编译占设备 CPU 数分钟；LC 容器签名/安装/进程拉起在宿主进程内执行）"
            let outcome = await approver("build_and_run", ctx.callId, actionText)
            guard outcome == .allowedOnce else {
                return .failure("user did not approve the guest run (outcome: \(outcome.rawValue))",
                                code: "RUN_NOT_APPROVED", name: "BuildError")
            }
        } else {
            return .failure("no approval service available（fail closed）",
                            code: "RUN_NOT_APPROVED", name: "BuildError")
        }

        // run 门（全生命周期：build→prepare→spawn→[C v2] RunSession 收尾；
        // run 中禁新 build——beginBuild 对 run 在途同样拒绝）。
        // 【C-b 拍板】重复运行=明确失败带活跃 pid，不自动停旧起新；endRun
        // 不再走 defer——spawn 成功由 RunSession 收尾放行，失败路径本方法
        // 内显式 endRun。
        guard BuildService.shared.beginRun() else {
            if BuildService.shared.isRunInFlight, let active = GuestRunService.shared.activeRunInfo() {
                let msg = "guest 运行中（pid=" + String(active.pid) + " 工程=" + active.projectName
                    + "）——stop_build 终止或等其退出；重复运行被拒绝（不自动停旧起新）"
                return .failure(msg, code: "RUN_IN_FLIGHT", name: "BuildError")
            }
            return .failure("another build or guest run is already in flight（等待其结束或 stop_build 后重试）",
                            code: "BUILD_IN_FLIGHT", name: "BuildError")
        }

        // ① 编译（MDK 线程池；sign=false——容器签名归 prepare 段）
        // 【N1】构建日志落盘（build_ipa 同缝——两路线同治）。
        let logArgs = BuildTools.buildLogArguments(workspaceRoot: ctx.workspace.rootURL, projectName: name)
        let result: BuildResult = await withCheckedContinuation { cont in
            BuildService.shared.build(project: project, sign: false,
                                      logDirectory: logArgs.directory,
                                      logProjectName: logArgs.name) { r in
                cont.resume(returning: r)
            }
        }
        guard result.success else {
            BuildService.shared.endRun()
            _ = try? await writer.append(.extensionEvent(
                kind: RunEvents.eventKind,
                payload: .object([
                    "name": .string(name),
                    "result": .string("failure"),
                    "phase": .string("build"),
                    "exit": .string("-"),
                    "runLog": .string(result.buildLogPath),
                    "diagnostics": .string(String(result.diagnosticsSummary.prefix(2000))),
                ])))
            // 【批A · S3】缓存状态提示 + 【U3/P3-8b】debug.json 宿主路径注记
            // （build_ipa 失败文案同款口径）。
            var cacheLine = ""
            if !result.cacheNote.isEmpty {
                cacheLine = "\n缓存状态: " + result.cacheNote
            }
            // 【N1】build log 路径行（插值内函数调用拆局部变量——swiftc
            // type-check 雷区纪律）。
            let failLogLine = BuildTools.buildLogPathLine(result)
            return .failure("""
                BUILD FAILED（\(String(format: "%.1fs", result.elapsedSeconds))）\(cacheLine)——按以下诊断修复源码后重新 build_and_run：
                \(result.diagnosticsSummary)
                build log: \(result.buildLogPath)（宿主路径——guest 不可读；用 build_log 工具读取）\(failLogLine)
                """, code: "BUILD_FAILED", name: "BuildError")
        }

        // ══ N10c：utility 终端路线（官方 Builder.swift:358-373 .run utility
        // 段语义对齐——签名编排→fastpath→自动开窗；run 门在返回前显式放行
        //（C v2：无 RunSession 持门——官方开窗即返回形态），stop_build 接线
        // 走活跃进程登记）══════════════════════════════════════════════
        if isUtilityProject {
            // ② utility 签名编排（官方 .run utility 段等义：补片→单 macho
            //    ZSign→NXTR token→fastpathUtility——prepareGuestRun 的
            //    utility 对位，见 BuildService.prepareUtilityRun）
            let prep = BuildService.prepareUtilityRun(project: project)
            guard prep.ok else {
                BuildService.shared.endRun()
                _ = try? await writer.append(.extensionEvent(
                    kind: RunEvents.eventKind,
                    payload: .object([
                        "name": .string(name),
                        "result": .string("failure"),
                        "phase": .string("prepare"),
                        "exit": .string("-"),
                        "runLog": .string(result.buildLogPath),
                        "diagnostics": .string(String(prep.message.prefix(2000))),
                    ])))
                return .failure("UTILITY PREPARE FAILED（编译成功，签名/token/fastpath 段失败——AI 按原因自修复后重跑）:\n" + prep.message,
                                code: "PREPARE_FAILED", name: "BuildError")
            }

            // ③ 自动开窗（拍板项 3）：官方 Builder.swift:367-370 同语义——
            //    NXWindowSessionTerminal initWithUtilityPath → NXWindowServer
            //    openWindowWithSession（openWindow 内部：TTY 分配+termios+
            //    三路 SLAVEFD 映射+spawn+tty_attach_proc+TerminalViewObjC——
            //    vendored 官方原样消费）。终端窗口关闭=进程 terminate（官方
            //    closeWindow 同款）。
            //    【N10e 修 F/G/I】exitingCallback 包装升级：官方回调之后
            //    ①采集 wait4 原值（processDidExit :284 触发点退出码可及——
            //    :275 同函数先读 exitContext）②主队列关窗（closeTerminal-
            //    WindowWithIdentifier——和 app 路线 processDidExit 关窗形态
            //    一致：PEProcess.m:286-294）③unregister（tee footer+guest_run
            //    退出事件+A2 窗口收尾）。stop_build 与自然退出同走此包装=
            //    两路径都自动关窗（「和 app 一样」拍板语义）。
            let fastPath = prep.utilityPath
            // 修 I：tee 落盘路径（对齐 app 路线工作区副本语义——BuildArtifacts/
            // run_log-<工程名>-<HHmmss>.txt 落 workspace 可 AI 直读；fakefs 元
            // 数据补注册同 ipa 副本缝；工程名段供 U1 delete/reset 清理关联）。
            let artDir = ctx.workspace.rootURL.appendingPathComponent("BuildArtifacts", isDirectory: true)
            try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
            // 【N11 · O2】工程名段经 artifactSafeName（与 run_log 副本/
            // project_delete 清理同一命名函数——非 ASCII 工程名口径统一）。
            let teeSafeName = BuildService.artifactSafeName(name)
            let teePath = artDir.appendingPathComponent(
                "run_log-" + teeSafeName + "-" + Self.runLogStamp() + ".txt").path
            let wsRootStd = ctx.workspace.rootURL.standardizedFileURL.path
            let teeStd = URL(fileURLWithPath: teePath).standardizedFileURL.path
            if teeStd.hasPrefix(wsRootStd + "/"), let cwd = sessionCwd {
                IshExecutorBridge.ensureFakefsMetadata(for: cwd + "/BuildArtifacts", isDirectory: true)
                let teeRel = String(teeStd.dropFirst(wsRootStd.count))
                IshExecutorBridge.ensureFakefsMetadata(for: cwd + teeRel, isDirectory: false)
            }
            let prepDetailText = prep.detail
            let opened = await MainActor.run { () -> (Bool, String) in
                var procRef: PEProcess?
                var winRef: id_t = 0
                var noteRef: NSString?
                let tee = UtilityTeeLog(path: teePath)
                let ok = GuestWindowBridge.openUtilityTerminal(
                    withPath: fastPath,
                    processOut: &procRef,
                    windowIdentifierOut: &winRef,
                    teeLog: tee,
                    noteOut: &noteRef)
                if ok, let process = procRef {
                    // 【批 3 · 修 O2/O3】数组登记（孤儿根源消除——不再覆写
                    // app 槽）+ timeoutSeconds 消费（nil=不限时，C-a 同款）。
                    GuestRunService.shared.registerUtilityProcess(
                        process,
                        utilityPath: fastPath,
                        projectName: name,
                        windowIdentifier: winRef,
                        teeLog: tee,
                        prepDetail: prepDetailText,
                        writer: writer,
                        timeoutSeconds: timeoutSeconds)
                    let officialCallback = process.exitingCallback
                    let windowId = winRef
                    process.exitingCallback = { [weak process] in
                        officialCallback?()
                        // 修 G：wait4 原值采集（任意线程——service lock 内写；
                        // 批 3 数组化——按窗口 id 定位登记）。
                        var raw = -1
                        if let strong = process {
                            let ctxAny: Any? = strong.process?.exitContext
                            if let exitCtx = ctxAny as? FBProcessExitContext {
                                raw = Int(exitCtx.underlyingContext.legacyCode)
                            }
                        }
                        GuestRunService.shared.noteUtilityExitRaw(windowIdentifier: windowId, raw: raw)
                        // 修 F：主队列关窗+注销（exitingCallback 触发线程不保证
                        // 主线程——vendored 官方回调内 closeWindow 也走 dispatch
                        // async main（NXWindowSessionTerminal.m:183 同款前提）；
                        // unregister 内 tee footer/事件发射线程安全；批 3 修 O2
                        // ——按窗口 id 定位单条登记移除+超时定时器 cancel）。
                        DispatchQueue.main.async {
                            GuestWindowBridge.closeTerminalWindow(withIdentifier: windowId)
                            GuestRunService.shared.unregisterUtilityProcess(windowIdentifier: windowId)
                        }
                    }
                    var note = "utility=" + (fastPath as NSString).lastPathComponent
                        + " pid=" + String(process.pid)
                    note = note + "（stop_build 可终止；进程退出/stop_build 后终端窗自动关闭——和 app 路线一致）"
                    return (true, note)
                }
                // 开窗失败：tee 已创建未消费（pendingTee 未被 init 认领？已置入
                // 即可能被认领——此处显式 footer 收尾防句柄悬挂）。
                tee.writeFooter("run end（开窗失败——tee 无输出）\n")
                let failNote = (noteRef as String?) ?? "openUtilityTerminal 失败（无注记）"
                return (false, failNote)
            }

            _ = try? await writer.append(.extensionEvent(
                kind: RunEvents.eventKind,
                payload: .object([
                    "name": .string(name),
                    "result": .string(opened.0 ? "success" : "failure"),
                    "phase": .string("spawn"),
                    "exit": .string("-"),
                    "runLog": .string(result.buildLogPath),
                    "diagnostics": .string(String(prep.detail.prefix(2000))),
                ])))

            if opened.0 {
                // 官方 .run utility 开窗即返回语义——run 门在本方法内显式放行
                //（C v2：无 RunSession 持门，不再走 defer）。
                BuildService.shared.endRun()
                // 【N1】build log 路径行（插值内函数调用拆局部变量——雷区纪律）。
                let utilityLogLine = BuildTools.buildLogPathLine(result)
                return .success("""
                    UTILITY TERMINAL OPENED（\(name)）
                    \(opened.1)
                    \(prep.detail)
                    终端窗口内 stdin/stdout 完整交互（SwiftTerm——官方 .run utility 同款；raw 模式：无行缓冲/无内核回显，交互程序需自管回显）；窗口关闭=进程 terminate；进程退出（含 stop_build）后窗口自动关闭并经 guest_run 事件回报退出形态。
                    运行输出 tee 工作区副本：\(teePath)（AI read 直取——raw 终端字节流含 ANSI 控制序列）\(utilityLogLine)
                    """)
            }
            BuildService.shared.endRun()
            return .failure("UTILITY TERMINAL FAILED（签名/fastpath 成功，开窗段失败）:\n" + opened.1,
                            code: "TERMINAL_FAILED", name: "BuildError")
        }

        // ② 补片→容器签名→NXTR token→安装（官方 .run 签名编排等义）
        let prep = BuildService.prepareGuestRun(project: project)
        guard prep.ok else {
            BuildService.shared.endRun()
            _ = try? await writer.append(.extensionEvent(
                kind: RunEvents.eventKind,
                payload: .object([
                    "name": .string(name),
                    "result": .string("failure"),
                    "phase": .string("prepare"),
                    "exit": .string("-"),
                    "runLog": .string(result.buildLogPath),
                    "diagnostics": .string(String(prep.message.prefix(2000))),
                ])))
            return .failure("PREPARE FAILED（编译成功，签名/安装段失败——AI 按原因自修复后重跑）:\n" + prep.message,
                            code: "PREPARE_FAILED", name: "BuildError")
        }

        // ③ spawn + stdio 回流启动（【C v2 拍板】spawn 成功工具立即返回——
        //    等待与收尾交 RunSession 常驻段：退出后经 guest_run 事件回报
        //    退出码+输出尾段+run_log 工作区副本；专用队列承载 spawn 段——
        //    ensureActivatedSync 内部 dispatch_sync 主队列，禁占协作线程池）
        let callId = ctx.callId
        let onShellLine = ctx.onShellLine
        let wsRoot = ctx.workspace.rootURL
        let prepDetail = prep.detail
        let spawn: GuestRunSpawnResult = await withCheckedContinuation { cont in
            DispatchQueue(label: "wanwo.guestrun.spawn").async {
                let r = GuestRunService.shared.spawnRun(
                    project: project,
                    projectName: name,
                    bundleID: prep.bundleID,
                    timeoutSeconds: timeoutSeconds,
                    prepDetail: prepDetail,
                    onLine: { line in
                        onShellLine(callId, line)
                    },
                    writer: writer,
                    workspaceRoot: wsRoot)
                cont.resume(returning: r)
            }
        }

        // spawn 失败（prepare 成功后的 spawn 段失败——run 门本方法放行）
        guard spawn.ok, let session = spawn.session else {
            BuildService.shared.endRun()
            _ = try? await writer.append(.extensionEvent(
                kind: RunEvents.eventKind,
                payload: .object([
                    "name": .string(name),
                    "result": .string("failure"),
                    "phase": .string("spawn"),
                    "exit": .string("-"),
                    "runLog": .string(spawn.runLogPath),
                    "diagnostics": .string(String(prep.detail.prefix(2000)) + "；" + spawn.message),
                ])))
            return .failure("SPAWN FAILED（编译/prepare 成功，spawn 段失败）:\n" + spawn.message,
                            code: "GUEST_SPAWN_FAILED", name: "BuildError")
        }

        // spawn 成功事件（phase=spawn——退出事件由 RunSession 收尾补发
        // phase=exit，带三态退出注记+输出尾段+run_log 工作区副本）
        _ = try? await writer.append(.extensionEvent(
            kind: RunEvents.eventKind,
            payload: .object([
                "name": .string(name),
                "result": .string("success"),
                "phase": .string("spawn"),
                "exit": .string("-"),
                "runLog": .string(session.runLogPath),
                "diagnostics": .string(String(prep.detail.prefix(2000))),
            ])))

        let spawnNote = "pid=" + String(session.pid)
            + "（浮窗已弹出——常驻交互面，用户可直接交互；stop_build 可终止；"
            + "guest 退出后经 guest_run 事件回报退出码+输出尾段+run_log 工作区副本）"
        return .success("GUEST SPAWNED（" + name + "）\n"
            + spawnNote + "\n"
            + prep.message + "\n"
            + prep.detail
            + BuildTools.buildLogPathLine(result))
    }
}
