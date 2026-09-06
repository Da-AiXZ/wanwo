//
//  AppLogger.swift
//  WanWo
//
//  【中性适配 · 替代 OpenMinis `src/ios/Shared/AppLogger.swift`】
//  逐行保留原实现；唯一差异：去除对 OpenMinis `CrashReporter` 的依赖
//  （WanWo M0 不引入该组件，INFO/WARN/ERROR 仅落 NSLog/os.log）。
//  其余 API（debug/info/notice/warning/error/critical/fault）与
//  @autoclosure DEBUG 抑制语义与原件一致。
//  出处：10-design 附录 A.2 / §十三.8 vendored 改名纪律。
//

import Foundation
import os.log

struct AppLogger {
    let category: String

    init(subsystem: String = "com.wanwo.app", category: String) {
        self.category = category
    }

    private static let oslog = Logger(subsystem: "com.wanwo.app", category: "ish")

    // [T-ios-log-noise-reduction] DEBUG is suppressed in Release builds so
    // diagnostic chatter (agentHistory dumps, per-record sync traces, etc.)
    // downgraded to `.debug()` adds zero cost / zero noise to shipped logs,
    // while staying available to developers running a Debug build. Use
    // `@autoclosure` so the message string isn't even built in Release —
    // the interpolation cost is skipped entirely, not just the NSLog.
    func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        log("DEBUG", message())
        #endif
    }
    func info(_ message: String)     { log("INFO", message) }
    func notice(_ message: String)   { log("NOTICE", message) }
    func warning(_ message: String)  { log("WARN", message) }
    func error(_ message: String)    { log("ERROR", message) }
    func critical(_ message: String) { log("CRIT", message) }
    func fault(_ message: String)    { log("FAULT", message) }

    private func log(_ level: String, _ message: String) {
        NSLog("[%@] [%@] %@", category, level, message)
        if level == "INFO" || level == "WARN" || level == "ERROR" {
            // 【中性适配】替代 OpenMinis 的 CrashReporter.appendLog：
            // M0 无崩溃收集组件，改写 os.log（subsystem com.wanwo.app）留存。
            let ts = Date().formatted(.dateTime.hour().minute().second())
            Self.oslog.notice("[\(ts)] [\(self.category)] \(message, privacy: .public)")
        }
    }
}
