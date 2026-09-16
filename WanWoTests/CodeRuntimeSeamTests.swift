//
//  CodeRuntimeSeamTests.swift
//  WanWoTests
//
//  【M5-B 批 P1 测试 · CodeRuntime 词汇缝】
//    1. 保留字常量逐字对拍（reserved.spec.ts:15-57 全用例形态移植）：
//       RESERVED_BINDING_GLOBALS 五条 / RESERVED_ERROR_MEMBERS 六条 /
//       DUNDER_MEMBER 形态（空/短中段边界）/ PORTABLE_RESERVED_WORDS 全集
//       （ECMAScript 段 48 词 + Python 段 23 词 = 71，逐段计数 + 抽样）
//    2. validateBindings 全分支（worker index.ts:320-361 七查文案逐字）：
//       合法通过 / $tools·保留字拒 / console·__debug__ 拒 / 重复 global 拒 /
//       error class 名四态 / member 排他集（空·JS Error·Python 协议·dunder）
//    3. functions 键 own-property 语义（__proto__/constructor 键合法——
//       null-prototype 的 Swift 字典等价，types.ts:45-47）
//    4. CodeRunFailure 六类词汇 / CodeRunResult error 是字段非 rejection
//       （协议 run 不 throws 的形态锚：桩 runtime 返回 error 字段结果）
//  纯词汇件零 IO——本测试面无网络/无 worker。
//

import XCTest
@testable import WanWo

final class CodeRuntimeSeamTests: XCTestCase {

    // MARK: 1. 保留字常量（reserved.spec.ts 对拍）

    func testReservedBindingGlobalsCoversEachBackendOwnedSlot() {
        // spec.ts:16-23 逐条。
        for name in ["console", "__dsh_main__", "__builtins__", "__name__", "__debug__"] {
            XCTAssertTrue(CodeRuntimeSeam.reservedBindingGlobals.contains(name),
                          "RESERVED_BINDING_GLOBALS 缺 \(name)")
        }
        XCTAssertFalse(CodeRuntimeSeam.reservedBindingGlobals.contains("tools"))
        // index.ts:39-42 五条闭集（不多不少）。
        XCTAssertEqual(CodeRuntimeSeam.reservedBindingGlobals.count, 5)
    }

    func testReservedErrorMembersCoversJSErrorAndPythonProtocol() {
        // spec.ts:25-30 逐条。
        for name in ["name", "message", "stack", "args", "with_traceback", "add_note"] {
            XCTAssertTrue(CodeRuntimeSeam.reservedErrorMembers.contains(name),
                          "RESERVED_ERROR_MEMBERS 缺 \(name)")
        }
        XCTAssertFalse(CodeRuntimeSeam.reservedErrorMembers.contains("code"))
        XCTAssertEqual(CodeRuntimeSeam.reservedErrorMembers.count, 6)
    }

    func testDunderMemberMatchesDunderFormOnly() {
        // spec.ts:32-44 逐条形态对拍。
        XCTAssertTrue(CodeRuntimeSeam.isDunderMember("__dict__"))
        XCTAssertTrue(CodeRuntimeSeam.isDunderMember("__init__"))
        XCTAssertFalse(CodeRuntimeSeam.isDunderMember("_private"))
        XCTAssertFalse(CodeRuntimeSeam.isDunderMember("name"))
        XCTAssertFalse(CodeRuntimeSeam.isDunderMember("__mid"))
        // `__` 空中段——非真 CPython dunder（spec.ts:38-39）。
        XCTAssertFalse(CodeRuntimeSeam.isDunderMember("__"))
        // `____` 两对 `__` 之间亦空中段（spec.ts:40-41）。
        XCTAssertFalse(CodeRuntimeSeam.isDunderMember("____"))
        // 单字符中段 = 最短真 dunder 形态（spec.ts:42-43）。
        XCTAssertTrue(CodeRuntimeSeam.isDunderMember("__x__"))
    }

