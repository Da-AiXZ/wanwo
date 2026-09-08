//
//  FsDiff.swift
//  WanWo
//
//  【语义移植 · dsh · G1】出处：dsh packages/fs/tool-fs/src/diff.ts 1:1
//  （computeHunkDiffs 三行上下文 hunk、diffsFromMeta 防御性收窄）+ write.ts/edit.ts
//  的 presentationMeta/presentResult 持久化语义：
//    · computeHunkDiffs(path, before, after) → 每个变更 hunk 一条 FileDiff，
//      各带 DIFF_CONTEXT=3 行上下文；纯插入 oldText=null；反斜杠 no-newline
//      patch 标记不入内容；分散替换保持独立 hunk；文本相同 → 空数组。
//    · meta 载荷 {diffs: [...]} 随 tool/result.meta 落 JSONL（JSON 可序列化，
//      会话 append 校验），replay 时 presentResult 复现变更卡。
//    · diffsFromMeta：缺失/畸形 → nil（呈现层回退，不抛错——dsh replay 语义）。
//  实现注：dsh 用 npm `diff` 的 structuredPatch；iOS 禁外部依赖 → 纯 Swift
//  行级 LCS。先剪公共前后缀再 DP，规模超限时整段中缀退化为单替换 hunk
//  （呈现层偏差，不影响 meta 持久化契约；偏差记交付报告）。
//

import Foundation

/// 一条变更 hunk（dsh FileDiff；JSON 可序列化——oldText nil 编码为 null）。
struct FileDiff: Equatable, Sendable {
    let path: String
    /// 被替换/删除的行（nil = 纯插入，dsh null 语义）。
    let oldText: String?
    let newText: String
}

// MARK: - hunk 计算

enum FsDiff {

    /// 每个 hunk 两侧展示的上下文行数（dsh DIFF_CONTEXT）。
    static let contextLines = 3

    /// 行级 LCS 的单元格数上限（防 O(n·m) 内存爆 iOS 预算；约 24MB Int32）。
    private static let maxDPCells = 6_000_000

    private enum Op {
        case same(String)
        case del(String)
        case add(String)
    }

    /// 计算 before → after 的每个应用 hunk（各带 contextLines 行上下文）。
    /// 纯插入 oldText=nil；patch 级 no-newline 标记跳过；文本相同 → []。
    static func computeHunkDiffs(path: String, before: String, after: String) -> [FileDiff] {
        guard before != after else { return [] }
        let oldLines = before.components(separatedBy: "\n")
        let newLines = after.components(separatedBy: "\n")

        // 1. 剪公共前后缀（LCS 输入规模缩减；前后缀行原样进 ops）。
        var prefix = 0
        let maxPrefix = min(oldLines.count, newLines.count)
        while prefix < maxPrefix && oldLines[prefix] == newLines[prefix] { prefix += 1 }
        var suffix = 0
        let maxSuffix = min(oldLines.count - prefix, newLines.count - prefix)
        while suffix < maxSuffix
                && oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }
        let midOld = Array(oldLines[prefix..<(oldLines.count - suffix)])
        let midNew = Array(newLines[prefix..<(newLines.count - suffix)])

        var ops: [Op] = oldLines.prefix(prefix).map { .same($0) }
        ops.append(contentsOf: diffMiddle(midOld, midNew))
        ops.append(contentsOf: oldLines.suffix(suffix).map { .same($0) })

