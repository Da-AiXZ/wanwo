//
//  WOFluidDiag.swift
//  WanWo
//
//  【流体逐帧诊断探针】侧栏开合流体重排引擎的零行为变化逐帧取证。
//    · 运行时静态开关（Release 包可用——CI 走 Release 配置，严禁 #if DEBUG
//      包裹；排除干扰时置 false 即全链静默）。
//    · 环形缓冲 8192 行，O(1) 摊销 append；dump 落 Documents/fluid-diag.log
//      （256KB 截半守护——WOMessageListView.swift 里 WOLayoutDiag.write 同款
//      写文件模式）。
//    · record = 高频逐帧事件入缓冲（dump 统一落盘）；note = 低频关键事件
//      不入缓冲、直接单独落一行（防被高频帧淹没——FLUID-SWITCH / SETTLE-SNAP
//      / ANCHOR-RESTORE 用）。
//    · dump 后清空缓冲并重置时间基准（每段取证自带独立时间轴）。
//    · 线程约定：插桩点全部位于 MainActor（WOMessageListCore），record/note
//      的缓冲读写恒主线程执行；文件 IO 走独立串行队列（WOLayoutDiag 同款）。
//

import Foundation
import QuartzCore

enum WOFluidDiag {
    /// 运行时开关（诊断构建恒 true）。
    static var enabled = true

    // MARK: 环形缓冲（主线程读写）

    /// 环形缓冲容量（行）。
    private static let capacity = 8192
    private static var ring: [String?] = Array(repeating: nil, count: capacity)
    /// 下一个写入槽位。
    private static var head = 0
    /// 当前有效行数（≤ capacity）。
    private static var count = 0
    /// 时间基准：首条 record 采样 CACurrentMediaTime()；dump 后重置。
    private static var t0: CFTimeInterval?

    // MARK: 文件落盘

    /// 文件写入串行队列（缓冲读写恒主线程，只有 IO 在此队列）。
    private static let queue = DispatchQueue(label: "com.wanwo.fluid-diag")
    /// 文件大小守护阈值（256KB 截半）。
    private static let maxFileSize = 256 * 1024

    /// 高频逐帧事件：入环形缓冲（不立即落盘——由 dump 统一落）。
    /// 行前缀 "+0.1234s"（相对 t0 的偏移；首条记录时采样 t0）。
    static func record(_ line: String) {
        guard enabled else { return }
        if t0 == nil { t0 = CACurrentMediaTime() }
        let elapsed = CACurrentMediaTime() - (t0 ?? 0)
        ring[head] = String(format: "+%.4fs ", elapsed) + line
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    /// 低频关键事件：不入缓冲，直接单独落一行到 fluid-diag.log
    ///（防被高频帧淹没；保证必落盘）。
    static func note(_ line: String) {
        guard enabled else { return }
        let prefix = t0.map { String(format: "+%.4fs ", CACurrentMediaTime() - $0) } ?? ""
        writeToFile("NOTE " + prefix + line)
    }

    /// 缓冲全量落盘（带 reason 头行）；落盘后清空缓冲 + 重置时间基准。
    static func dump(reason: String) {
        guard enabled else { return }
        var lines: [String] = []
        lines.reserveCapacity(count + 1)
        let oldest = (head - count + capacity) % capacity
        for i in 0..<count {
            if let line = ring[(oldest + i) % capacity] {
                lines.append(line)
            }
        }
        lines.append("=== dump(\(reason)) ===")
        writeToFile(lines.joined(separator: "\n"))
        // 清空缓冲 + 重置时间基准（下段取证独立时间轴）。
        for i in 0..<capacity { ring[i] = nil }
        head = 0
        count = 0
        t0 = nil
    }

    /// 落盘实现（WOLayoutDiag.write 同款：串行队列 + 256KB 截半守护）。
    private static func writeToFile(_ text: String) {
        let payload = text + "\n"
        queue.async {
            let url = FileManager.default.urls(for: .documentDirectory,
                                               in: .userDomainMask)[0]
                .appendingPathComponent("fluid-diag.log")
            let fm = FileManager.default
            guard let data = payload.data(using: .utf8) else { return }
            if fm.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size > maxFileSize {
                    try? handle.truncate(atOffset: size / 2)
                    _ = try? handle.seek(toOffset: size / 2)
                }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
