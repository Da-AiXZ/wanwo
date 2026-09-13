//
//  BundledSkillInstaller.swift
//  WanWo
//
//  【M4-D 件 D2 附属 · bundled 预装】指纹 marker 幂等安装——codex lib.rs 的
//  bundled marker 思路 + OpenMinis installBundledSkills 参照（简报环 11）。
//  语义：
//    · bundled 技能资源 = App bundle 内 `bundled-skills/` 目录引用（folder
//      reference，保目录结构；project.yml `type: folder`）；
//    · 安装位 = 容器 user 根 skills/.bundled/<name>/…（发现面以 bundled rank
//      单独成根——SkillRegistry.Root(source: .bundled)）；
//    · 指纹 = 按 (相对路径+内容) 的 SHA256（排序确定）；marker 文件
//      .bundled/.install-marker（点前缀——发现面 skipsHiddenFiles 天然跳过，
//      marker 文件名带点前缀为 lead 派单明确）；
//    · 幂等：marker == 当前指纹 → 零改动返回；不匹配（首次/版本升级）→
//      清 .bundled 子目录重写 + 写 marker（版本升级=清子目录重写，派单明确）。
//

import Foundation
import CryptoKit

/// 单个 bundled 技能文件（相对 bundled-skills/ 的路径 + 内容）。
struct BundledSkillFile: Equatable, Sendable {
    /// 形如 "hello-wanwo/SKILL.md"（首段=技能目录名）。
    let relativePath: String
    let data: Data
}

/// bundled 技能安装器（纯函数命名空间；零宿主状态）。
enum BundledSkillInstaller {

    /// marker 文件名（点前缀：发现面 hidden 跳过 + 派单明确）。
    static let markerFileName = ".install-marker"

    // MARK: 资源装载

    /// 生产面：从 bundle 的 `bundled-skills/` 目录引用读取（folder reference）。
    /// 目录引用缺失（无预装）→ []。
    static func bundledFiles(bundle: Bundle = .main) -> [BundledSkillFile] {
        guard let folderURL = bundle.url(forResource: "bundled-skills", withExtension: nil) else {
            return []
        }
        return bundledFiles(in: folderURL)
    }

    /// 目录直读重载（测试注入面）：枚举目录内全部常规文件（含子层——资源目录
    /// 自身结构确定，非发现面递归语义）。
    static func bundledFiles(in folderURL: URL) -> [BundledSkillFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []) else {
            return []
        }
        var files: [BundledSkillFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let prefix = folderURL.path + "/"
            let relative = url.path.hasPrefix(prefix)
                ? String(url.path.dropFirst(prefix.count))
                : url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else { continue }
            files.append(BundledSkillFile(relativePath: relative, data: data))
        }
        return files
    }

    // MARK: 指纹

    /// 指纹 = SHA256( Σ sorted(相对路径 ++ 0x00 ++ 内容) )；排序保证确定性。
    static func fingerprint(_ files: [BundledSkillFile]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            hasher.update(data: Data(file.relativePath.utf8))
            hasher.update(data: Data([0x00]))
            hasher.update(data: file.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 幂等安装

    /// 会话启动调用一次。files 为空 = 无预装（若安装位存在则整目录移除——
    /// 版本升级到空集的收敛形态）。
    /// - Throws: 文件系统错误上抛（调用方 fail open 记日志——bundled 技能
    ///   可选，安装失败不阻塞会话）。
    static func install(files: [BundledSkillFile],
                        targetRoot: URL,
                        fileManager: FileManager = .default) throws {
        let markerURL = targetRoot.appendingPathComponent(markerFileName)
        guard !files.isEmpty else {
            if fileManager.fileExists(atPath: targetRoot.path) {
                try fileManager.removeItem(at: targetRoot)
            }
            return
        }

        let digest = fingerprint(files)
        // 幂等：marker 指纹匹配 → 零改动（marker 为安装态唯一真相——
        // 外部漂移不修复，登记语义）。
        if let existing = try? String(contentsOf: markerURL, encoding: .utf8),
            existing == digest {
            return
        }

        // 版本升级（或首次）：清子目录重写。
        if fileManager.fileExists(atPath: targetRoot.path) {
            try fileManager.removeItem(at: targetRoot)
        }
        try fileManager.createDirectory(at: targetRoot,
                                        withIntermediateDirectories: true)
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            let destination = targetRoot.appendingPathComponent(file.relativePath)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try file.data.write(to: destination, options: .atomic)
        }
        try Data(digest.utf8).write(to: markerURL, options: .atomic)
    }
}