    func testPortableReservedWordsIsECMAScriptUnionPython() {
        // spec.ts:46-56 抽样对拍。
        XCTAssertTrue(CodeRuntimeSeam.portableReservedWords.contains("function"))
        XCTAssertTrue(CodeRuntimeSeam.portableReservedWords.contains("lambda"))
        XCTAssertTrue(CodeRuntimeSeam.portableReservedWords.contains("nonlocal"))
        XCTAssertTrue(CodeRuntimeSeam.portableReservedWords.contains("class"))
        XCTAssertFalse(CodeRuntimeSeam.portableReservedWords.contains("tools"))

        // 逐段计数对拍（index.ts:77-81 五行 48 词 + :84-85 两行 23 词 = 71；
        // 派单预判「ECMAScript 段 33 词」为 :77-79 三行的子集计数——纠偏登记）。
        XCTAssertEqual(CodeRuntimeSeam.portableReservedWords.count, 71)

        // ECMAScript 段抽样（strict-mode 保留名 + 未来保留名全部在场）。
        for word in ["await", "debugger", "enum", "implements", "interface",
                     "package", "private", "protected", "public", "arguments",
                     "eval", "let", "static", "yield", "with"] {
            XCTAssertTrue(CodeRuntimeSeam.portableReservedWords.contains(word),
                          "ECMAScript 段缺 \(word)")
        }
        // Python 段抽样（软关键字 type/_ + match + 大写三态）。
        for word in ["False", "None", "True", "async", "del", "elif", "except",
                     "from", "global", "is", "match", "type", "_"] {
            XCTAssertTrue(CodeRuntimeSeam.portableReservedWords.contains(word),
                          "Python 段缺 \(word)")
        }
        // 大小写敏感（false/true/null 是 ECMAScript 字面量保留名，False/True/
        // None 是 Python——互不吸收）。
        XCTAssertFalse(CodeRuntimeSeam.portableReservedWords.contains("False_"))
        XCTAssertTrue(CodeRuntimeSeam.portableReservedWords.contains("false"))
        XCTAssertTrue(CodeRuntimeSeam.portableReservedWords.contains("null"))
    }

    func testPortableIdentifierRule() {
        // worker index.ts:73 IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*$/ 1:1。
        XCTAssertTrue(CodeRuntimeSeam.isPortableIdentifier("tools"))
        XCTAssertTrue(CodeRuntimeSeam.isPortableIdentifier("_x"))
        XCTAssertTrue(CodeRuntimeSeam.isPortableIdentifier("a1_b2"))
        XCTAssertFalse(CodeRuntimeSeam.isPortableIdentifier(""))            // 空串
        XCTAssertFalse(CodeRuntimeSeam.isPortableIdentifier("$tools"))      // JS-only 拼写
        XCTAssertFalse(CodeRuntimeSeam.isPortableIdentifier("1abc"))        // 数字开头
        XCTAssertFalse(CodeRuntimeSeam.isPortableIdentifier("bad-name"))    // 连字符
        XCTAssertFalse(CodeRuntimeSeam.isPortableIdentifier("a b"))         // 空白
        XCTAssertFalse(CodeRuntimeSeam.isPortableIdentifier("λ"))           // 非 ASCII
        XCTAssertFalse(CodeRuntimeSeam.isPortableIdentifier("aé"))          // 中段非 ASCII
    }

    // MARK: 2. validateBindings 全分支（worker :320-361 文案逐字）

