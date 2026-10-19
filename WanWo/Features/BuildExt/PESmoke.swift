//
//  PESmoke.swift
//  WanWo
//
//  【N8c · pe_smoke】运行侧底座冒烟工具（形态 A：BuildExt 域 AI 可调用审批级
//  工具——方案拍板项 4，用户 2026-10-19 22:09 确认）。总纲 N8 验收四条的机测
//  载体（装机后由 AI 自主驱动，结果文本回流）：
//    ① status（只读）：liveProcessIsAvailable + PEBootstrapRegistry endpoint
//      注册数 + 两 daemon（PELaunchServiceRegistry）pid/autorestart 直译。
//    ② probe（只读）：经宿主代理面 PEContainer（→containerd daemon）做 XPC
//      往返（containerRoot + isReadableFileAtPath），证明 XPC 句柄/对象传输
//      （总纲验收②；对象跨 XPC 白名单 = ResecureDecoder 5 类体系）。
//    ③ recycle（驱动级，审批）：对指定 daemon terminate → 轮询 autorestart
//      新 pid（PELaunchService PEShouldAutorestart→exitingCallback→ignition
//      官方语义）→ 报告宿主存活（总纲验收④；pid>0 亦旁证 getppid 闸门已过
//      =验收③，daemon 已进入 PEServiceMain 并注册 endpoint）。
//  注册形态与审批缝完全复用 BuildTools 既有模式（build_ipa 同管线）。
//
//  swiftc 雷区纪律：构造器参数位无内嵌复杂表达式、多行插值拆单步局部变量、
//  无嵌套函数（全部 static func 平铺）。
//

import Foundation

// MARK: - PESmokeService（冒烟语义承载，纯只读+terminate 驱动）

enum PESmokeService {

    /// daemon 服务标识（LaunchServices plist 折算后形态，compliance §N8）
    static let containerdIdentifier = "com.wanwo.containerd"
    static let installdIdentifier = "com.wanwo.installd"

    /// recycle 轮询上限（官方 spawn 反自旋 300ms + NSExtension 拉起余量；
    /// PELaunchService.ignition 失败路径为递归重试无退避——官方形状，超时即报）
    static let recycleTimeoutSeconds: TimeInterval = 20

