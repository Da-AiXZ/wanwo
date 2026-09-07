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

/// 斜杠命令注册表（M2 四命令；M3+ 扩 /model 切换、/permissions 等）。
struct SlashCommandRegistry {
    struct Command {
        let name: String
        let summary: String
        /// 执行体。返回用户可见结果文本；抛错 → command/done(error)。
        let run: () async -> String
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

    // MARK: - M2 四命令装配

    /// 装配注册表（命令结果落盘由 ChatViewModel 统一记账）。
    static func makeDefault(loop: AgentLoop,
                            environment: AppEnvironment) -> SlashCommandRegistry {
        // /compact：经 runMaintenance 串行化的强制压缩（idle 才可执行）。
        let compact = Command(name: "compact", summary: "Force a context compaction now") { [weak loop] in
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
        let new = Command(name: "new", summary: "Start a new session") { [weak environment] in
            guard let environment else { return "environment unavailable" }
            guard (await environment.createSession()) != nil else {
                return "Failed to create session."
            }
            return "New session started."
        }
        // /model：显示当前模型（切换 UI 随 M3 设置页扩展）。
        let model = Command(name: "model", summary: "Show the active model endpoint") { [weak environment] in
            guard let environment else { return "environment unavailable" }
            guard let (_, endpoint) = (try? await environment.makeAdapter()) else {
                return "No enabled endpoint configured (see Settings · Providers)."
            }
            return "Active model: \(endpoint.name) · \(endpoint.model)"
        }
        var commands: [String: Command] = [
            "compact": compact,
            "new": new,
            "model": model,
        ]
        let helpText = "Available commands:\n"
            + (commands.values.map { "/\($0.name) — \($0.summary)" }
                + ["/help — Show available commands"])
                .sorted()
                .joined(separator: "\n")
        let help = Command(name: "help", summary: "Show available commands") {
            helpText
        }
        commands["help"] = help
        return SlashCommandRegistry(commands: commands)
    }
}
