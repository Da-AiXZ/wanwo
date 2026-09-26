//
//  OffloadPermissionManager.swift
//  WanWo
//
//  【vendored 适配 · 源=OpenMinis src/ios/Agent/Offload/OffloadPermissionManager.swift
//   全文 303 行】三档权限（bypass/askOnce/notAllowed）持久化 + 每会话 AskOnce
//   授权（sessionGrants）+ 30s 超时 + 参数化确认卡数据结构。
//
//  适配点（简报 B1a ②，全部有明示依据；其余语义 1:1）：
//   1. 【删除】extractOffloadCommand(from:)（原件 :210-222，简报明示不移植——
//      v2 检查点已移内核分发点，见 10-design:818 + Platform/ISHKernel.m
//      wanwo_offload_register_checked）。
//   2. 【替换】@Published pendingRequest 审批流 → 审批缝 presentApproval
//      （简报明示形态：var presentApproval: ((Request, @Sendable @escaping
//      (Bool) -> Void) -> Void)?；AppEnvironment 后续接线，TODO(审批接线)）。
//      PermissionRequest 保留（去掉 continuation 字段——应答通道由缝回调承载），
//      parsedArguments 参数化解析逻辑 1:1 保留（原件 :34-92）。
//      OpenMinis 靠 pendingRequest 主线程串行化防"超时 vs 用户应答"双恢复；
//      缝化后应答回调可能来自任意线程，改用锁保护 resume-once 标志，语义不变。
//   3. 【新增】命令注册表扩为 27 条（简报 B1a ②：按 10-design §8.2 表
//      :823-851，含每命令默认档 defaultLevel；OpenMinis 原表仅 19 条且无
//      defaultLevel 字段）。permissionLevel 未存储时回落注册表默认档。
//   4. 【改名】denied 消息深链 minis://settings/permissions →
//      wanwo://settings/permissions（10-design M6.5 wanwo:// scheme）。
//   5. 【新增·万我 M6.1】checkForKernel(command:fullCommand:)：内核
//      trampoline 的 C→Swift 同步检查入口（信号量阻塞等待 MainActor 异步
//      检查收敛，≤30s 超时按 deny——简报 ③"阻塞等待 ≤30s=deny"）。
//   6. 【新增·测试缝】approvalTimeoutSeconds / init(defaults:)：生产路径
//      恒 30s + UserDefaults.standard（存储形态与原件一致）；仅供单测注入。
//

import Foundation
import Combine
import os.lock

// MARK: - Types

enum OffloadPermissionLevel: Int, CaseIterable {
    case bypass = 0
    case askOnce = 1
    case notAllowed = 2

    var displayName: String {
        switch self {
        case .bypass: return "Bypass"
        case .askOnce: return "Ask Once"
        case .notAllowed: return "Not Allowed"
        }
    }
}

enum PermissionResult: Equatable {
    case allowed
    case denied(String)
}

struct PermissionRequest: Identifiable {
    let id: String
    let commandName: String
    let displayLabel: String
    let description: String
    /// The full shell command string, e.g. "apple-healthkit query --type steps"
    let fullCommand: String

    /// Parse the command arguments into displayable key-value pairs.
    /// Handles patterns like: `command subcommand --key value --flag`.
    ///
    /// Only the FIRST shell command's tokens are surfaced — anything past a
    /// pipe / chain operator (`&&`, `||`, `;`, `|`) or a redirect (`>`,
    /// `>>`, `<`) belongs to a separate process or is plumbing the user
    /// shouldn't have to skim through to grant a permission. Without this
    /// gate the previous parser dumped the redirect target, the chained
    /// `python3 -c "..."` blob, and every word inside the quoted python
    /// snippet as `arg` rows, pushing the Allow / Deny buttons below the
    /// sheet's bottom edge. 【OpenMinis OffloadPermissionManager.swift:45-73 1:1】
    var parsedArguments: [(key: String, value: String)] {
        let parts = Self.firstCommandTokens(fullCommand)
        guard parts.count > 1 else { return [] }

        var result: [(key: String, value: String)] = []
        // First non-command token is the subcommand
        var idx = 1
        if idx < parts.count && !parts[idx].hasPrefix("-") {
            result.append((key: "Action", value: parts[idx]))
            idx += 1
        }
        while idx < parts.count {
            let token = parts[idx]
            if token.hasPrefix("--") || token.hasPrefix("-") {
                let key = token.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                if idx + 1 < parts.count && !parts[idx + 1].hasPrefix("-") {
                    result.append((key: key, value: parts[idx + 1]))
                    idx += 2
                } else {
                    result.append((key: key, value: "true"))
                    idx += 1
                }
            } else {
                result.append((key: "arg", value: token))
                idx += 1
            }
        }
        return result
    }

