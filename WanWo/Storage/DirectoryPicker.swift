//
//  DirectoryPicker.swift
//  WanWo
//
//  【M6.5 新写 · 语义源 dsh directory-picker 双后端（workspace.zh.md :138-184）】
//  dsh：`pick`（OS 原生选择器）+ `list`/`createDirectory`（应用内浏览器）两个后端，
//  一个组合后端服务两者、服务不了的动词拒绝而非近似。
//  iOS 不可抗力映射（10-design §6⑤:669 同款）：
//    · pick     → UIDocumentPickerViewController(.folder)（SwiftUI 壳
//                 FolderPicker 已随 MountedFoldersSettingsView 落地，复用）。
//    · list / createDirectory → 应用内浏览后端：WanWo 无现成目录浏览面（报告
//                 标注），本批不实现——动词拒绝而非近似（dsh 口径）。
//
//  本批落：picked URL → guest 工作区路径的映射缝（纯逻辑，可测）。WorkspacePicker
//  的设置页/侧栏 UI 流程随 B4 左侧栏欠账（§9 #5=添加工作区按钮），接线点在
//  本文件注释标明。
//

import Foundation

/// directory-picker 后端能力（dsh DirectoryPickerCapability 对应）。
enum DirectoryPickerCapability: Equatable {
    /// OS 原生选择器（iOS = UIDocumentPicker）。
    case native
    /// 应用内浏览器（list/createDirectory；WanWo 暂无浏览面——不可用）。
    case browse
}

/// directory-picker 缝（dsh ctx.directoryPicker 的 WanWo 本地对应）。
enum DirectoryPicker {

    /// 本后端可服务的动词面：仅 pick（native）。list/createDirectory 拒绝
    /// （dsh「动词组合服务不了就拒绝而非近似」——报告标注待应用内浏览面）。
    static func capability() -> DirectoryPickerCapability {
        return .native
    }

    enum MapError: Error, LocalizedError {
        case notMappedToGuest
        case notUnderActiveMount

        var errorDescription: String? {
            switch self {
            case .notUnderActiveMount:
                return "所选文件夹尚未挂载。请先在「设置 · 外挂载文件夹」中挂载该文件夹，再添加为工作区。"
            case .notMappedToGuest:
                return "无法把所选文件夹映射为会话工作目录。"
            }
        }
    }

    /// pick 结果 → guest 工作区路径映射缝（WorkspacePicker(B4) 调用点）。
    ///
    /// 工作区 path 必须是 **guest 侧可 cd 的目录**（新会话 cwd 注入该 path）。
    /// UIDocumentPicker 返回宿主 URL，两段映射：
    ///   1. 命中某个激活外挂载的宿主规范根 → /var/wanwo/mounts/<name>[/<rel>]
    ///      （外挂载目录在 fakefs 内真实可见——语义等价 dsh pick 的宿主目录）。
    ///   2. 未命中任何挂载 → 拒绝（引导先挂载——拒绝而非近似，dsh 口径）。
    ///
    /// 返回 guest 路径（可直入 WorkspaceRegistry.create(path:)）。
    static func mapPickedURLToGuestPath(_ picked: URL) throws -> String {
        let hostRootFor: (String) -> String? = { name in
            Thread.isMainThread
                ? MainActor.assumeIsolated {
                    MountedFoldersManager.shared.canonicalHostPath(forName: name)
                        ?? MountedFoldersManager.shared.resolvedURL(forName: name)?.path
                }
                : DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        MountedFoldersManager.shared.canonicalHostPath(forName: name)
                            ?? MountedFoldersManager.shared.resolvedURL(forName: name)?.path
                    }
                }
        }
        let names: [String] = Thread.isMainThread
            ? MainActor.assumeIsolated { MountedFoldersManager.shared.entries.map(\.name) }
            : DispatchQueue.main.sync {
                MainActor.assumeIsolated { MountedFoldersManager.shared.entries.map(\.name) }
            }

        let pickedPath = picked.standardizedFileURL.path
        // 最长前缀优先（嵌套挂载名防误命中）。
        var best: (name: String, root: String)?
        for name in names {
            guard let root = hostRootFor(name) else { continue }
            let rootStd = URL(fileURLWithPath: root).standardizedFileURL.path
            if pickedPath == rootStd
                || pickedPath.hasPrefix(rootStd + "/") {
                if best == nil || rootStd.count > best!.root.count {
                    best = (name, rootStd)
                }
            }
        }
        guard let hit = best else {
            throw MapError.notUnderActiveMount
        }
        let rel = pickedPath == hit.root
            ? ""
            : String(pickedPath.dropFirst(hit.root.count + 1))
        return rel.isEmpty
            ? "\(WanWoPaths.mountsLinuxDir)/\(hit.name)"
            : "\(WanWoPaths.mountsLinuxDir)/\(hit.name)/\(rel)"
    }

    /// dsh `list(path)` 动词：应用内浏览后端缺位——显式拒绝（不可抗力，报告标注；
    /// WorkspacePicker 的浏览形态随 B4 评估是否补 face）。
    static func list(path: String?) throws -> Never {
        throw MapError.notMappedToGuest
    }

    /// dsh `createDirectory(path, name)` 动词：同上，显式拒绝。
    static func createDirectory(path: String, name: String) throws -> Never {
        throw MapError.notMappedToGuest
    }
}
