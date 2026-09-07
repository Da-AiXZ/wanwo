//
//  ToolTimeout.swift
//  WanWo
//
//  【语义移植 · dsh】出处：dsh tool-call-timeout-policy（协作式 deadline +
//  TOOL_TIMEOUT 结构化错误；不放弃工具 promise——超时后工具体继续运行至收敛，
//  其结果被丢弃但不被强杀）+ 10-design §5.3（ToolTimeout F019）。
//

import Foundation

enum ToolTimeout {
    /// 结构化超时错误码（dsh TOOL_TIMEOUT）。
    static let timeoutCode = "TOOL_TIMEOUT"

    /// 以协作式 deadline 包住工具体。超时返回 TOOL_TIMEOUT 结构化失败结果；
    /// 工具任务不被取消（promise 不放弃），继续后台运行至自然收敛。
    /// - Parameters:
    ///   - timeoutMs: deadline 毫秒；nil = 无 deadline，直跑。
    ///   - body: 工具体。
    static func run(timeoutMs: Int?,
                    _ body: @escaping @Sendable () async throws -> ToolOutput) async -> ToolOutput {
        guard let timeoutMs, timeoutMs > 0 else {
            do {
                return try await body()
            } catch {
                return Self.failure(from: error)
            }
        }

        let bodyTask = Task { try await body() }
        let deadlineTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
        }

        // 竞速：工具体先完成 → 用其结果；deadline 先到 → 返回结构化超时，
        // 工具体保持运行（dsh 语义：不放弃 promise，不硬杀同进程代码）。
        while true {
            if bodyTask.isCancelled { break }
            if deadlineTask.isCancelled { break }
            if Task.isCancelled {
                // 调用方（回合）取消：按 ABORTED 合成；工具体仍后台收敛。
                deadlineTask.cancel()
                return ToolOutput.failure("tool call aborted", code: "ABORTED", name: "AbortError")
            }
            if bodyTask.isFinished {
                deadlineTask.cancel()
                let output: ToolOutput
                if let value = try? await bodyTask.value {
                    output = value
                } else if let error = bodyTask.error {
                    output = Self.failure(from: error)
                } else {
                    output = ToolOutput.failure("tool failed", code: "TOOL_ERROR")
                }
                return output
            }
            if deadlineTask.isFinished {
                let seconds = Double(timeoutMs) / 1000
                return ToolOutput.failure(
                    "tool timed out after \(String(format: "%.1f", seconds))s",
                    code: Self.timeoutCode, name: "ToolTimeoutError")
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                deadlineTask.cancel()
                return ToolOutput.failure("tool call aborted", code: "ABORTED", name: "AbortError")
            }
        }
        deadlineTask.cancel()
        return ToolOutput.failure("tool call aborted", code: "ABORTED", name: "AbortError")
    }

    /// 错误 → 结构化失败输出（LLMError / 其他一律拍平为 message + UNKNOWN 类码）。
    static func failure(from error: Error) -> ToolOutput {
        if let llmError = error as? LLMError {
            return ToolOutput(text: "Error: \(llmError.message)", isError: true,
                              errorName: "LLMError", errorCode: llmError.code, meta: nil)
        }
        if error is CancellationError {
            return ToolOutput.failure("tool call aborted", code: "ABORTED", name: "AbortError")
        }
        return ToolOutput.failure(String(describing: error), code: "UNKNOWN")
    }
}
