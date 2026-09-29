//
//  SessionNotesTypes.swift
//  WanWo
//
//  【语义移植 · Cline Memory Bank · M8 批2 件 B3】出处：
//  repos/cline-main/docs/best-practices/memory-bank.mdx（六文件 schema :19-42、
//  层级 :29-31、更新触发四条件 :142-146）+ cline-deepread.md §1 全量实勘
//  （Memory Bank 在 Cline 是纯 prompt 方法论、内核零实现——万我把"每任务必读"
//  的 prompt 承诺改为内核确定性注入，登记为万我增强，cline-deepread.md §4.1）。
//  万我适配（登记）：
//    · 六文件 → 五文件：productContext.md 并入 projectbrief.md（Cline 层级图
//      :29-31 中 productContext 与 systemPatterns/techContext 同为 brief 下游
//      低频件；万我起步期合并，减少空文件面）。
//    · 每文件固定头标记一行（机器可识别 + 写入校验锚）——Cline 无格式防线，
//      万我增强（markdown 无并发编辑者，全文重写防漂移）。
//    · 注入截断上限 2000 字符/文件（Cline 无注入故无对应常量；与 compaction
//      shared TOOL_RESULT_CHAR_LIMIT=2_000 同量级，登记自拟）。
//

import Foundation

/// 常驻笔记五文件（Cline 六文件裁剪：productContext 并入 brief——登记见件头注）。
/// 职责语义与更新频率逐条对拍 memory-bank.mdx :33-42 表格：
///   projectbrief = 基石（项目级）/ techContext = 低频 / systemPatterns = 低频 /
///   activeContext = 高频（"updates most frequently" :39）/ progress = 里程碑。
enum SessionNoteFile: String, CaseIterable, Sendable {
    case projectbrief
    case techContext
    case systemPatterns
    case activeContext
    case progress

    /// 桶内文件名（Cline memory-bank/*.md 命名 1:1，去 productContext）。
    var fileName: String {
        switch self {
        case .projectbrief: return "projectbrief.md"
        case .techContext: return "techContext.md"
        case .systemPatterns: return "systemPatterns.md"
        case .activeContext: return "activeContext.md"
        case .progress: return "progress.md"
        }
    }

    /// 职责一句话（memory-bank.mdx :33-42 语义；供工具/UI 批复用，本批不预填
    /// 进文件——空文件起步纪律）。
    var roleSummary: String {
        switch self {
        case .projectbrief:
            return "项目基石：核心需求与目标，其他笔记的源头（productContext 语义并入）"
        case .techContext:
            return "技术栈、环境、约束、依赖"
        case .systemPatterns:
            return "架构、设计模式、组件关系"
        case .activeContext:
            return "当前工作焦点、近期变更、下一步（更新最频繁）"
        case .progress:
            return "已完成 / 待建 / 当前状态 / 已知问题（里程碑时更新）"
        }
    }
}

/// 常驻笔记常量（登记自拟值见件头注）。
enum SessionNotesConstants {
    /// 桶目录名（项目根下，项目内可见可手编）。
    static let notesDirName = "wanwo-notes"
    /// 注入截断上限：activeContext / progress 各 2000 字符（超出截断 + 尾注记）。
    static let injectionCharLimit = 2_000
    /// 注入段名（PromptAssembler 段名唯一性键）。
    static let sectionName = "session:notes"
    /// 回合收尾观察追加的截断上限（单条观察块，登记自拟）。
    static let turnObservationCharLimit = 1_000
}

/// 每文件固定头标记（机器可识别一行；写入校验锚——头行被删=拒绝写入）。
/// 形态取 HTML 注释：markdown 渲染不可见，纯文本可读。
enum SessionNotesHeader {
    static func marker(for file: SessionNoteFile) -> String {
        return "<!-- wanwo-session-note v1 | file=\(file.fileName) "
            + "| 万我常驻笔记：本行为机器标记，勿删改 -->"
    }

    /// 校验 content 首个非空行是否为该文件的固定头标记（applyNoteUpdate 写入闸）。
    static func isPresent(in content: String, for file: SessionNoteFile) -> Bool {
        let first = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return first.map {
            $0.trimmingCharacters(in: .whitespaces) == marker(for: file)
        } ?? false
    }

    /// 剥头标记行返回正文（trim 后空 = 空文件语义，注入端零扰动）。
    static func body(afterMarker content: String, for file: SessionNoteFile) -> String {
        guard let firstLineEnd = content.firstIndex(of: "\n") else { return "" }
        return String(content[content.index(after: firstLineEnd)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 常驻笔记错误面。
enum SessionNotesError: Error, CustomStringConvertible {
    /// 头标记缺失/被删——拒绝写入防格式漂移（万我增强，Cline 无格式防线——登记）。
    case headerMarkerMissing(SessionNoteFile)

    var description: String {
        switch self {
        case .headerMarkerMissing(let file):
            return "session note update rejected: fixed header marker for "
                + "\(file.fileName) is missing or modified (content must start "
                + "with the marker line)"
        }
    }
}