    /// 派单（worker index.ts:320-361 七查逐查）断言 helper。
    private func assertContractError(
        _ bindings: [CodeBindingNamespace],
        expectedMessage: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try CodeRuntimeSeam.validateBindings(bindings),
                             file: file, line: line) { failure in
            guard let contract = failure as? CodeRuntimeSeam.ContractError else {
                XCTFail("expected ContractError, got \(failure)", file: file, line: line)
                return
            }
            XCTAssertEqual(contract.message, expectedMessage, file: file, line: line)
        }
    }

    func testValidateAcceptsLegalNamespaces() throws {
        // 合法：普通 global + 空 functions + 合法 errorClass（派单：空 functions 合法）。
        XCTAssertNoThrow(try CodeRuntimeSeam.validateBindings([
            CodeBindingNamespace(global: "tools"),
        ]))
        XCTAssertNoThrow(try CodeRuntimeSeam.validateBindings([
            CodeBindingNamespace(
                global: "tools",
                functions: ["lookup": { _, _ in .null }],
                errorClass: CodeBindingErrorClass(
                    name: "ToolsError", memberNameProperty: "memberName")),
        ]))
        // member 非标识符名可接受（types.ts:37-38——「any other name —
        // identifiers or not — is accepted everywhere」）。
        XCTAssertNoThrow(try CodeRuntimeSeam.validateBindings([
            CodeBindingNamespace(
                global: "tools",
                errorClass: CodeBindingErrorClass(
                    name: "ToolsError", memberNameProperty: "member name!")),
        ]))
    }

    func testValidateRejectsNonIdentifierAndReservedWordGlobals() {
        // :323-324——$tools 被设计性拒绝（types.ts:54 锚）。
        assertContractError(
            [CodeBindingNamespace(global: "$tools")],
            expectedMessage: "dsh-code-runtime-worker-thread: binding global "
                + "\"$tools\" is not a usable identifier")
        // 保留字同分支同文案（worker 后端有效的 `lambda` 在此被拒——可移植承诺）。
        assertContractError(
            [CodeBindingNamespace(global: "lambda")],
            expectedMessage: "dsh-code-runtime-worker-thread: binding global "
                + "\"lambda\" is not a usable identifier")
        // `_` 是保留字（软关键字安全保留）——不可用作 global。
        assertContractError(
            [CodeBindingNamespace(global: "_")],
            expectedMessage: "dsh-code-runtime-worker-thread: binding global "
                + "\"_\" is not a usable identifier")
    }

    func testValidateRejectsReservedBindingGlobals() {
        // :332-334——console（本后端日志槽）与 __debug__（Python 编译期常量槽）。
        assertContractError(
            [CodeBindingNamespace(global: "console")],
            expectedMessage: "dsh-code-runtime-worker-thread: reserved binding "
                + "global \"console\"")
        assertContractError(
            [CodeBindingNamespace(global: "__debug__")],
            expectedMessage: "dsh-code-runtime-worker-thread: reserved binding "
                + "global \"__debug__\"")
    }

    func testValidateRejectsDuplicateGlobals() {
        // :335-337。
        assertContractError(
            [CodeBindingNamespace(global: "tools"),
             CodeBindingNamespace(global: "tools")],
            expectedMessage: "dsh-code-runtime-worker-thread: duplicate binding "
                + "global \"tools\"")
    }

    func testValidateErrorClassNameBranches() {
        // :345-347——error class 名标识符/保留字。
        assertContractError(
            [CodeBindingNamespace(global: "tools", errorClass: CodeBindingErrorClass(
                name: "$E", memberNameProperty: "memberName"))],
            expectedMessage: "dsh-code-runtime-worker-thread: binding error class "
                + "\"$E\" is not a usable identifier")
        assertContractError(
            [CodeBindingNamespace(global: "tools", errorClass: CodeBindingErrorClass(
                name: "class", memberNameProperty: "memberName"))],
            expectedMessage: "dsh-code-runtime-worker-thread: binding error class "
                + "\"class\" is not a usable identifier")
        // :348-350——error class 名撞 backend 槽 = reserved binding global 文案。
        assertContractError(
            [CodeBindingNamespace(global: "tools", errorClass: CodeBindingErrorClass(
                name: "console", memberNameProperty: "memberName"))],
            expectedMessage: "dsh-code-runtime-worker-thread: reserved binding "
                + "global \"console\"")
        // :351-353——撞 namespace global。
        assertContractError(
            [CodeBindingNamespace(global: "tools", errorClass: CodeBindingErrorClass(
                name: "tools", memberNameProperty: "memberName"))],
            expectedMessage: "dsh-code-runtime-worker-thread: duplicate injected "
                + "global \"tools\"")
        // :351-353——两个 error class 同名。
        assertContractError(
            [CodeBindingNamespace(global: "tools", errorClass: CodeBindingErrorClass(
                name: "ToolsError", memberNameProperty: "memberName")),
             CodeBindingNamespace(global: "fs", errorClass: CodeBindingErrorClass(
                name: "ToolsError", memberNameProperty: "memberName"))],
            expectedMessage: "dsh-code-runtime-worker-thread: duplicate injected "
                + "global \"ToolsError\"")
    }

    func testValidateRejectsExcludedMemberNameProperties() {
        // :354-357 排他集三分支同文案：空 / JS Error 成员 / Python 协议成员 / dunder。
        for member in ["", "name", "message", "stack", "args",
                       "with_traceback", "add_note", "__dict__"] {
            assertContractError(
                [CodeBindingNamespace(global: "tools", errorClass: CodeBindingErrorClass(
                    name: "ToolsError", memberNameProperty: member))],
                expectedMessage: "dsh-code-runtime-worker-thread: binding error "
                    + "member property \(CodeRuntimeSeam.jsonQuoted(member)) "
                    + "is not usable",
                file: #filePath, line: #line)
        }
        // 成员名不因保留字表被拒（排他集只有六条 + dunder）——"type"/"class"
        // 是合法 member（types.ts:37-38「any other name accepted everywhere」）。
        XCTAssertNoThrow(try CodeRuntimeSeam.validateBindings([
            CodeBindingNamespace(global: "tools", errorClass: CodeBindingErrorClass(
                name: "ToolsError", memberNameProperty: "type")),
        ]))
    }

    // MARK: 3. functions 键 own-property 语义

    func testFunctionKeysArbitraryStringsOwnPropertySemantics() throws {
        // types.ts:45-47——`__proto__`/`constructor` 是普通 own property，
        // 非原型冲突（Swift 字典 own-key 天然等价，适配登记③）。校验不拒之。
        let namespace = CodeBindingNamespace(global: "tools", functions: [
            "__proto__": { _, _ in .null },
            "constructor": { _, _ in .null },
            "hasOwnProperty": { _, _ in .null },
        ])
        XCTAssertNoThrow(try CodeRuntimeSeam.validateBindings([namespace]))
        XCTAssertEqual(namespace.functions.count, 3)
        XCTAssertNotNil(namespace.functions["__proto__"])
        XCTAssertNotNil(namespace.functions["constructor"])
    }

    // MARK: 4. 失败词汇 + 结果形态（error 是字段非 rejection）

    func testRunFailureKindVocabulary() {
        // types.ts:105 六类闭集，rawValue = wire 词汇逐字。
        XCTAssertEqual(Set(CodeRunFailureKind.allCases), Set([
            CodeRunFailureKind.exception, .timeout, .abort,
            .workerExit, .invalidOutput, .outputLimit,
        ]))
        XCTAssertEqual(CodeRunFailureKind.exception.rawValue, "exception")
        XCTAssertEqual(CodeRunFailureKind.timeout.rawValue, "timeout")
        XCTAssertEqual(CodeRunFailureKind.abort.rawValue, "abort")
        XCTAssertEqual(CodeRunFailureKind.workerExit.rawValue, "worker-exit")
        XCTAssertEqual(CodeRunFailureKind.invalidOutput.rawValue, "invalid-output")
        XCTAssertEqual(CodeRunFailureKind.outputLimit.rawValue, "output-limit")
    }

    func testRunResultErrorIsFieldNotRejection() {
        // types.ts:111-113——失败程序经 result.error 字段报告；形态锚 = 失败
        // 结果照常构造（无异常路径）、value/logs/error 三字段并存。
        let failed = CodeRunResult(
            value: nil,
            logs: ["partial stdout"],
            error: CodeRunFailure(kind: .exception, message: "boom"))
        XCTAssertNil(failed.value)
        XCTAssertEqual(failed.logs, ["partial stdout"])
        XCTAssertEqual(failed.error?.kind, .exception)
        // 成功形态：值在场 + error 缺省。
        let succeeded = CodeRunResult(value: .int(3), logs: [])
        XCTAssertNotNil(succeeded.value)
        XCTAssertNil(succeeded.error)
        // Equatable 形态（跨 runtime 传递可比对）。
        XCTAssertEqual(failed, CodeRunResult(
            value: nil, logs: ["partial stdout"],
            error: CodeRunFailure(kind: .exception, message: "boom")))
    }

    func testProtocolRunDoesNotThrowAndCarriesErrorAsField() async {
        // 协议形态锚：run 不 throws（CodeRuntimeProtocol 契约——error 是字段）；
        // 桩实现验证 language/isolation 信息性字段与 run 签名形状。
        final class StubRuntime: CodeRuntimeProtocol {
            let language = "typescript"
            let isolation = "worker-thread"
            func run(_ request: CodeRunRequest) async -> CodeRunResult {
                return CodeRunResult(
                    logs: [],
                    error: CodeRunFailure(kind: .abort, message: "runtime disposed"))
            }
        }
        let runtime = StubRuntime()
        let result = await runtime.run(CodeRunRequest(program: "return 1"))
        XCTAssertEqual(result.error?.kind, .abort)
        XCTAssertEqual(result.error?.message, "runtime disposed")
        XCTAssertEqual(runtime.language, "typescript")
        XCTAssertEqual(runtime.isolation, "worker-thread")
    }
}
