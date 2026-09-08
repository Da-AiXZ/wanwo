//
//  SlashCommandRegistry.swift
//  WanWo
//
//  【按设计新写】出处：10-design §十一 M2.7（斜杠命令 /compact /new /model /help）+
//  dsh packages/interaction/commands（command/run / command/done 事件词汇 1:1）。
//  语义：
//    · 命令输入不进模型上下文（不发 user/message）；落盘 command/run → 执行 →
//      command/done(success|error)，全程可 replay。
//    · /compact 经 AgentLoop.runMaintenance 串行化（idle 才可执行）。
//    · /new 由 AppEnvironment 会话层接管（创建会话并切换 selection）。
//

import Foundation

/// 斜杠命令注册表（M2 四命令 + M3 T2 /permission；M3+ 扩 /model 切换等）。
struct SlashCommandRegistry {
    struct Command {
        let name: String
        let summary: String
        /// 执行体。args = 命令名之后的参数原文（无参为 nil）。返回用户可见
        /// 结果文本；抛错 → command/done(error)。
        let run: (_ args: String?) async -> String
    }

    let commands: [String: Command]

    /// 是否是斜杠命令输入。
    static func isCommand(_ text: String) -> Bool {
        text.hasPrefix("/")
    }

    /// 解析命令名（去 "/"，取首词）。
    static func commandName(_ text: String) -> String {
        String(text.dropFirst().split(separator: " ", omittingEmptySubsequences: true)
            .first.map(String.init) ?? "")
    }

    func command(named name: String) -> Command? {
        commands[name]
    }

    var helpText: String {
        "Available commands:\n"
            + commands.values.sorted { $0.name < $1.name }
                .map { "/\($0.name) — \($0.summary)" }
                .joined(separator: "\n")
    }

    // MARK: - M2 四命令 + M3 T2 /permission 装配

    /// 装配注册表（命令结果落盘由 ChatViewModel 统一记账）。
    /// M3 T3：plan = 计划模式协调器（/plan on|off；nil = 计划模式不可用）。
    static func makeDefault(loop: AgentLoop,
                            environment: AppEnvironment,
                            permission: PermissionCoordinator? = nil,
                            plan: PlanModeController? = nil) -> SlashCommandRegistry {
        // /compact：经 runMaintenance 串行化的强制压缩（idle 才可执行）。
        let compact = Command(name: "compact", summary: "Force a context compaction now") { [weak loop] _ in
            guard let loop else { return "agent unavailable" }
            let writer = loop.deps.writer
            let events = writer.events
            let model = writer.recordedRequestHeader?.config.model
            let result = await loop.runMaintenance {
                let ok = (try? await loop.deps.compactor.compactNow(events: events, model: model) { payload, _ in
                    try await loop.deps.writer.append(payload)
                }) ?? false
                return ok ? "Compaction completed." : "Compaction skipped (nothing compacted)."
            }
            return result
        }
        // /new：创建新会话（selection 切换由命令体完成）。
        let new = Command(name: "new", summary: "Start a new session") { [weak environment] _ in
            guard let environment else { return "environment unavailable" }
            guard (await environment.createSession()) != nil else {
                return "Failed to create session."
            }
            return "New session started."
        }
        // /model：显示当前模型（切换 UI 随 M3 设置页扩展）。
        let model = Command(name: "model", summary: "Show the active model endpoint") { [weak environment] _ in
            guard let environment else { return "environment unavailable" }
            guard let (_, endpoint) = (try? await environment.makeAdapter()) else {
                return "No enabled endpoint configured (see Settings · Providers)."
            }
            return "Active model: \(endpoint.name) · \(endpoint.model)"
        }
        // /permission：权限预设查看/切换（dsh permission-presets handler 语义：
        // 空输入报当前值 + available 清单；未知名报错带清单；切换 = 双旋钮
        // diff 写——approval 持久（approval/policy 事件）、sandbox 内存）。
        let permissionCommand = Command(
            name: "permission", summary: "Show or switch the permission preset") { [weak permission] args in
            guard let permission else { return "permission system unavailable" }
            return await permission.applyPreset(named: args)
        }
        // /plan：进入/离开计划模式（dsh plan-mode index.ts:25-70 handler 语义）。
        // dsh 四态（committed/queued/cancelled/noop）在 WanWo 简化为 committed/
        // noop 两态（无 pending 机制——PlanModeController 偏差 1）；dsh 附加消息
        // 走 agent.steer（M7 缝）——本构建附加消息报不支持（偏差 3，fail closed：
        // 不切模式，防止用户以为已带上消息）。
        let planCommand = Command(
            name: "plan", summary: "Enter or leave plan mode") { [weak plan] args in
            guard let plan else { return "plan mode system unavailable" }
            let message = (args ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if message == "off" {
                do {
                    let changed = try await plan.commit(false, narrate: true)
                    return changed
                        ? "Plan mode off."
                        : "Plan mode is already inactive."
                } catch {
                    return "错误：plan mode 关闭落盘失败（fail closed，状态未变）："
                        + "\(String(describing: error))"
                }
            }
            if !message.isEmpty {
                return "错误：/plan 的附加消息本构建暂不支持（dsh steer 语义随 M7 落地）；"
                    + "模式未切换。用法：/plan 进入计划模式，/plan off 离开。"
            }
            do {
                let changed = try await plan.commit(true, narrate: true)
                return changed
                    ? "Plan mode on. Use /plan off to leave."
                    : "Plan mode is already active."
            } catch {
                return "错误：plan mode 开启落盘失败（fail closed，状态未变）："
                    + "\(String(describing: error))"
            }
        }
        var commands: [String: Command] = [
            "compact": compact,
            "new": new,
            "model": model,
            "permission": permissionCommand,
            "plan": planCommand,
        ]
        let helpText = "Available commands:\n"
            + (commands.values.map { "/\($0.name) — \($0.summary)" }
                + ["/help — Show available commands"])
                .sorted()
                .joined(separator: "\n")
        let help = Command(name: "help", summary: "Show available commands") { _ in
            helpText
        }
        commands["help"] = help
        return SlashCommandRegistry(commands: commands)
    }
}
