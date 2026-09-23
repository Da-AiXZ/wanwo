//
//  RightRailDiag.swift
//  WanWo
//
//  批14：右栏诊断日志（真机定位"开关没反应/铺满"专用）。右栏状态机每个
//  转折点（钮点击/isExpanded·isFullscreen 变化/details 开关/折算触发/深链）
//  追加一行到 Documents/rightRail-diag.log——用户在「文件」App → WanWo 里
//  直接可见可分享，一次复现=完整状态轨迹（AppLogger 的 os.log 用户拿不到，
//  Windows 侧无法连设备控制台；文件共享键 M4-E 已开启）。
//  守护：单文件 512KB 上限，超限截半（诊断日志残行可忽略）。
//

import Foundation

enum RightRailDiag {
    static let logger = AppLogger(category: "RightRail")

    private static let queue = DispatchQueue(label: "com.wanwo.rightrail-diag")
    private static let maxBytes = 512 * 1024

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        return docs.appendingPathComponent("rightRail-diag.log")
    }

    /// 一条诊断事件（调用方把当时的 @MainActor 状态值拼进 message）。
    static func event(_ message: String) {
        logger.info(message) // os.log 同步一份（Debug 控制台可见）
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) | \(message)\n"
        queue.async {
            let url = fileURL
            let fm = FileManager.default
            guard let data = line.data(using: .utf8) else { return }
            if fm.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size > maxBytes {
                    // 大小守护：截留后半（seek 到中点，残行容忍）
                    try? handle.truncate(atOffset: size / 2)
                    _ = try? handle.seek(toOffset: size / 2)
                }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
