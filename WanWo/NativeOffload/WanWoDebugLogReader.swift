//
//  WanWoDebugLogReader.swift
//  WanWo
//
//  【语义移植 · 源=OpenMinis src/ios/Debug/MinisDebugLogReader.swift 全文 164 行
//   （B1c 批）】`wanwo-debug logs` CLI 子命令的进程内日志读取桥（ObjC 侧经
//  NSClassFromString("WanWoDebugLogReader") 动态触达，见 DebugOffload.m）。
//  适配点（其余语义 1:1）：
//   1. 类名 MinisDebugLogReader → WanWoDebugLogReader（改名纪律——ObjC 侧
//      字符串同步）；
//   2. 【删除】LoggingManager 日日文件 fallback（源 :105-140 + :52-58 的 note
//      分支）——WanWo 无 LoggingManager 组件（AppLogger 仅 NSLog + os.log，
//      见 AppLogger.swift 头注）；OSLogStore 主路径语义与原件完全一致
//      （AppLogger 的 NSLog 输出被系统桥接进 unified log）。
//   3. 文件头注释出处注记改写。
//  NOTE: not `#if DEBUG`-gated — Release availability is the whole point
//  (T-ios-minis-debug-logs-oslogstore)。
//

import Foundation
import OSLog

/// In-process log reader for the `wanwo-debug logs` CLI subcommand.
///
/// Unlike the rest of the wanwo-debug CLI (whose RPC-backed subcommands route
/// through `DebugLocalDispatch` / `DebugJSONRPC` — not ported to WanWo), this
/// reader is intentionally **available in Release builds**. It lets a user
/// reproducing a bug on their own Release device read the app's own runtime
/// log output (StopDiag / RetryDiag etc.) without attaching Xcode.
///
/// Source (WanWo 形态——原件双源取一)：
///   1. `OSLogStore(scope: .currentProcessIdentifier)` (iOS 15+) — the unified
///      log buffer for this process. `AppLogger` writes via `NSLog`, which the
///      system bridges into the unified log, so `logger.info/.warning/.error`
///      lines land here with the full "[Category] [LEVEL] message" text as the
///      composed message.
///
@objc public final class WanWoDebugLogReader: NSObject {

    @objc(sharedInstance)
    public static let shared = WanWoDebugLogReader()

    private override init() { super.init() }

    /// Read recent log lines and return a JSON string:
    ///   { "source": "oslog"|"none", "count": N, "lines": [String],
    ///     "note": String? }
    /// All filters are optional:
    ///   - lastN:    keep only the most recent N matching lines (<= 0 = no cap)
    ///   - minutes:  only entries from the last N minutes (<= 0 = no time bound)
    ///   - grep:     case-insensitive substring filter (nil/empty = no filter)
    ///
    /// Synchronous and side-effect free; safe to call from the offload thread.
    @objc public func readLogsJSON(lastN: Int, minutes: Int, grep: String?) -> String {
        let keyword = (grep?.isEmpty == false) ? grep : nil
        let sinceDate: Date? = minutes > 0 ? Date(timeIntervalSinceNow: -Double(minutes) * 60) : nil

        // Primary: unified log store for this process（原件双源取一：
        // LoggingManager 文件 fallback 不移植，见头注适配点 2）。
        if let osResult = readFromOSLogStore(lastN: lastN, since: sinceDate, keyword: keyword),
           !osResult.isEmpty {
            return Self.encode(source: "oslog", lines: osResult, note: nil)
        }

        return Self.encode(
            source: "none",
            lines: [],
            note: "No matching log entries. OSLogStore returned nothing."
        )
    }

    // MARK: - OSLogStore

    private func readFromOSLogStore(lastN: Int, since: Date?, keyword: String?) -> [String]? {
        guard #available(iOS 15.0, *) else { return nil }
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            // Bound the scan: prefer the explicit time window; otherwise look
            // back a generous default so `--last N` has enough to choose from
            // without walking the entire process lifetime.
            let position: OSLogPosition
            if let since {
                position = store.position(date: since)
            } else {
                position = store.position(date: Date(timeIntervalSinceNow: -3600)) // last hour
            }
            let entries = try store.getEntries(at: position)

            var lines: [String] = []
            for entry in entries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                if let since, logEntry.date < since { continue }
                // AppLogger's NSLog output is the composed message; it already
                // contains "[Category] [LEVEL] message". Prefix with a short
                // timestamp for readability.
                let msg = logEntry.composedMessage
                if let keyword, msg.range(of: keyword, options: .caseInsensitive) == nil { continue }
                let ts = Self.timeFormatter.string(from: logEntry.date)
                lines.append("[\(ts)] \(msg)")
            }
            if lastN > 0, lines.count > lastN {
                lines = Array(lines.suffix(lastN))
            }
            return lines
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func encode(source: String, lines: [String], note: String?) -> String {
        var dict: [String: Any] = [
            "source": source,
            "count": lines.count,
            "lines": lines,
        ]
        if let note { dict["note"] = note }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"source\":\"none\",\"count\":0,\"lines\":[],\"note\":\"JSON encode failed\"}"
        }
        return str
    }
}