    /// Whitespace-split the command but stop at the first shell separator so
    /// only the head command's tokens are returned. This is permissive about
    /// quoting (we don't try to honour `'...'` / `"..."` boundaries) — good
    /// enough for the permission-row preview where we just want to suppress
    /// the long tail past `&&`, redirects, etc. that confused users.
    private static let shellSeparators: Set<String> = [
        "&&", "||", ";", "|", ">", ">>", "<", "<<", "&",
    ]

    private static func firstCommandTokens(_ command: String) -> [String] {
        let raw = command.split(separator: " ").map(String.init)
        var head: [String] = []
        for token in raw {
            if shellSeparators.contains(token) { break }
            head.append(token)
        }
        return head
    }
}

// MARK: - Command Definitions

enum OffloadCommandCategory: String, CaseIterable {
    case privacy = "Privacy"
    case media = "Media"
    case system = "System"
}

struct OffloadCommandInfo {
    let name: String
    let displayLabel: String
    let description: String
    let category: OffloadCommandCategory
    /// Only privacy-sensitive commands appear in Settings
    let showInSettings: Bool
    /// 默认权限档（万我 M6.1 增：10-design §8.2 表 :823-851 每命令默认档；
    /// OpenMinis 原表无此字段、未存储时一律回落 .bypass）。
    let defaultLevel: OffloadPermissionLevel
}

// MARK: - Manager

/// Fallback session id used when an offload permission check has no chat session
/// context (e.g. invocations outside the chat flow, or before a session id has
/// been assigned). Mirrors the Android constant `OFFLOAD_GLOBAL_SESSION_ID`
/// (commit 20d8e68) so per-session grants stay wire-compatible across platforms.
/// 【OpenMinis OffloadPermissionManager.swift:118 1:1】
let OFFLOAD_GLOBAL_SESSION_ID = "offload-global"

@MainActor
final class OffloadPermissionManager: ObservableObject {
    static let shared = OffloadPermissionManager()

