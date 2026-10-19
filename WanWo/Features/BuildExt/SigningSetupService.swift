//
//  SigningSetupService.swift
//  WanWo
//
//  【N7b 件③】签名环境校验（万我版 checkSigningSetup，方案 §二 N7b-3）。
//  官方对照（main UI/CodeSigCheck.swift checkSigningSetup，140 行三段）：
//    ①NXApplicationState.extensionExists ②extensionCorrectlyEntitled
//    （get-task-allow）③LCUtils.validateCertificate——失败 alert 引导导入。
//  万我裁剪（登记）：
//    · ①②段（extension 存在性/entitlement 检查）**不做**——万我暂无 appex，
//      该两段服务 LC 容器化运行链（N8/N9 范畴落 PEProcessManager/LiveProcess
//      时再补）；
//    · ③段改走 ZSigner.checkCertWithProv:key:pass:completionHandler: 直调
//      （ZSigner 已在主 App 编译面，N7a 落位；LCUtils.validateCertificate 底层
//      即此调用，0.10.3 LCUtils.m 同构——绕过其 NSUserDefaults 证书读取缝，
//      万我证书在 CertificateStore）。prov 参数 = 用户导入的 mobileprovision
//      数据（非宿主 embedded——万我 unsigned 分发无宿主有效 profile，这正是
//      导入式三件套的原因）。
//    · status==0 为有效（zsigner.h 契约）；expirationDate = 证书有效期。
//

import Foundation

/// 证书校验结果读视图（设置页状态行 + N7c 签名编排 gate 共用）。
struct SigningCertificateStatus: Equatable, Sendable {
    /// 三件材料齐全（CertificateStore.isConfigured）。
    let configured: Bool
    /// checkCert status==0（zsigner.h 契约：0 = 有效）。
    let isValid: Bool
    /// 证书有效期（checkCert 回传；未配置/校验失败 = nil）。
    let expirationDate: Date?
    /// 人读状态描述（设置页状态行直显）。
    let message: String
}

enum SigningSetupService {
    /// 校验签名证书配置（async——checkCert 回调桥接为 await）。
    /// 未配置时短路返回（不触发 ZSigner）。
    static func validateCertificate() async -> SigningCertificateStatus {
        guard CertificateStore.isConfigured else {
            return SigningCertificateStatus(
                configured: false,
                isValid: false,
                expirationDate: nil,
                message: "未配置——请导入 adhoc 证书（p12 + 描述文件 + 密码）")
        }

        // 三件在位（isConfigured 已判）后逐一加载；防竞态兜底再守一层。
        guard let p12Data = CertificateStore.loadCertificateData(),
              let profileData = CertificateStore.loadProfileData(),
              let password = CertificateStore.loadPassword() else {
            return SigningCertificateStatus(
                configured: false,
                isValid: false,
                expirationDate: nil,
                message: "证书材料读取失败——请重新导入")
        }

        let outcome: CheckOutcome = await withCheckedContinuation { continuation in
            // ZSigner ObjC 桥接形态：checkCertWithProv:key:pass:completionHandler:
            // → checkCert(withProv:key:pass:completionHandler:)（首参 merge 进
            // 方法名）；block (int, NSDate*, NSString*) → (Int32, Date?, String?)。
            // 返回 int 为同步失败码（仅参数为空等前置错——回调路径才是权威判定）。
            _ = ZSigner.checkCert(
                withProv: profileData, key: p12Data, pass: password
            ) { status, expirationDate, error in
                let outcome = CheckOutcome(
                    status: status,
                    expirationDate: expirationDate,
                    error: error)
                continuation.resume(returning: outcome)
            }
        }

        let message = message(for: outcome)
        return SigningCertificateStatus(
            configured: true,
            isValid: outcome.status == 0,
            expirationDate: outcome.expirationDate,
            message: message)
    }

    // MARK: N8 · extension 两段收口（官方 main checkSigningSetup ①②段语义，
    // N7b 预留 stub 的本批收口；diff 登记 docs/gpl-compliance.md §N8）

    /// ① extensionExists：PlugIns/WanWoLiveProcess.appex 存在性（官方
    /// NXApplicationState.extensionExists 同语义；vendored PEExtension.m 的
    /// liveProcessIsAvailable 同判据——start_environment constructor 的
    /// ignition 启动闸门，缺失=extension-less 模式 guest 不可运行）。
    static var extensionExists: Bool {
        guard let plugInsPath = Bundle.main.builtInPlugInsPath else {
            return false
        }
        let appexPath = plugInsPath + "/WanWoLiveProcess.appex"
        return FileManager.default.fileExists(atPath: appexPath)
    }

    /// ② entitlement 判定：读导入 profile 的 get-task-allow（万我语义适配——
    /// 官方读 appex 内嵌 profile 的 get-task-allow；万我 unsigned 分发的权威
    /// profile = 用户导入三件套，guest 签名身份由它决定——N7c bundle id 对齐
    /// 同源。appex 随整包重签后其 profile 即用户导入件，语义一致）。
    static func extensionAllowsDebug() -> Bool {
        guard let profileData = CertificateStore.loadProfileData() else {
            return false
        }
        return Self.profileAllowsDebug(profileData)
    }

    /// profile 数据 → Entitlements["get-task-allow"] 布尔判定。解析复用 N7c
    /// 字节级 range(of:) 形态（mobileprovision=CMS 包裹明文 plist，二进制安全；
    /// String(utf8) 整包解码会因 CMS 二进制字节失败——N7c 装机实证）。
    static func profileAllowsDebug(_ data: Data) -> Bool {
        guard let startRange = data.range(of: Data("<?xml".utf8)),
              let endRange = data.range(of: Data("</plist>".utf8)),
              endRange.upperBound > startRange.lowerBound else {
            return false
        }
        let xmlData = data.subdata(in: startRange.lowerBound..<endRange.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(
                from: xmlData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return false
        }
        return (entitlements["get-task-allow"] as? Bool) ?? false
    }

    /// 组合读视图（官方 checkSigningSetup 三段语义 ①②③；③=validateCertificate
    /// 既有。万我不弹 alert——无官方 NXWindowServer rootVC 呈现缝，文本回流）。
    static func runtimeSetupSummary() async -> String {
        if !extensionExists {
            return "extension MISSING（PlugIns/WanWoLiveProcess.appex 不存在——extension-less 模式，guest 不可运行）"
        }
        if !extensionAllowsDebug() {
            return "extension entitlement FAIL（导入 profile 无 get-task-allow——需 Developer 证书 profile，Distribution profile 不支持）"
        }
        let status = await validateCertificate()
        if status.isValid {
            return "signing setup OK（extension 存在 ✓ / get-task-allow ✓ / 证书有效）"
        }
        return "certificate INVALID（extension ✓ / get-task-allow ✓，但 checkCert 失败：" + status.message + "）"
    }

    // MARK: - 内部承载

    /// checkCert 回调一次快照（continuation 只能 resume 一次——值类型承载）。
    private struct CheckOutcome: Sendable {
        let status: Int32
        let expirationDate: Date?
        let error: String?
    }

    /// 状态描述组装（拆步局部变量——swiftc type-check 雷区形态规避）。
    private static func message(for outcome: CheckOutcome) -> String {
        if outcome.status == 0 {
            return "证书有效"
        }
        if let error = outcome.error, !error.isEmpty {
            return "证书校验失败：\(error)"
        }
        let detail = "status \(outcome.status)"
        return "证书校验失败（\(detail)）"
    }
}
