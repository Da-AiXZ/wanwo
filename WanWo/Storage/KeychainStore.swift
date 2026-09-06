//
//  KeychainStore.swift
//  WanWo
//
//  【按设计新写】出处：10-design §2.3/§5.5（Keychain 存凭据，F057）、
//  dsh credentials apiKeyEnv 引用式语义（key 与端点永不跨代配对）——
//  WanWo 形态：kSecClassGenericPassword，service 固定，account = endpoint id。
//  敏感值永不入日志（§十三.4）。
//

import Foundation
import Security

enum KeychainStore {
    private static let service = "com.wanwo.endpoint"

    /// 保存（覆盖写）。
    static func save(apiKey: String, account: String) throws {
        guard let data = apiKey.data(using: .utf8) else {
            throw NSError(domain: "com.wanwo.keychain", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法编码 API Key"])
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: "com.wanwo.keychain", code: Int(addStatus),
                              userInfo: [NSLocalizedDescriptionKey: "Keychain 写入失败 (\(addStatus))"])
            }
        } else if status != errSecSuccess {
            throw NSError(domain: "com.wanwo.keychain", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain 更新失败 (\(status))"])
        }
    }

    /// 读取（不存在返回 nil）。
    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除（不存在视为成功）。
    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
