//
//  PermissionPresets.swift
//  WanWo
//
//  【语义移植 · dsh permission-presets · M3 T2】出处：
//    - packages/interaction/permission-presets/src/index.ts —— 双旋钮模型
//      KnobState{preset, sandbox, approval}；默认表两条：
//      workspace-write(+ask) / danger-full-access(+never 捆绑)；'custom' 是
//      派生态（保留名，绝不作切换目标/事件载荷——index.ts CUSTOM_PRESET 校验
//      `if (CUSTOM_PRESET in this.presets) throw` 同语义）。T2.2：宿主配置
//      read-only 挡（hostTable，见下注）进入可切换面。
//    - derive 语义：上次显式选择仍与其 bundle 匹配则沿用（still-matching
//      赢共享 bundle 平局）→ 否则取宿主 preset map 首个 (sandbox, approval)
//      命中 → 否则 custom。
//    - apply 语义（diff 写）：preset 名未变不动；旋钮值没变不写
//      （PermissionCoordinator.applyPreset 落点）。
//  WanWo 归一（T2.1 起双旋钮均持久，原 T2 偏差 1 已修）：
//    · sandbox 旋钮 = 持久（sandbox/mode extension 事件折叠，T2.1 补批词汇）；
//    · approval 旋钮 = 持久（approval/policy extension 事件折叠；落盘成功
//      才进内存，fail closed）。
//

import Foundation

/// 预设条目（dsh PresetSpec 的 WanWo 形态：name + 双旋钮 + 展示摘要）。
struct PresetSpec: Equatable, Sendable {
    let name: String
    let sandbox: ApprovalDecisionMatrix.SandboxMode
    let approval: ApprovalPolicy
    let summary: String
}

/// 预设表（dsh permission-presets 语义：默认表 = DEFAULT_PRESETS 两条 1:1 +
/// 宿主配置 read-only 挡；切换目标 = switchableTable 全集）。
enum PermissionPresets {
    /// 派生态保留名（dsh CUSTOM_PRESET）。
    static let custom = "custom"

    /// 默认预设表（dsh DEFAULT_PRESETS 两条 1:1）。
    static let defaultTable: [PresetSpec] = [
        PresetSpec(
            name: "workspace-write",
            sandbox: .workspaceWrite,
            approval: .ask,
            summary: "工作区写入直接放行；其他副作用工具逐次询问"),
        PresetSpec(
            name: "danger-full-access",
            sandbox: .dangerFullAccess,
            approval: .never,
            summary: "沙箱不设限；审批策略捆绑 never（不询问，规则明拒才拦）"),
    ]

    /// 宿主配置预设（T2.2：dsh permission-presets 支持部署方在 DEFAULT_PRESETS
    /// 之外配置预设——PermissionSelect.tsx:44-47 对「host-configured names」
    /// 的宽口径 + settings schema 对 defaultPreset 广播 read-only 挡位
    /// （PermissionRow 三挡下拉/locales.ts:9-11）。WanWo 宿主侧配置 read-only
    /// = 只读沙箱 + ask 审批（最保守档；原 T2 文案「read-only 需自定义预设，
    /// 本构建暂未提供」自本批起失效）。
    static let hostTable: [PresetSpec] = [
        PresetSpec(
            name: "read-only",
            sandbox: .readOnly,
            approval: .ask,
            summary: "仅可查看：写入类调用逐次询问（沙箱只读档）"),
    ]

    /// 可切换/可派生的宿主预设全集（= dsh 宿主 preset map；spec(named:) 与
    /// derive 的查找面）。
    static var switchableTable: [PresetSpec] { defaultTable + hostTable }

    static var availableNames: [String] { switchableTable.map(\.name) }

    static func spec(named name: String) -> PresetSpec? {
        switchableTable.first { $0.name == name }
    }
}

/// 双旋钮状态（dsh KnobState 的 WanWo 形态；线程安全——审批缝在后台线程
/// 读、/permission 在命令任务写）。
final class PermissionKnobs: @unchecked Sendable {
    private let lock = NSLock()
    private var sandboxStorage: ApprovalDecisionMatrix.SandboxMode = .workspaceWrite
    private var approvalStorage: ApprovalPolicy = .ask
    private var lastSelectionStorage: String?

    /// 沙箱旋钮（持久；由 PermissionCoordinator 在 sandbox/mode 事件落盘
    /// 成功后写入——写盘失败绝不进内存，fail closed；T2.1 起不再是内存态）。
    var sandbox: ApprovalDecisionMatrix.SandboxMode {
        get { lock.lock(); defer { lock.unlock() }; return sandboxStorage }
        set { lock.lock(); sandboxStorage = newValue; lock.unlock() }
    }

    /// 审批旋钮（持久；由 PermissionCoordinator 在 approval/policy 事件落盘
    /// 成功后写入——写盘失败绝不进内存，fail closed）。
    var approval: ApprovalPolicy {
        get { lock.lock(); defer { lock.unlock() }; return approvalStorage }
        set { lock.lock(); approvalStorage = newValue; lock.unlock() }
    }

    /// 最近一次显式选择的预设名（derive 的 still-matching 输入）。
    var lastSelection: String? {
        get { lock.lock(); defer { lock.unlock() }; return lastSelectionStorage }
        set { lock.lock(); lastSelectionStorage = newValue; lock.unlock() }
    }

    /// dsh derive：still-matching 显式选择（赢共享 bundle 平局）→ 首个宿主
    /// preset map 命中（switchableTable——含宿主配置 read-only）→ custom。
    func currentPresetName() -> String {
        lock.lock()
        let selection = lastSelectionStorage
        let sandbox = sandboxStorage
        let approval = approvalStorage
        lock.unlock()
        if let selection, let spec = PermissionPresets.spec(named: selection),
           spec.sandbox == sandbox, spec.approval == approval {
            return selection
        }
        if let first = PermissionPresets.switchableTable.first(where: {
            $0.sandbox == sandbox && $0.approval == approval
        }) {
            return first.name
        }
        return PermissionPresets.custom
    }
}
