//
//  CertificateStore.swift
//  WanWo
//
//  【N7b 件①】签名证书三件材料存取（方案 analysis/n7-signing-chain-plan.md
//  §二 N7b-1，用户拍板三项：交付 BuildArtifacts / 密码 Keychain / adhoc
//  p12+profile 导入式）。
//  官方对照（0.10.3 CertificateImporter）：官方只导 p12+密码，存
//  NSUserDefaults 三键（LCCertificateData/Password/UpdateDate），prov 取宿主
//  embedded.mobileprovision——万我 unsigned 分发无宿主有效 profile → 导入式
//  三件套（LiveContainer 上游形态，非自创），存储载体也升级：
//    · 密码（String）→ Keychain（kSecClassGenericPassword，service
//      com.wanwo.signing 与 LLM 凭据 com.wanwo.credentials / MCP
//      com.wanwo.mcp 同形隔离；复用 KeychainStore 既有 SecItem 形态）；
//    · p12 与 mobileprovision（二进制大件）→ App 沙盒 Application
//      Support/WanWoSigning/ 目录文件——iOS Keychain 适合小 secret（密码/
//      token），二进制证书大件走文件+沙盒保护是平台主流做法（Keychain 无
//      增益且读写走 SecItem 序列化，无必要）。
//  密码敏感值永不入日志（KeychainStore 同纪律）。
//

import Foundation
import Security

enum CertificateStore {
    /// 三件材料落盘根目录（Application Support/WanWoSigning/，沙盒内）。
    static let signingDirectory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WanWoSigning", isDirectory: true)
    }()

    /// p12 身份证书文件名。
    private static let p12FileName = "identity.p12"
    /// mobileprovision 描述文件名。
    private static let profileFileName = "signing.mobileprovision"
    /// 签名密码 Keychain service（与 endpoint/credentials/mcp 同形隔离）。
    private static let keychainService = "com.wanwo.signing"
    /// 签名密码 Keychain account。
    private static let passwordAccount = "signing.p12.password"

    // MARK: - 写入

    /// 保存三件材料（覆盖写）：密码入 Keychain，p12/profile 落沙盒文件。
    /// - Parameters:
    ///   - p12: p12 身份证书二进制（PKCS#12）。
    ///   - password: p12 导出密码（原样入 Keychain，允许空串——部分证书无密码）。
    ///   - profile: mobileprovision 描述文件二进制。
    static func save(p12: Data, password: String, profile: Data) throws {
        // 目录确保存在（首次导入时创建；中间目录一并建）。
        try FileManager.default.createDirectory(
            at: signingDirectory, withIntermediateDirectories: true)

        // 密码先行（Keychain 写失败时文件已落盘会留下半套配置——先密钥后文件
        // 的失败面更小：文件可重导，报错即可）。
        try KeychainStore.save(apiKey: password,
                               account: passwordAccount,
                               service: keychainService)

        let p12URL = signingDirectory.appendingPathComponent(p12FileName)
        try p12.write(to: p12URL, options: .atomic)

        let profileURL = signingDirectory.appendingPathComponent(profileFileName)
        try profile.write(to: profileURL, options: .atomic)
    }

    // MARK: - 读取

    /// 读 p12 身份证书数据（不存在读失败 = nil）。
    static func loadCertificateData() -> Data? {
        let url = signingDirectory.appendingPathComponent(p12FileName)
        return try? Data(contentsOf: url)
    }

    /// 读签名密码（Keychain；不存在 = nil）。
    static func loadPassword() -> String? {
        KeychainStore.load(account: passwordAccount, service: keychainService)
    }

    /// 读 mobileprovision 描述文件数据（不存在读失败 = nil）。
    static func loadProfileData() -> Data? {
        let url = signingDirectory.appendingPathComponent(profileFileName)
        return try? Data(contentsOf: url)
    }

    // MARK: - 状态

    /// 三件齐全判定（p12 + profile 文件在位 且 密码 Keychain 在位）。
    /// 文件以"可读出非空数据"为准（删除残留/空文件视为未配置）。
    /// 密码只要求 Keychain 在位——空密码合法（部分证书导出未设密码）。
    static var isConfigured: Bool {
        let passwordReady = loadPassword() != nil
        let p12Ready = isReadableNonEmpty(loadCertificateData())
        let profileReady = isReadableNonEmpty(loadProfileData())
        return passwordReady && p12Ready && profileReady
    }

    /// 数据在位判定（非 nil 且非空）。
    private static func isReadableNonEmpty(_ data: Data?) -> Bool {
        guard let data = data else { return false }
        return !data.isEmpty
    }

    /// 导入时间（设置页状态行展示用；取 p12 文件修改时间，缺 = nil）。
    static var importDate: Date? {
        let url = signingDirectory.appendingPathComponent(p12FileName)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    // MARK: - 清除

    /// 清除三件材料（幂等：不存在视为成功）。
    static func clear() {
        KeychainStore.delete(account: passwordAccount, service: keychainService)
        let p12URL = signingDirectory.appendingPathComponent(p12FileName)
        let profileURL = signingDirectory.appendingPathComponent(profileFileName)
        try? FileManager.default.removeItem(at: p12URL)
        try? FileManager.default.removeItem(at: profileURL)
    }
}
