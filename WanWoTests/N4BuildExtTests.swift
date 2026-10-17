// N4 验收单测（13 号设计环 N4："$(VAR) 展开单测；DebugDatabase 读写单测"）。
// 纯逻辑件——不依赖网络/guest/真机状态，模拟器云跑。

import XCTest
@testable import WanWo

final class N4BuildExtTests: XCTestCase {

    // MARK: - NXPlist $(VAR) 展开（expandString）

    /// 构造临时 plist 文件的 NXPlist（initWithPlistPath 需要真实文件）。
    private func makePlist(dictionary: [String: Any],
                           variables: [String: String]?) throws -> NXPlist {
        let plistPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("n4test-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary,
                                                      format: .xml, options: 0)
        XCTAssertTrue(FileManager.default.createFile(atPath: plistPath, contents: data))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: plistPath) }
        return try XCTUnwrap(NXPlist(plistPath: plistPath, variables: variables))
    }

    /// ① 字典点路径展开：$(Compiler.Arch) → 自 plist 字典树解析。
    func testExpandStringDictionaryPath() throws {
        let plist = try makePlist(
            dictionary: ["Compiler": ["Arch": "arm64"], "App": ["Name": "WanWo"]],
            variables: nil)

        let arch = try XCTUnwrap(plist.expandString("$(Compiler.Arch)", depth: 0, ownRoot: nil) as? String)
        XCTAssertEqual(arch, "arm64")
    }

    /// ② variables 兜底：$(VAR) 不在字典树时落 variables。
    func testExpandStringVariablesFallback() throws {
        let plist = try makePlist(
            dictionary: ["App": ["Name": "WanWo"]],
            variables: ["PlatformArch": "arm64"])

        let value = try XCTUnwrap(plist.expandString("value-$(PlatformArch)", depth: 0, ownRoot: nil) as? String)
        XCTAssertEqual(value, "value-arm64")
    }

    /// ③ 未命中 → 空串（官方语义：replacementValue ?: @""）。
    func testExpandStringMissBlanksOut() throws {
        let plist = try makePlist(dictionary: ["App": ["Name": "WanWo"]], variables: nil)

        let value = try XCTUnwrap(plist.expandString("x-$(NoSuch.Var)-y", depth: 0, ownRoot: nil) as? String)
        XCTAssertEqual(value, "x--y")
    }

    /// ④ 递归展开：变量值内再含 $(引用)（depth+1 递归，上限 10 层）。
    func testExpandStringRecursive() throws {
        let plist = try makePlist(
            dictionary: ["A": "flag-$(B)", "B": "value"],
            variables: nil)

        let value = try XCTUnwrap(plist.expandString("$(A)", depth: 0, ownRoot: nil) as? String)
        XCTAssertEqual(value, "flag-value")
    }

    // MARK: - DebugDatabase 读写

    /// ⑤ 写读回环：addMessage → saveDatabase → 重开断言读回。
    func testDebugDatabaseRoundtrip() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("n4debug-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let db = DebugDatabase.getDatabase(ofPath: path)
        db.addMessage(message: "hello-n4", severity: .error)
        db.saveDatabase(toPath: path)

        let reopened = DebugDatabase.getDatabase(ofPath: path)
        reopened.reuseDatabase()
        let messages = reopened.debugObjects.values.flatMap(\.debugItems)
        XCTAssertTrue(messages.contains { $0.message == "hello-n4" },
                      "重开后的库里应能读回写入的 message")
    }

    /// ⑥ clearDatabase 语义：清空后 Internal 桶重建为空。
    func testDebugDatabaseClear() throws {
        let db = DebugDatabase.getDatabase(ofPath: "/dev/null") /* 不存在 → 走新建分支 */
        db.addMessage(message: "to-be-cleared", severity: .warning)
        db.clearDatabase()

        let items = db.debugObjects.values.flatMap(\.debugItems)
        XCTAssertTrue(items.isEmpty, "clearDatabase 后不应残留 debug items")
    }
}
