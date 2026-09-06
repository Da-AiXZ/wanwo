//
//  WanWoEnvStore.swift
//  WanWo
//
//  【薄 stub · 替代 OpenMinis `src/ios/Shared/EnvVarStore.swift`】
//  OpenMinis 的 ISHExecutionCoordinator 在每条命令前经
//  `EnvVarStore.shared.allAsDict()` 注入用户自定义 guest 环境变量。
//  该组件属于 OpenMinis 应用层（不在附录 A 冻结清单），WanWo M0 亦无
//  环境变量配置面，故提供 API 兼容的最小空实现保住原件调用点结构；
//  M2（shell 工具）/M5（env 注入单一来源纪律，08 §三.7.2#8）再按需扩展。
//  不做任何自研新架构。
//

import Foundation

final class WanWoEnvStore {
    static let shared = WanWoEnvStore()

    private init() {}

    /// 用户自定义 guest 环境变量（key=value）。M0 恒为空字典 ——
    /// 调用方（IshExecutorBridge）对空字典不注入 customEnvironment。
    func allAsDict() -> [String: String] {
        [:]
    }
}
