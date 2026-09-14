//
//  JSCodeEngineProbeTests.swift
//  WanWoTests
//
//  【真机批 B 定位探针】复刻用户真机 run_code 场景（CI 快速通道——
//  真机面包屑实证：Promise.all + binding 并行场景 logs=0/binding 调用
//  零次/程序异常收尾，疑似 async 续体推进缺口）。CI 每轮 4 分钟，
//  本文件用于快速复现与修复验证；定位完成后本文件保留为回归锚。
//

import XCTest
@testable import WanWo

final class JSCodeEngineProbeTests: XCTestCase {

    private func makeRuntime(maxWallMs: Double = 30_000) throws -> JSCodeRuntime {
        try JSCodeRuntime(config: JSCodeRuntimeConfig(maxWallMs: maxWallMs))
    }

    /// 复刻 1：Promise.all + 两个 binding 并行（真机程序的核心形态——
    /// 面包屑实证 binding 调用零次/程序以 success 收尾/logs=0 的场景）。
    func testPromiseAllTwoBindingCalls() async throws {
        let runtime = try makeRuntime()
        let request = CodeRunRequest(
            program: """
            const r = await Promise.all([tools.echo({i:1}), tools.echo({i:2})]);
            return r;
            """,
            bindings: [CodeBindingNamespace(
                global: "tools",
                functions: ["echo": { args in return args }])])
        let result = await runtime.run(request)
        XCTAssertNil(result.error, "error: \(result.error?.message ?? "")")
        XCTAssertEqual(result.value, .array([
            .object(["i": .int(1)]), .object(["i": .int(2)]),
        ]))
    }

    /// 复刻 2：console.log 输出进 logs（真机 logs=0 的疑点）。
    func testConsoleLogCapturedIntoLogs() async throws {
        let runtime = try makeRuntime()
        let request = CodeRunRequest(
            program: """
            console.log("before");
            const v = await tools.echo({ok:true});
            console.log("after", JSON.stringify(v));
            return v;
            """,
            bindings: [CodeBindingNamespace(
                global: "tools",
                functions: ["echo": { args in return args }])])
        let result = await runtime.run(request)
        XCTAssertNil(result.error, "error: \(result.error?.message ?? "")")
        XCTAssertTrue(result.logs.contains("before"), "logs=\(result.logs)")
        XCTAssertTrue(result.logs.contains(where: { $0.contains("after") }), "logs=\(result.logs)")
    }

    /// 复刻 3：慢 binding（1 秒挂起后返回——真机 web_fetch 形态）。
    func testSlowBindingResolves() async throws {
        let runtime = try makeRuntime(maxWallMs: 20_000)
        let request = CodeRunRequest(
            program: """
            const a = await tools.slow({ms: 800});
            return a;
            """,
            bindings: [CodeBindingNamespace(
                global: "tools",
                functions: ["slow": { args in
                    try await Task.sleep(nanoseconds: 800_000_000)
                    return args
                }])])
        let result = await runtime.run(request)
        XCTAssertNil(result.error, "error: \(result.error?.message ?? "")")
        XCTAssertEqual(result.value, .object(["ms": .int(800)]))
    }

    /// 复刻 4：程序内引用未定义宿主 API（setTimeout——真机程序的必挂形态，
    /// 期望立即 exception 收敛而非悬挂）。
    func testUndefinedHostAPIFailsFast() async throws {
        let runtime = try makeRuntime(maxWallMs: 10_000)
        let request = CodeRunRequest(
            program: """
            await new Promise(r => setTimeout(r, 100));
            return "unreached";
            """,
            bindings: [CodeBindingNamespace(
                global: "tools",
                functions: ["echo": { args in return args }])])
        let result = await runtime.run(request)
        let error = try XCTUnwrap(result.error,
                                  "undefined host API must fail fast, got value=\(String(describing: result.value))")
        XCTAssertEqual(error.kind, CodeRunFailureKind.exception)
    }
}
