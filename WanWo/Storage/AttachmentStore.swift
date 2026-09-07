//
//  AttachmentStore.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh attachment（content-addressed 存储 + 准入 +
//  请求投影）+ 10-design §5.1/§四（F042 附件系统）。
//  M2 最小面：read_image 等工具产物的 content-addressed 存档 + 引用描述；
//  上传 UI 通道与降采样随 M9 补齐（07 F042 完整面）。
//

import Foundation
import CryptoKit

/// 附件引用（持久；事件/工具 meta 内可携带）。
struct AttachmentRef: Codable, Equatable, Sendable {
    var id: String
    var fileName: String
    var mimeType: String
    var byteCount: Int
    var storagePath: String
}

/// content-addressed 附件存储（F042 最小面）。
final class AttachmentStore: @unchecked Sendable {
    private let root: URL
    private let lock = NSLock()

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// 收纳一份二进制（SHA-256 内容寻址；同内容幂等）。
    func admit(_ data: Data, fileName: String, mimeType: String) -> AttachmentRef? {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let ext = (fileName as NSString).pathExtension
        let storeName = ext.isEmpty ? hex : "\(hex).\(ext)"
        let fileURL = root.appendingPathComponent(storeName)
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                return nil
            }
        }
        return AttachmentRef(id: hex, fileName: fileName, mimeType: mimeType,
                             byteCount: data.count, storagePath: fileURL.path)
    }

    /// 读取已收纳内容。
    func data(for ref: AttachmentRef) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: ref.storagePath))
    }
}
