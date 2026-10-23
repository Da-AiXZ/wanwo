//
//  BuildObservabilityN11Tests.swift
//  WanWoTests
//
//  【N11 观察项 · 单测面】可纯函数验证的三件：
//    - O8：BuildService.shortDiagnosticPath 三形态（/private/var 宿主绝对
//      路径归一、工程相对路径直通、已短形态直通）——批A S1 单一渲染源的
//      回归门。
//    - O2/O3：BuildService.artifactSafeName（ASCII 字母数字白名单 + 非
//      ASCII/空串/符号落 "run" 兜底——写入侧 run_log 副本/utility tee/
//      构建日志与删除侧 project_delete 清理前缀的统一命名函数）。
//  不可单测面（真机面）：O4（sourcesContainCpp 缓存——依赖 MDK 钩子安装
//  态与构建编排线程）、N1（BuildLogSession FileHandle 落盘）、N2（RunLog-
//  LineGuard 与 guest 管道读循环的交错时序）。
//

import XCTest
@testable import WanWo

final class BuildObservabilityN11Tests: XCTestCase {

    // MARK: - fixture（O8）

    /// 工程根（/var 形态——project.url 既有形态；纯构造路径，不触磁盘）。
    private static let projectRoot =
        "/var/mobile/Containers/Data/Application/AAAAAAAA-1111-2222-3333-444444444444/BuildProjects/Demo/PROJ-UUID"

    private func rootURL() -> URL {
        return URL(fileURLWithPath: Self.projectRoot)
    }

    // MARK: O8 · shortDiagnosticPath

    /// 形态一：/private/var 宿主绝对路径（DebugDatabase 落键真实形态——
    /// 编译器诊断 fileURL 符号链接解析后的 /private 形态）归一后按工程根
    /// 精确剥离 → 工程相对路径。
    func testPrivateVarHostAbsolutePathNormalizedToProjectRelative() {
        let title = "/private" + Self.projectRoot + "/ContentView.swift"
        let out = BuildService.shortDiagnosticPath(title: title, projectRoot: rootURL())
        XCTAssertEqual(out, "ContentView.swift")
    }

    /// 形态一补：/var 形态（无 /private 前缀——project.url 同源形态）同样
    /// 按工程根精确剥离（渲染序①对两形态都命中）。
    func testVarFormAbsolutePathNormalizedToProjectRelative() {
        let title = Self.projectRoot + "/Sources/Deep/Type.swift"
        let out = BuildService.shortDiagnosticPath(title: title, projectRoot: rootURL())
        XCTAssertEqual(out, "Sources/Deep/Type.swift")
    }

    /// 形态二：工程相对路径（不以 / 开头）直通原样——不误改。
    func testRelativePathPassesThrough() {
        let out = BuildService.shortDiagnosticPath(
            title: "ContentView.swift", projectRoot: rootURL())
        XCTAssertEqual(out, "ContentView.swift")
    }

    /// 形态三：已短形态直通——非路径键（Internal 等 Message 桶标题）
    /// 原样返回（④全不命中分支对非路径键直通）。
    func testNonPathTitlePassesThrough() {
        let out = BuildService.shortDiagnosticPath(
            title: "Internal", projectRoot: rootURL())
        XCTAssertEqual(out, "Internal")
    }

    /// 形态三补：不命中工程根/BSROOT 的绝对路径不误切（旧盲切缺陷
    /// C1E5B58 短形态回归门——错切半截路径的形态禁止复现）。
    func testUnmatchedAbsolutePathPassesThrough() {
        let title = "/somewhere/else/File.swift"
        let out = BuildService.shortDiagnosticPath(title: title, projectRoot: rootURL())
        XCTAssertEqual(out, title)
    }

    // MARK: O2/O3 · artifactSafeName

    /// ASCII 字母数字原样通过（project_create 校验的正常态零变化）。
    func testArtifactSafeNameAsciiPassThrough() {
        XCTAssertEqual(BuildService.artifactSafeName("Demo2"), "Demo2")
        XCTAssertEqual(BuildService.artifactSafeName("ObjcCLI"), "ObjcCLI")
    }

    /// 非 ASCII 工程名（历史中文工程）落 "run" 兜底——写入侧与删除侧
    /// 同一函数同源（O3 口径统一的核心断言）。
    func testArtifactSafeNameNonAsciiFallsBackToRun() {
        XCTAssertEqual(BuildService.artifactSafeName("计算器"), "run")
    }

    /// 空串落 "run" 兜底（copyRunLogToWorkspace 既有兜底语义收编）。
    func testArtifactSafeNameEmptyFallsBackToRun() {
        XCTAssertEqual(BuildService.artifactSafeName(""), "run")
    }

    /// 分隔符/符号/空格拒绝（防文件名注入与路径逃逸段）。
    func testArtifactSafeNameRejectsSeparatorAndSymbols() {
        XCTAssertEqual(BuildService.artifactSafeName("a/b"), "run")
        XCTAssertEqual(BuildService.artifactSafeName("my-app"), "run")
        XCTAssertEqual(BuildService.artifactSafeName("a b"), "run")
        XCTAssertEqual(BuildService.artifactSafeName(".."), "run")
    }
}