    /// 27 命令全量元数据（万我 M6.1 增：10-design §8.2 表 :823-851，序=注册序；
    /// 前 19 条 description 沿 OpenMinis 原表 1:1，后 8 条为 WanWo 新增条目）。
    static let allCommands: [OffloadCommandInfo] = [
        // §8.2 #1 ffmpeg（bypass）
        .init(name: "ffmpeg", displayLabel: "FFmpeg", description: "Audio/video transcoding, frame extraction, and metadata", category: .media, showInSettings: false, defaultLevel: .bypass),
        // #2 apple-calendar（askOnce）
        .init(name: "apple-calendar", displayLabel: "Calendar", description: "Events, schedules, and calendar details", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #3 apple-location（askOnce）
        .init(name: "apple-location", displayLabel: "Location", description: "Current GPS coordinates and location history", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #4 apple-weather（askOnce）
        .init(name: "apple-weather", displayLabel: "Weather", description: "Weather forecasts and conditions", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #5 apple-vision（askOnce）
        .init(name: "apple-vision", displayLabel: "Vision", description: "OCR, face, and barcode image analysis", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #6 apple-open（bypass）
        .init(name: "apple-open", displayLabel: "Open URL", description: "", category: .system, showInSettings: false, defaultLevel: .bypass),
        // #7 apple-clipboard（askOnce）
        .init(name: "apple-clipboard", displayLabel: "Clipboard", description: "Text and images copied to the clipboard", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #8 apple-healthkit（askOnce）
        .init(name: "apple-healthkit", displayLabel: "HealthKit", description: "Steps, heart rate, sleep, and other health records", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #9 apple-photos（askOnce）
        .init(name: "apple-photos", displayLabel: "Photos", description: "Photos, videos, and album metadata", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #10 apple-maps（askOnce）
        .init(name: "apple-maps", displayLabel: "Maps", description: "Map search, POI, and navigation links", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #11 apple-nlp（bypass）
        .init(name: "apple-nlp", displayLabel: "NLP", description: "", category: .system, showInSettings: false, defaultLevel: .bypass),
        // #12 apple-alarm（askOnce）
        .init(name: "apple-alarm", displayLabel: "Alarm", description: "System alarms (AlarmKit with version fallback)", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #13 apple-media（askOnce）
        .init(name: "apple-media", displayLabel: "Media", description: "Music library and now-playing", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #14 apple-speak（bypass）
        .init(name: "apple-speak", displayLabel: "Speak", description: "", category: .media, showInSettings: false, defaultLevel: .bypass),
        // #15 apple-speech（askOnce）
        .init(name: "apple-speech", displayLabel: "Speech", description: "Speech recognition", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #16 apple-device（bypass）
        .init(name: "apple-device", displayLabel: "Device", description: "", category: .system, showInSettings: false, defaultLevel: .bypass),
        // #17 apple-homekit（askOnce）
        .init(name: "apple-homekit", displayLabel: "HomeKit", description: "Smart home devices, rooms, and scenes", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #18 apple-notification（bypass）
        .init(name: "apple-notification", displayLabel: "Notification", description: "", category: .system, showInSettings: false, defaultLevel: .bypass),
        // #19 apple-player（askOnce）
        .init(name: "apple-player", displayLabel: "Player", description: "Audio playback", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #20 wanwo-model-use（bypass；OpenMinis minis-model-use 改名，§8.2 注）
        .init(name: "wanwo-model-use", displayLabel: "Model Use", description: "Call LLMs from the shell (list, search, invoke)", category: .system, showInSettings: false, defaultLevel: .bypass),
        // #21 apple-reminders（askOnce）
        .init(name: "apple-reminders", displayLabel: "Reminders", description: "Tasks, due dates, and reminder lists", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #22 apple-bluetooth（askOnce）
        .init(name: "apple-bluetooth", displayLabel: "Bluetooth", description: "BLE scan, connect, and characteristic I/O", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #23 apple-nfc（askOnce）
        .init(name: "apple-nfc", displayLabel: "NFC", description: "NFC tag read and write", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #24 wanwo-sessions-cli（askOnce；minis-sessions-cli 改名）
        .init(name: "wanwo-sessions-cli", displayLabel: "Sessions CLI", description: "Query and operate other chat sessions", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #25 wanwo-browser-use（askOnce；minis-browser-use 改名）
        .init(name: "wanwo-browser-use", displayLabel: "Browser Use", description: "Drive the built-in browser from the shell", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #26 wanwo-config（askOnce；minis-config 改名）
        .init(name: "wanwo-config", displayLabel: "Config", description: "Read and write app settings", category: .privacy, showInSettings: true, defaultLevel: .askOnce),
        // #27 wanwo-debug（bypass；minis-debug 改名）
        .init(name: "wanwo-debug", displayLabel: "Debug", description: "Diagnostics; logs subcommand in all builds", category: .system, showInSettings: false, defaultLevel: .bypass),
    ]

    // MARK: 审批缝（万我 M6.1 增，简报 B1a ②明示形态）

    /// TODO(审批接线)：AppEnvironment 后续把本缝接到 SwiftUI 审批卡（形态对齐
    /// OpenMinis pendingRequest 审批流；本批只定义缝，不接 UI）。回调在任意
    /// 线程调用；第二个参数为应答闭包（YES=allow / NO=deny，只首个生效）。
    var presentApproval: ((PermissionRequest, @Sendable @escaping (Bool) -> Void) -> Void)?

    /// 当前在途审批请求 id（超时判定锚；语义对齐 OpenMinis pendingRequest?.id）。
    private var activeApprovalID: String?

    /// 【批2 B⑦】判定观测缝：AppEnvironment 注入（判定注记 → diagTrace 进
    /// 会话事件流 diag/trace + OSLog 双落点）。参数 = 解析后的 sessionId
    /// （含 OFFLOAD_GLOBAL_SESSION_ID 全局桶——内核路径无会话上下文落此桶，
    /// 无 writer 时 diagTrace 自行降级 OSLog 警告，判定留痕不丢）。
    /// 验收（批2 简报 B⑦）：下次事件流/日志能回答"这条命令为什么被允许/拒绝"
    /// ——checkPermission 每个判定分支（bypass 直通/notAllowed/askOnce 桶命中/
    /// 弹卡/用户允许/用户拒绝/30s 超时/超时竞态）必须各发一条。
    /// 单测不注入 = 缺省 nil，行为零变化（OffloadPermissionManagerTests 前置）。
    var decisionObserver: ((_ sessionId: String, _ note: String) -> Void)?

    /// 审批超时（秒）。生产恒 30s（OpenMinis :266 的 30_000_000_000 ns）；
    /// 仅单测经此注入缩短（万我 M6.1 增 · 测试缝，生产路径不触碰）。
    var approvalTimeoutSeconds: TimeInterval = 30

    /// Per-session "Ask Once" grants: [sessionId: Set<commandName>]
    private var sessionGrants: [String: Set<String>] = [:]

    /// 批12+归挡（2026-09-27 用户裁决）：会话挡位=完全权限时 27 命令整体免问
    /// （askOnce→bypass；notAllowed 显式禁止除外）。由 PermissionCoordinator
    /// 在挡位切换点写（AppEnvironment 装配处接缝），存储层不动。
    var fullAccessOverride = false

    private let defaults: UserDefaults
    private let logger = AppLogger(category: "OffloadPermission")

    /// 存储形态与 OpenMinis 一致（UserDefaults.standard + integer per command）；
    /// init 注入仅供单测隔离（万我 M6.1 增 · 测试缝）。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Storage

    private func defaultsKey(for command: String) -> String {
        "offloadPermission.\(command)"
    }

    func permissionLevel(for command: String) -> OffloadPermissionLevel {
        // 万我 M6.1 修：未存储判定必须用 object(forKey:) —— integer(forKey:)
        // 未存储返回 0，而 rawValue 0 = .bypass 是合法档位，会把"未存储"
        // 误判为 bypass，导致注册表默认档（如 apple-clipboard 的 askOnce）
        // 永远不生效。object(forKey:) 返回 nil 才是真正的未存储。
        if defaults.object(forKey: defaultsKey(for: command)) != nil {
            let raw = defaults.integer(forKey: defaultsKey(for: command))
            if let level = OffloadPermissionLevel(rawValue: raw) {
                return level
            }
        }
        // 未存储时回落注册表默认档（10-design §8.2 每命令默认档；
        // OpenMinis 原件一律回落 .bypass——其表无 defaultLevel 字段）。
        return Self.allCommands.first(where: { $0.name == command })?.defaultLevel ?? .bypass
    }

    func setPermissionLevel(_ level: OffloadPermissionLevel, for command: String) {
        defaults.set(level.rawValue, forKey: defaultsKey(for: command))
    }

    func setAllBypass() {
        for cmd in Self.allCommands {
            setPermissionLevel(.bypass, for: cmd.name)
        }
        sessionGrants.removeAll()
    }

    // MARK: - Permission Check

    func checkPermission(for command: String, sessionId: String?, fullCommand: String = "") async -> PermissionResult {
        // Mirror Android: prefer the caller-supplied session id; fall back to the
        // global bucket when the chat hasn't bound a session yet (or when invoked
        // outside chat). This keeps `Ask Once` grants per-session when possible
        // while still working for non-chat callers.
        // 【OpenMinis :227-232 1:1；内核 trampoline 路径无会话上下文，自然落
        //  OFFLOAD_GLOBAL_SESSION_ID 全局桶——同 App 会话内第二次免弹。】
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sessionId = trimmed.isEmpty ? OFFLOAD_GLOBAL_SESSION_ID : trimmed
        var level = permissionLevel(for: command)
        // 批12+归挡（2026-09-27 用户裁决）：offload 27 命令归入"完全权限"挡
        // ——会话挡位=完全权限时整体免问（askOnce→bypass；notAllowed=用户
        // 显式禁止，不被挡位覆盖）；低挡位按各命令自身档位走（用户手改的
        // bypass 恒 bypass）。持久存储不动，纯运行时覆盖。
        if fullAccessOverride, level == .askOnce {
            level = .bypass
            decisionObserver?(sessionId, "完全权限挡覆盖：\(command) askOnce→bypass（免问）")
        }

        switch level {
        case .bypass:
            // 【批2 B⑦】判定打点：bypass 直通（原分支零打点）。
            logger.info("Permission bypass: \(command)")
            decisionObserver?(sessionId, "bypass 直通：\(command)")
            return .allowed

        case .notAllowed:
            logger.info("Permission denied (Not Allowed): \(command)")
            decisionObserver?(sessionId, "notAllowed 档拒绝：\(command)（用户已在设置禁用）")
            return .denied("Permission denied: the user has disabled '\(command)'. To enable it, go to Settings > Permissions or tap: [Open Permissions](wanwo://settings/permissions)")

        case .askOnce:
            // Check session grant
            if sessionGrants[sessionId]?.contains(command) == true {
                // 【批2 B⑦】判定打点：会话桶命中免弹。
                decisionObserver?(sessionId, "askOnce 会话桶命中（本会话已授权，免弹）：\(command)")
                return .allowed
            }

            let cmdInfo = Self.allCommands.first(where: { $0.name == command })
            let displayLabel = cmdInfo?.displayLabel ?? command
            let description = cmdInfo?.description ?? ""

            let allowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let request = PermissionRequest(
                    id: UUID().uuidString,
                    commandName: command,
                    displayLabel: displayLabel,
                    description: description,
                    fullCommand: fullCommand
                )
                // 防双恢复：审批应答与超时竞争。OpenMinis 靠 pendingRequest
                // 主线程串行化防竞争（:264-271）；缝化后应答回调可能来自任意
                // 线程，改用锁保护 resume-once 标志，语义不变（仅首个生效）。
                let resumeLock = OSAllocatedUnfairLock<Bool>(initialState: false)
                let resumeOnce: @Sendable (Bool) -> Void = { value in
                    let shouldResume = resumeLock.withLock { flag -> Bool in
                        if flag { return false }
                        flag = true
                        return true
                    }
                    if shouldResume {
                        continuation.resume(returning: value)
                    }
                }

                Task { @MainActor in
                    self.activeApprovalID = request.id
                    // TODO(审批接线)：缝未接线时 presentApproval 为 nil——
                    // 等价于无人应答，30s 超时按 deny 收敛（与 OpenMinis
                    // 审批卡无人应答路径语义一致）。
                    // 【批2 B⑦】判定打点：弹卡（呈现面缝未接线时同义=无人应答）。
                    self.decisionObserver?(sessionId,
                                           self.presentApproval == nil
                                           ? "askOnce 审批缝未接线（无人应答，30s 超时=deny）：\(command)"
                                           : "askOnce 弹卡等待用户裁决（30s 超时=deny）：\(command) fullCommand=\(fullCommand)")
                    self.presentApproval?(request, resumeOnce)

                    // 30s timeout（OpenMinis :264-271 同款）
                    let timeoutNanos = UInt64(self.approvalTimeoutSeconds * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: timeoutNanos)
                    if self.activeApprovalID == request.id {
                        self.activeApprovalID = nil
                        // 【批2 B⑦】判定打点：30s 超时 deny（resumeOnce 与
                        // 应答竞争，仅首个生效——应答已先行则本打点不发，
                        // 由 allow/deny 分支打点）。
                        self.decisionObserver?(sessionId, "askOnce 30s 超时未应答 → deny：\(command)")
                        resumeOnce(false)
                    }
                }
            }

            if allowed {
                sessionGrants[sessionId, default: []].insert(command)
                logger.info("Permission granted (Ask Once): \(command)")
                decisionObserver?(sessionId, "askOnce 用户允许（写入会话桶）：\(command)")
                return .allowed
            } else {
                logger.info("Permission denied (Ask Once): \(command)")
                if sessionGrants[sessionId]?.contains(command) == true {
                    // Was granted via timeout race — treat as denied
                    decisionObserver?(sessionId, "askOnce 超时竞态收敛 → deny（应答晚于超时，授权不生效）：\(command)")
                    return .denied("Permission denied: authorization for '\(command)' timed out. To change permissions: [Open Permissions](wanwo://settings/permissions)")
                }
                decisionObserver?(sessionId, "askOnce 用户拒绝：\(command)")
                return .denied("Permission denied: the user declined '\(command)' for this session. To change permissions: [Open Permissions](wanwo://settings/permissions)")
            }
        }
    }

    // MARK: - Session Reset

    func resetSessionGrants(for sessionId: String) {
        sessionGrants.removeValue(forKey: sessionId)
    }

    // MARK: - 内核分发点同步检查入口（万我 M6.1 增，简报 B1a ③）

    /// 内核 offload trampoline 的 C→Swift 检查入口（guest 线程同步调用）。
    /// 经信号量阻塞等待 MainActor 异步检查收敛；≤30s 未收敛按 deny
    /// （简报 ③"阻塞等待 ≤30s=deny"；checkPermission 的 AskOnce 30s 超时
    /// 先行收敛，此处外层等待通常先于其到期返回）。
    /// OpenMinis 无此入口（v2 为设计强制新实现）；检查本体语义 = checkPermission
    /// （内核路径无会话上下文 → sessionId=nil → 全局桶，同 OpenMinis 非聊天
    /// 调用者回退语义 :227-232）。
    nonisolated static func checkForKernel(command: String, fullCommand: String) -> Bool {
        let resultBox = OSAllocatedUnfairLock<Bool>(initialState: false)
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let result = await shared.checkPermission(for: command, sessionId: nil, fullCommand: fullCommand)
            resultBox.withLock { $0 = (result == .allowed) }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            return false
        }
        return resultBox.withLock { $0 }
    }
}
