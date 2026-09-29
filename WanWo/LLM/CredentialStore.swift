//
//  CredentialStore.swift
//  WanWo
//
//  【语义移植 · dsh · M8 批1 件A2 密钥面】Keychain = dsh `.credentials.yaml`
//  (0600) 的平台正解（派单简报 §二.2 登记适配）。
//  出处（dsh 快照 repos/deepseek-harness-master/）：
//    - packages/api/settings-controller/src/credentials.ts:18-20（批量 describe
//      上限 MAX_DESCRIBE_REFS = 64）、:83-90（describe：一次配置页批量问询，
//      逐 ref 投影只留 configured/source/writable 三字段——:45-51
//      projectCredentialInfo）、:100-105（set：value min(1) 空值拒绝）、
//      :113-118（unset 幂等）；
//    - dsh CredentialInfo（types）：configured / source? / writable——读视图
//      永不含密钥值（"已配置——输入新值可替换" UI 语义的数据基础）；
//    - packages/client/ui-settings-models/src/client/store.ts:111-113
//      （deriveKeyRef：`<ROUTE>_API_KEY` = 大写 + 非字母数字段 → "_"）。
//  万我差异登记：
//    1. dsh wire 面三方法不回传值；宿主请求路径另有 `ctx.credentials.resolve`
//       缝（llm-deepseek/index.ts:430-451 resolveApiKey 消费）。万我请求路径
//       （OpenAICompatAdapter bearer）同构需要值 → 本 store 另设 value(for:)
//       宿主内读值缝，describe 恒不含值语义不变。
//    2. dsh credentialRef 语法 `^[A-Za-z_][A-Za-z0-9_]*$`（credentials.ts:22）
//       不搬：routeApiKeyRef(endpoint.id.uuidString) 可产生数字开头 ref，而
//       Keychain account 接受任意串——语法防线无消费面，登记省略。
//    3. 测试纪律：后端协议注入（CredentialBackend），单测用内存 fake，
//       禁真 Keychain 依赖。
//


import Foundation
import Security

// MARK: - 读视图（冻结契约；禁改名）

/// 密钥状态读视图（dsh CredentialInfo 1:1）——永不含密钥值。
struct CredentialInfo: Equatable, Sendable {
    /// 读视图永不含值（dsh credentials 语义）。
    let configured: Bool
    let source: String?
    let writable: Bool
}

// MARK: - 后端缝（协议注入；单测 fake 后端）

/// 凭据后端缝（Keychain 直存；协议化供单测注入内存 fake——禁真 Keychain 依赖）。
protocol CredentialBackend: Sendable {
    /// 读值（不存在/空 = nil）。
    func readValue(_ ref: String) -> String?
    /// 写值（覆盖写）。
    func writeValue(_ ref: String, value: String) throws
    /// 删值（不存在视为成功——dsh unset 幂等）。
    func deleteValue(_ ref: String)
    /// 来源标签（CredentialInfo.source 数据源）。
    var sourceName: String { get }
}

/// Keychain 后端（kSecClassGenericPassword；service 固定 com.wanwo.credentials，
/// account = ref——与既有 com.wanwo.endpoint（endpoint uuid 账目）同形隔离）。
struct KeychainCredentialBackend: CredentialBackend {
    static let service = "com.wanwo.credentials"
    var sourceName: String { "keychain" }

    func readValue(_ ref: String) -> String? {
        KeychainStore.load(account: ref, service: Self.service)
    }

    func writeValue(_ ref: String, value: String) throws {
        try KeychainStore.save(apiKey: value, account: ref, service: Self.service)
    }

    func deleteValue(_ ref: String) {
        KeychainStore.delete(account: ref, service: Self.service)
    }
}

// MARK: - Store（冻结契约接口）

/// 密钥面（dsh credentials 三方法 + 派生 ref + 宿主内读值缝）。
final class CredentialStore: @unchecked Sendable {
    /// 批量 describe 上限（dsh credentials.ts:20 MAX_DESCRIBE_REFS）。
    static let maxDescribeRefs = 64

    private let backend: any CredentialBackend

    /// - Parameter backend: 凭据后端（缺省 Keychain；单测注入内存 fake）。
    init(backend: any CredentialBackend = KeychainCredentialBackend()) {
        self.backend = backend
    }

    /// 批量读视图（dsh credentials.ts:83-90 describe 语义：一次配置页批量
    /// 问询，按 refs 顺序逐项回答；≤64 上限同源 :18-20——进程内调用方自守，
    /// DEBUG assert 拦越界）。永不含值。
    func describe(refs: [String]) -> [CredentialInfo] {
        assert(refs.count <= Self.maxDescribeRefs,
               "CredentialStore.describe batch bound is \(Self.maxDescribeRefs) (dsh MAX_DESCRIBE_REFS)")
        return refs.map { ref in
            let value = backend.readValue(ref)
            return CredentialInfo(
                configured: !(value?.isEmpty ?? true),
                source: (value?.isEmpty ?? true) ? nil : backend.sourceName,
                writable: true)
        }
    }

    /// 存值（dsh credentials.ts:100-105 set 语义：value min(1)——空值拒绝；
    /// 覆盖写）。
    func set(ref: String, value: String) throws {
        if value.isEmpty {
            throw CredentialStoreError.emptyValue(ref: ref)
        }
        try backend.writeValue(ref, value: value)
    }

    /// 删值（dsh credentials.ts:113-118 unset 语义：幂等，不存在视为成功）。
    func unset(ref: String) {
        backend.deleteValue(ref)
    }

    /// 宿主内读值缝（万我请求路径 bearer 数据源；对拍 dsh
    /// ctx.credentials.resolve——llm-deepseek/index.ts:436 resolve(ref).value。
    /// 读视图 describe 恒不含值的语义不受影响：本缝仅请求路径消费）。
    func value(for ref: String) -> String? {
        let value = backend.readValue(ref)
        return (value?.isEmpty ?? true) ? nil : value
    }

    // MARK: 派生 ref（dsh store.ts:111-115 deriveKeyRef 逐语义）

    /// 派生密钥 ref：`<ROUTE>_API_KEY` = 大写 + 非字母数字段（含 Unicode 非
    /// ASCII）折叠为单个 "_" + `_API_KEY` 后缀。例：`minimax-cn` →
    /// `MINIMAX_CN_API_KEY`（dsh store.ts:111-113 同式）。
    static func routeApiKeyRef(_ route: String) -> String {
        let upper = route.uppercased()
        var out = ""
        var inRun = false
        for scalar in upper.unicodeScalars {
            let isAlnum = (scalar.value >= 0x41 && scalar.value <= 0x5A)   // A-Z
                || (scalar.value >= 0x30 && scalar.value <= 0x39)          // 0-9
            if isAlnum {
                out.unicodeScalars.append(scalar)
                inRun = false
            } else if !inRun {
                out += "_"
                inRun = true
            }
        }
        return out + "_API_KEY"
    }
}

/// 密钥面错误（dsh RemoteError 'credential/rejected' 承载面在万我为本地抛错；
/// 空值拒绝 = dsh setRequestSchema value.min(1) :26）。
struct CredentialStoreError: Error, Equatable {
    var message: String

    static func emptyValue(ref: String) -> CredentialStoreError {
        CredentialStoreError(message: "credential value for \(ref) must not be empty")
    }
}
