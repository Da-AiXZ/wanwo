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
    /// 批15f：节流——同内容 1 秒内只写一次（防热路径误挂引发 IO/重算风暴，
    /// 批15c 折算分支实证：body 求值路径挂日志 → 同秒数百条 → watchdog 击杀）。
    private static var lastMessage: String = ""
    private static var lastTime: Date = .distantPast

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask)[0]
        return docs.appendingPathComponent("rightRail-diag.log")
    }

    /// 一条诊断事件（调用方把当时的 @MainActor 状态值拼进 message）。
    /// 批15f：双通道留痕——文件写入若静默失败（try? 吞错），UserDefaults
    /// 最近 8 条兜底仍可佐证"埋点是否执行过"；写入失败同步 NSLog 报警。
    static func event(_ message: String) {
        // 节流（主线程判断；event 约定从 MainActor 调用）。
        let now = Date()
        if message == lastMessage, now.timeIntervalSince(lastTime) < 1.0 { return }
        lastMessage = message
        lastTime = now

        logger.info(message) // os.log 同步一份（Debug 控制台可见）
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) | \(message)\n"
        // UserDefaults 兜底通道（主线程安全：event 可能从 MainActor 调）。
        let defaults = UserDefaults.standard
        var trail = defaults.stringArray(forKey: "rightrail-diag-trail") ?? []
        trail.append("\(ts) | \(message)")
        if trail.count > 8 { trail = Array(trail.suffix(8)) }
        defaults.set(trail, forKey: "rightrail-diag-trail")
        queue.async {
            let url = fileURL
            let fm = FileManager.default
            guard let data = line.data(using: .utf8) else { return }
            var wrote = false
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
                wrote = ((try? handle.write(contentsOf: data)) != nil)
            } else {
                wrote = ((try? data.write(to: url, options: .atomic)) != nil)
            }
            if !wrote {
                NSLog("[RightRail] 文件写入失败（Documents/rightRail-diag.log）——事件仅存 UserDefaults 兜底")
            }
        }
    }
}
