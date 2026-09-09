//
//  PermissionDefaultStore.swift
//  WanWo
//
//  【按缝新写 · M3 T2.2】出处（dsh Web UI 原件语义）：
//    - packages/client/ui-permission-presets/src/client/PermissionRow.tsx:1-5
//      ——「the default preset for subsequently created sessions. Current-session
//      switches remain on the composer /permission control」：设置·权限行 =
//      新会话默认预设选择器（App 级持久），与当前会话旋钮完全分离。
//    - packages/client/ui-permission-presets/src/client/settings-store.ts:131-161
//      —— select() 把所选预设写进宿主 Settings（WanWo 宿主面 = 本 store 的
//      JSON 持久文件；T2.2 派单项 2「PermissionKnobs 增 App 级默认源」）。
//    - dsh 笔记 2026-07-23-web-permission-and-approval.md:13 ——
//      BootHostOptions.sandbox 供给部署默认（mode 默认 workspace-write；
//      approvalPolicy 默认 ask）→ 本 store 出厂默认 = workspace-write。
//  可选值 = PermissionPresets.switchableTable（read-only / workspace-write /
//  danger-full-access 三挡，对应 dsh 设置 schema 对 defaultPreset 广播的三挡）。
//  线程模型：PermissionCoordinator 在后台线程读折叠缺省 → NSLock 保护。
//

import Foundation

/// App 级新会话默认权限预设（设置·权限行的持久宿主面）。
final class PermissionDefaultStore: @unchecked Sendable {
    private let lock = NSLock()
    private var valueStorage: String
    private let fileURL: URL

    private static let logger = AppLogger(category: "PermissionDefaultStore")

    /// 出厂默认（dsh BootHostOptions.sandbox 部署默认：workspace-write + ask）。
    static let fallbackPreset = "workspace-write"

    /// 当前新会话默认预设名（恒为 switchableTable 合法成员；非法值在写入口拒绝）。
    var defaultPreset: String {
        lock.lock(); defer { lock.unlock() }
        return valueStorage
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        // 载入已持久值；文件缺失/损坏/值非法 → 回落出厂默认（fail closed：
        // 宁可回到最保守的可用档，不猜用户意图）。
        if let data = try? Data(contentsOf: fileURL),
           let object = try? JSONDecoder().decode([String: String].self, from: data),
           let stored = object["defaultPreset"],
           PermissionPresets.spec(named: stored) != nil {
            valueStorage = stored
        } else {
            valueStorage = Self.fallbackPreset
        }
    }

    /// 设置新会话默认预设（非法名拒绝，返回 false——fail closed）。
    @discardableResult
    func setDefault(named name: String) -> Bool {
        guard PermissionPresets.spec(named: name) != nil else {
            Self.logger.warning("reject invalid default preset \"\(name)\"")
            return false
        }
        lock.lock()
        valueStorage = name
        lock.unlock()
        persist()
        return true
    }

    /// 新会话的初始双旋钮（PermissionCoordinator.restoreKnobs 缺省回落位；
    /// 未知预设名回落 workspace-write + ask——dsh BootHostOptions 部署默认）。
    func newSessionKnobs() -> (sandbox: SandboxMode,
                               approval: ApprovalPolicy) {
        guard let spec = PermissionPresets.spec(named: defaultPreset) else {
            return (.workspaceWrite, .ask)
        }
        return (spec.sandbox, spec.approval)
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(["defaultPreset": defaultPreset])
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("permission default persist failed: \(String(describing: error))")
        }
    }
}
