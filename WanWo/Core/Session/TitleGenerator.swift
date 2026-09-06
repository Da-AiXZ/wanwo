//
//  TitleGenerator.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh session-title 能力（附录 B #26：LLM 生成 + fallback）、
//  dsh known-event-types 'session/title' / 'session/title-llm-request'、
//  10-design §十一 M1.4（标题自动生成：首轮后 LLM 生成，fallback = 首行截断）。
//  wire 侧走 dsh serialize resolveThinking 的 session-title 分支（thinking 强制关闭）。
//

import Foundation

/// 会话标题生成（F004）。
enum TitleGenerator {
    private static let logger = AppLogger(category: "title")

    /// 首轮结束后生成并落盘标题（失败静默降级为 fallback；不抛出——标题非关键路径）。
    static func generateAndStore(writer: SessionWriter,
                                 database: SessionDatabase,
                                 adapter: OpenAICompatAdapter) async {
        let firstUser = writer.firstUserMessage ?? ""
        guard !firstUser.isEmpty else { return }

        var title: String?
        do {
            // 汇总首轮对话的前若干字符作为生成输入（成本受控）。
            let derived = writer.deriveMessages()
            let context = derived.messages.suffix(2)
                .map { "\($0.role.rawValue): \(String($0.content.prefix(600)))" }
                .joined(separator: "\n")
            let request = LLMRequest(
                baseURL: adapter.endpoint.baseURL,
                apiKey: adapter.apiKey,
                model: adapter.endpoint.model,
                system: "为以下对话生成一个不超过 16 个字的简短标题。直接输出标题本身，"
                    + "不要引号、句号或任何解释。",
                messages: [ChatMessage(role: .user, content: context)],
                maxTokens: 32,
                purpose: "session-title")
            var text = ""
            for try await chunk in adapter.stream(request) {
                if case .textDelta(_, let delta) = chunk {
                    text += delta
                }
                if case .finish = chunk { break }
            }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                title = String(cleaned.prefix(48))
            }
        } catch {
            logger.warning("title LLM generation failed: \(String(describing: error))")
        }

        // fallback：首行截断（dsh session-title fallback 语义）。
        let finalTitle: String
        let source: String
        if let title = title {
            finalTitle = title
            source = "llm"
        } else {
            let firstLine = firstUser.split(separator: "\n", maxSplits: 1).first
                .map(String.init) ?? firstUser
            finalTitle = String(firstLine.prefix(40))
            source = "fallback"
        }

        do {
            try await writer.append(.sessionTitle(title: finalTitle, source: source),
                                    ignorable: true)
            database.setTitle(id: writer.id, title: finalTitle)
        } catch {
            logger.warning("title persist failed: \(String(describing: error))")
        }
    }
}