        return hunks(from: ops).map { FileDiff(path: path, oldText: $0.old, newText: $0.new) }
    }

    /// 中缀区的行级 LCS → op 序列。规模超限退化为整段替换（单 del 组 + 单 add 组）。
    private static func diffMiddle(_ oldLines: [String], _ newLines: [String]) -> [Op] {
        if oldLines.isEmpty { return newLines.map { .add($0) } }
        if newLines.isEmpty { return oldLines.map { .del($0) } }
        let cells = (oldLines.count + 1) * (newLines.count + 1)
        guard cells <= maxDPCells else {
            // 呈现层降级：不逐行细化，整段按一个替换 hunk 呈现（dsh structuredPatch
            // 无此分支；仅超大文件触发，meta 契约不变）。
            return oldLines.map { .del($0) } + newLines.map { .add($0) }
        }

        // DP 表：L[i][j] = old[i...] 与 new[j...] 的 LCS 长度。
        var lcs = [Int32](repeating: 0, count: cells)
        let w = newLines.count + 1
        for i in stride(from: oldLines.count - 1, through: 0, by: -1) {
            for j in stride(from: newLines.count - 1, through: 0, by: -1) {
                lcs[i * w + j] = oldLines[i] == newLines[j]
                    ? lcs[(i + 1) * w + j + 1] + 1
                    : max(lcs[(i + 1) * w + j], lcs[i * w + j + 1])
            }
        }

        // 回溯产出 op 序列（同长取 del 优先，保证旧文本前置于新增）。
        var ops: [Op] = []
        var i = 0, j = 0
        while i < oldLines.count && j < newLines.count {
            if oldLines[i] == newLines[j] {
                ops.append(.same(oldLines[i])); i += 1; j += 1
            } else if lcs[(i + 1) * w + j] >= lcs[i * w + j + 1] {
                ops.append(.del(oldLines[i])); i += 1
            } else {
                ops.append(.add(newLines[j])); j += 1
            }
        }
        while i < oldLines.count { ops.append(.del(oldLines[i])); i += 1 }
        while j < newLines.count { ops.append(.add(newLines[j])); j += 1 }
        return ops
    }

    /// op 序列 → 带 contextLines 上下文的 hunk（相邻变更间隔 ≤ 2×上下文时合并，
    /// 与 unified diff hunk 语义一致）。
    private static func hunks(from ops: [Op]) -> [(old: String?, new: String)] {
        // 找出全部连续变更段（[start, end)）。
        var runs: [(start: Int, end: Int)] = []
        var index = 0
        while index < ops.count {
            if isChange(ops[index]) {
                let start = index
                while index < ops.count && isChange(ops[index]) { index += 1 }
                runs.append((start, index))
            } else {
                index += 1
            }
        }
        guard !runs.isEmpty else { return [] }

        // 合并：两段间 same 行数 ≤ 2×context 时并入同一 hunk。
        var groups: [(start: Int, end: Int)] = []
        for run in runs {
            if let last = groups.last, run.start - last.end <= 2 * contextLines {
                groups[groups.count - 1].end = run.end
            } else {
                groups.append(run)
            }
        }

        // 每组扩上下文 → 两侧文本（same 行两侧都进；patch '\' 标记不存在于
        // 本实现的行内容，语义等价 dsh 的 skip-'\\'）。
        var out: [(old: String?, new: String)] = []
        for group in groups {
            let start = max(0, group.start - contextLines)
            let end = min(ops.count, group.end + contextLines)
            var oldTexts: [String] = []
            var newTexts: [String] = []
            for op in ops[start..<end] {
                switch op {
                case .same(let line):
                    oldTexts.append(line); newTexts.append(line)
                case .del(let line):
                    oldTexts.append(line)
                case .add(let line):
                    newTexts.append(line)
                }
            }
            // dsh 语义：oldLines 空 → null；newLines 空 → ""（纯删除）。
            out.append((oldTexts.isEmpty ? nil : oldTexts.joined(separator: "\n"),
                        newTexts.joined(separator: "\n")))
        }
        return out
    }

    private static func isChange(_ op: Op) -> Bool {
        if case .same = op { return false }
        return true
    }

    // MARK: - meta 持久化（dsh FsDiffMeta 契约）

    /// meta 载荷 `{diffs: [...]}`（tool/result.meta 落 JSONL，replay 复现变更卡）。
    static func meta(diffs: [FileDiff]) -> JSONValue {
        .object(["diffs": .array(diffs.map encode)])
    }

    private static func encode(_ diff: FileDiff) -> JSONValue {
        .object([
            "path": .string(diff.path),
            "oldText": diff.oldText.map(JSONValue.string) ?? .null,
            "newText": .string(diff.newText),
        ])
    }

    /// 防御性收窄（dsh diffsFromMeta 1:1）：meta 非 object、diffs 缺失/空数组/
    /// 元素畸形 → nil（呈现层回退到调用参数兜底或无卡，不抛错）。
    static func diffsFromMeta(_ meta: JSONValue?) -> [FileDiff]? {
        guard case .object(let dict)? = meta, case .array(let items)? = dict["diffs"],
              !items.isEmpty else { return nil }
        var diffs: [FileDiff] = []
        for item in items {
            guard case .object(let d)? = item,
                  case .string(let path)? = d["path"],
                  case .string(let newText)? = d["newText"] else { return nil }
            let oldText: String?
            switch d["oldText"] {
            case .string(let s): oldText = s
            case .null, .none: oldText = nil
            default: return nil
            }
            diffs.append(FileDiff(path: path, oldText: oldText, newText: newText))
        }
        return diffs
    }

    // MARK: - M2 素净卡摘要（正式 diff 卡族 = M9 对照 dsh Web UI）

    /// hunk 摘要行（重放卡 detail 用；hunk 数 + 增删行数）。
    /// 增删按多重集差计（上下文行两侧等量出现，差值后自然抵消）。
    static func summarize(_ diffs: [FileDiff]) -> String {
        var added = 0, removed = 0
        for diff in diffs {
            let oldCount = Dictionary(grouping: diff.oldText.map { $0.components(separatedBy: "\n") } ?? [],
                                      by: { $0 }).mapValues { $0.count }
            let newCount = Dictionary(grouping: diff.newText.components(separatedBy: "\n"),
                                      by: { $0 }).mapValues { $0.count }
            for (line, n) in newCount { added += max(0, n - (oldCount[line] ?? 0)) }
            for (line, n) in oldCount { removed += max(0, n - (newCount[line] ?? 0)) }
        }
        return "\(diffs.count) hunk\(diffs.count == 1 ? "" : "s") (+\(added) −\(removed))"
    }
}
