//
//  SkillImporter.swift
//  WanWo
//
//  【M4-D 件 D7 · F030 迁移导入】Claude/Cursor 等外部技能目录导入（简报件表
//  D7 行：文件选择器源 → 复制 + 宽解析）。语义锚点：发现面双形态承接（dsh
//  skills.md:85——目录 bundle `<name>/SKILL.md` + 平铺 `<name>.md`），导入=
//  复制进 user 根（WanWoPaths.skillsPersistentDir），形态判定在发现面自然发生。
//
//  契约（lead 派单）：
//    · 单/批量智能判定：统一逐项处理路径（单项=批量的 n=1 特例；呈报文案
//      按选中项数区分——视图层职责）；
//    · 同名跳过：目标已存在（目录或文件同名）→ skipped，不覆盖（用户数据
//      防线——覆盖语义登记不做）；
//    · 宽解析：导入不做 kebab/frontmatter 校验（发现面 kebab 校验兜底，
//      错误进 snapshot.errors 设置页可见——登记）；
//    · 非 .md 文件拒收（failed）——技能载体只有两种形态，其余是用户误选。
//
//  安全 scopes：fileImporter 交付的安全作用域 URL 逐项 start/stop
//  （startAccessingSecurityScopedResource 返回 false 时按普通路径继续——
//  测试注入的临时目录 URL 无作用域）。
//

import Foundation

/// 导入结果（逐项三分：导入/跳过/失败；文案呈现归视图层）。
struct SkillImportResult: Equatable, Sendable {
    var imported: [String] = []
    var skipped: [String] = []
    var failed: [String] = []
}

enum SkillImporter {

    /// 把选中的目录/文件复制进 user 技能根。
    /// - Parameters:
    ///   - urls: 选择器交付项（目录或 .md 文件，可多项）。
    ///   - userRoot: user 技能根（WanWoPaths.skillsPersistentDir）。
    static func importItems(at urls: [URL], into userRoot: URL) -> SkillImportResult {
        let fileManager = FileManager.default
        var result = SkillImportResult()
        try? fileManager.createDirectory(at: userRoot,
                                         withIntermediateDirectories: true)

        for url in urls {
            let name = url.lastPathComponent
            // 安全作用域（安全为 false 时按普通路径处理——见头注）。
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                result.failed.append(name)
                continue
            }
            let destination: URL
            if isDirectory.boolValue {
                // bundle 形态：目录整体复制（含 SKILL.md 与伴生资源）。
                destination = userRoot.appendingPathComponent(name, isDirectory: true)
            } else if name.hasSuffix(".md") {
                // 平铺形态：单文件复制。
                destination = userRoot.appendingPathComponent(name)
            } else {
                result.failed.append(name)
                continue
            }
            // 同名跳过（目录与文件同名同判——发现面身份键一致）。
            if fileManager.fileExists(atPath: destination.path) {
                result.skipped.append(name)
                continue
            }
            do {
                try fileManager.copyItem(at: url, to: destination)
                result.imported.append(name)
            } catch {
                Self.logger.error("skill import copy failed for \(name): "
                                  + "\(String(describing: error))")
                result.failed.append(name)
            }
        }
        return result
    }

    private static let logger = AppLogger(category: "SkillImporter")
}