    /// status：只读状态直译（klog 同信息面）。
    static func statusReport() -> String {
        var lines: [String] = []

        let extAvailable = liveProcessIsAvailable()
        if extAvailable {
            lines.append("extension: WanWoLiveProcess.appex present (PlugIns)")
        } else {
            lines.append("extension: WanWoLiveProcess.appex MISSING in PlugIns (liveProcessIsAvailable=false, ignition 不会启动)")
        }

        let bootstrap = PEBootstrapRegistry.shared()
        let registryDict = bootstrap.registry
        let endpointCount = registryDict.count
        lines.append("bootstrap endpoints registered: " + String(endpointCount))
        let sortedIDs = registryDict.keys.sorted()
        for identifier in sortedIDs {
            lines.append("  endpoint: " + identifier)
        }

        let launchRegistry = PELaunchServiceRegistry.shared()
        let services = [containerdIdentifier, installdIdentifier]
        for identifier in services {
            let service = launchRegistry.service(forIdentifier: identifier)
            if service == nil {
                lines.append("service " + identifier + ": NOT REGISTERED（plist 缺失或 ignition 未跑）")
                continue
            }
            let svc = service!
            var line = "service " + identifier
                + ": exec=" + (svc.executablePath ?? "-")
                + " autorestart=" + String(svc.autoRestart)
            let process = svc.process
            if process != nil {
                let pid = process!.pid
                if pid > 0 {
                    line = line + " pid=" + String(pid) + " RUNNING"
                } else {
                    line = line + " pid=" + String(pid) + " NOT RUNNING"
                }
            } else {
                line = line + " pid=- (no process record)"
            }
            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }

    /// probe：XPC 往返证明（宿主代理面 → containerd daemon）。
    /// PEContainer 方法内部为官方同款 2s 超时 semaphore 形态，阻塞安全。
    static func probeReport() -> String {
        let container = PEContainer.shared()
        // 第一跳：containerRoot（NSURL 对象跨 XPC 返回 appex NSHomeDirectory()）
        let root = container.containerRoot
        if root == nil {
            return "probe FAILED: containerRoot nil（XPC 往返超时/连接失败——containerd daemon 未起？先 pe_smoke mode=status）"
        }
        let rootURL = root!
        let rootPath = rootURL.path
        // 第二跳：对容器根做 BOOL 往返（isReadableFileAtPath 官方 probe 面）
        let readable = container.isReadableFile(atPath: rootPath)
        var lines: [String] = []
        lines.append("probe round-trip 1 (containerRoot): OK -> " + rootPath)
        if readable {
            lines.append("probe round-trip 2 (isReadableFileAtPath root): OK (true)")
        } else {
            lines.append("probe round-trip 2 (isReadableFileAtPath root): returned false（容器根不可读——异常态）")
        }
        if readable {
            lines.append("XPC handle transport: VERIFIED（对象跨 XPC + 连接全链畅通）")
        }
        return lines.joined(separator: "\n")
    }

    /// recycle：terminate → autorestart 新 pid → 宿主存活（驱动级，需审批）。
    static func recycleReport(serviceIdentifier: String) -> String {
        let launchRegistry = PELaunchServiceRegistry.shared()
        let service = launchRegistry.service(forIdentifier: serviceIdentifier)
        if service == nil {
            return "recycle FAILED: service " + serviceIdentifier + " not registered（先 pe_smoke mode=status 看 ignition 态）"
        }
        let svc = service!
        let oldProcess = svc.process
        if oldProcess == nil {
            return "recycle FAILED: service " + serviceIdentifier + " has no live process（daemon 未在跑）"
        }
        let oldPid = oldProcess!.pid
        if oldPid <= 0 {
            return "recycle FAILED: pid=" + String(oldPid) + "（daemon 无有效 pid）"
        }

        // 驱动级 terminate（官方 PEProcess.terminate→SIGKILL→processDidExit；
        // autorestart 走 PELaunchService.exitingCallback→ignition）
        _ = oldProcess!.terminate()

        // 轮询新 pid（新 PEProcess 对象被 ignition 装回 _process）
        var newPid: Int32 = 0
        let deadline = Date().addingTimeInterval(recycleTimeoutSeconds)
        while Date() < deadline {
            let current = svc.process
            if current != nil {
                let candidate = current!.pid
                if candidate > 0 && candidate != oldPid {
                    newPid = candidate
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        var lines: [String] = []
        if newPid > 0 {
            lines.append("recycle: " + serviceIdentifier + " old pid " + String(oldPid)
                         + " -> new pid " + String(newPid) + "（autorestart VERIFIED）")
        } else {
            lines.append("recycle: " + serviceIdentifier + " terminate 后 " + String(Int(recycleTimeoutSeconds))
                         + "s 内未见新 pid（autorestart 未发生——查 klog/ignition 自旋风险）")
        }
        // 宿主存活证明：本工具仍在执行 + 宿主面单例可响应（总纲验收④）
        let managerAlive = (PEProcessManager.shared() != nil)
        let registryAlive = (PEBootstrapRegistry.shared() != nil)
        lines.append("host alive: PEProcessManager=" + String(managerAlive)
                     + " PEBootstrapRegistry=" + String(registryAlive)
                     + "（宿主进程未随 daemon 终止）")
        if newPid > 0 && managerAlive {
            lines.append("verdict: PASS（N8 验收④；新 pid 亦旁证 getppid 闸门=验收③已过）")
        } else if managerAlive {
            lines.append("verdict: PARTIAL（宿主存活 ✓，autorestart ✗——按验收矩阵记失败项）")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - PESmokeTool（AgentTool 注册形态，build_ipa 同管线）

struct PESmokeTool: AgentTool {
    let name = "pe_smoke"
    let description = "Runtime foundation smoke tool (N8). "
        + "mode=status: read-only daemon/endpoint state (containerd + installd pids, XPC bootstrap registrations). "
        + "mode=probe: read-only XPC round-trip to the containerd daemon via the host proxy (verifies handle transport). "
        + "mode=recycle: terminate a daemon and verify auto-restart with a new pid (requires user approval; host must survive). "
        + "Run status first after install; probe/recycle only make sense once daemons are running."
    let parameters = JSONValue.schemaObject(
        properties: [
            "mode": .stringSchema(description: "status | probe | recycle"),
            "service": .stringSchema(description: "For recycle: \"com.wanwo.containerd\" (default) or \"com.wanwo.installd\"."),
        ],
        required: ["mode"])

    /// recycle 触碰 daemon 生命周期——exclusive 车道。
    func isConcurrencySafe(_ args: JSONValue) -> Bool { false }

    func execute(_ args: JSONValue, _ ctx: ToolExecutionContext) async throws -> ToolOutput {
        guard let mode = args.objectValue?["mode"]?.stringValue else {
            return .failure("missing \"mode\" (status | probe | recycle)", code: "INVALID_ARGS")
        }

        if mode == "status" {
            return .success(PESmokeService.statusReport())
        }
        if mode == "probe" {
            return .success(PESmokeService.probeReport())
        }
        if mode != "recycle" {
            return .failure("invalid \"mode\": " + mode + " (status | probe | recycle)", code: "INVALID_ARGS")
        }

        // recycle：服务名校验（fail closed——只允许两个已知 daemon 标识）
        let service = args.objectValue?["service"]?.stringValue ?? PESmokeService.containerdIdentifier
        if service != PESmokeService.containerdIdentifier && service != PESmokeService.installdIdentifier {
            return .failure("invalid \"service\": " + service
                            + "（只允许 " + PESmokeService.containerdIdentifier
                            + " / " + PESmokeService.installdIdentifier + "）",
                            code: "INVALID_ARGS")
        }

        // 审批（驱动级——终止 daemon 进程；nil → fail closed，build_ipa 同缝）
        if let approver = ctx.escalationApprover {
            let outcome = await approver("pe_smoke", ctx.callId,
                                         "重启运行侧守护进程 \"\(service)\"（terminate 后验证自动重启）")
            guard outcome == .allowedOnce else {
                return .failure("user did not approve the recycle (outcome: \(outcome.rawValue))",
                                code: "RECYCLE_NOT_APPROVED", name: "BuildError")
            }
        } else {
            return .failure("no approval service available（fail closed）",
                            code: "RECYCLE_NOT_APPROVED", name: "BuildError")
        }

        return .success(PESmokeService.recycleReport(serviceIdentifier: service))
    }
}
