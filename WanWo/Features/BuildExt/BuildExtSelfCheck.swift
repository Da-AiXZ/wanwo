// BuildExt 自检（13 号设计 N2 验收项：CC 版本/P 核数/fatal handler 冒烟）。
// N0–N1 已实证：vendored CC/MDK（Nyxian main@0587c30）+ 官方配方工具链
// （toolchain-0587c30-20261016，swift 6.4.0）真编译链接通过。
// 本模块 = 设备端最小验证面：三个 CC C API 全通 = CoreCompiler.framework
// 在 iPad 上加载并工作（llvm_init constructor 已随 dyld 执行）。

import Foundation
// CC 三 API 经 WanWo-Bridging-Header.h 暴露（#import <CoreCompiler/CCUtils.h>）——
// 官方 Nyxian 同款形态：CoreCompiler umbrella 含 C++ 头，Swift 不直接 import。

struct BuildExtCheckItem: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let passed: Bool
}

enum BuildExtSelfCheck {
    /// 工具链/源码版本锚（docs/gpl-compliance.md 的运行时镜像）。
    static let toolchainAnchor =
        "Nyxian main@0587c30 · LLVM-On-iOS 5c2e215 (swift 6.4.0) · toolchain-0587c30-20261016"

    /// 逐项执行。全部在调用线程同步跑；三项 C API 均为轻量调用（无编译）。
    static func run() -> [BuildExtCheckItem] {
        var items: [BuildExtCheckItem] = []

        // ① P 核数（CCGetMaximumPerformanceCores → sysctl hw.perflevel0.physicalcpu，
        //    回退 hw.physicalcpu → 1）。CCUtils 的 constructor 已注册 AArch64
        //    Target/MC/AsmParser/Disassembler —— 本函数可调即 CC 静态初始化存活。
        let cores = CCGetMaximumPerformanceCores()
        items.append(BuildExtCheckItem(
            name: "CC 性能核数",
            detail: cores > 0 ? "\(cores) 个 P 核（sysctl 探测成功，CC constructor 存活）"
                              : "返回 \(cores)（异常：应 ≥1）",
            passed: cores > 0))

        // ② LLVM fatal handler 安装（防 swift-frontend 内部 fatal 直接 abort 宿主；
        //    幂等安装——安装成功即"已装"，无查询型 API，此为设计等价验证）。
        CCInstallLLVMFatalErrorHandler()
        items.append(BuildExtCheckItem(
            name: "LLVM fatal handler",
            detail: "CCInstallLLVMFatalErrorHandler() 调用完成（幂等；防编译器内部 fatal 带崩宿主）",
            passed: true))

        // ③ Swift 模块初始化（CCInitializeSwiftModulesOnce——CC 链接 swift 工具链
        //    dylib 的初始化门；once 语义，重复调用安全）。
        CCInitializeSwiftModulesOnce()
        items.append(BuildExtCheckItem(
            name: "Swift 模块初始化",
            detail: "CCInitializeSwiftModulesOnce() 调用完成（once 语义）",
            passed: true))

        // ④ 版本锚（编译期常量，非运行时读数——CC 层无版本查询 API，锚在
        //    gpl-compliance.md）。
        items.append(BuildExtCheckItem(
            name: "工具链版本锚",
            detail: toolchainAnchor,
            passed: true))

        // ── N3b 读数：编译引导状态 + 宿主 OS（13 号设计 N3b 验收项）──

        // ⑤ Bootstrap 状态（NXBootstrap 幂等安装：SDK/Include/lib/swift 四树
        //    就位 = 编译前置资源完整；未完成时列缺失树，不阻断其余读数）。
        let bootstrap = NXBootstrap.shared()
        let bootstrapVersion = bootstrap.version
        // ObjC readonly property 导入 Swift 后为属性（非函数）——直接访问。
        let trees: [(String, URL)] = [
            ("SDK/iPhoneOS26.5.sdk", bootstrap.sdkURL),
            ("Include", bootstrap.includeURL),
            ("swift", bootstrap.swiftURL),
            ("lib", bootstrap.rootURL.appendingPathComponent("lib")),
        ]
        let missing = trees.filter { !FileManager.default.fileExists(atPath: $0.1.path) }.map(\.0)
        if bootstrapVersion >= 29 && missing.isEmpty {
            items.append(BuildExtCheckItem(
                name: "编译引导（bootstrap）",
                detail: "已安装（v\(bootstrapVersion)）：SDK/Include/swift/lib 四树完整 @ \(bootstrap.rootURL.path)",
                passed: true))
        } else {
            items.append(BuildExtCheckItem(
                name: "编译引导（bootstrap）",
                detail: missing.isEmpty
                    ? "进行中（v\(bootstrapVersion)/29）——首启后台安装中，稍后重开本页"
                    : "未完成（v\(bootstrapVersion)/29）缺失：\(missing.joined(separator: "、"))",
                passed: missing.isEmpty))
        }

        // ⑥ 宿主 OS 版本（MDKOSVersion.host——13 号设计 N3b 验收：
        //    返回 16.6.1 数值正确；host 为类属性，Swift 侧不带括号）。
        let hostOS = MDKOSVersion.host.versionString
        items.append(BuildExtCheckItem(
            name: "宿主 OS 读数",
            detail: "MDKOSVersion.host = \(hostOS)",
            passed: !hostOS.isEmpty))

        // ── N4 逻辑验收（13 号设计环 N4：$(VAR) 展开 + DebugDatabase 读写）──
        // 原设计"模拟器 swift test 云跑"不可行：主 App 含编译内核后模拟器
        // 构建需链 sim 平台 CC，而官方工具链 llvm.a 仅 ios-arm64 切片（真机）
        // ——run 39011546398 实证平台不匹配拒链。逻辑验证移入真机自检页。

        // ⑦ $(VAR) 展开（NXPlist.expandString——官方语义：字典点路径递归
        //    解析 → variables 兜底 → 未命中空串；depth 上限 10）。
        do {
            let dir = NSTemporaryDirectory()
            let plistPath = (dir as NSString).appendingPathComponent("n4check-\(UUID().uuidString).plist")
            let dict: [String: Any] = ["Compiler": ["Arch": "arm64"], "App": ["Name": "WanWo"]]
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            FileManager.default.createFile(atPath: plistPath, contents: data)
            defer { try? FileManager.default.removeItem(atPath: plistPath) }

            var failures: [String] = []
            if let plist = NXPlist(plistPath: plistPath, withVariables: ["PlatformArch": "arm64"]) {
                // ① 字典点路径
                if let arch = plist.dictionary.expand("$(Compiler.Arch)", depth: 0, ownRoot: nil) as? String, arch == "arm64" {} else {
                    failures.append("点路径展开失败")
                }
                // ② variables 兜底
                if let v = plist.dictionary.expand("value-$(PlatformArch)", depth: 0, ownRoot: nil) as? String, v == "value-arm64" {} else {
                    failures.append("variables 兜底失败")
                }
                // ③ 未命中 → 空串
                if let miss = plist.dictionary.expand("x-$(NoSuch.Var)-y", depth: 0, ownRoot: nil) as? String, miss == "x--y" {} else {
                    failures.append("未命中空串语义失败")
                }
                // ④ 递归展开
                if let r = plist.dictionary.expand("$(Recursive)", depth: 0, ownRoot: nil) as? String, r == "flag-value" {
                    // 递归用例需要字典支持——用独立 plist 验证
                } else {
                    // 递归单独构造
                    let p2Path = (dir as NSString).appendingPathComponent("n4check2-\(UUID().uuidString).plist")
                    let d2: [String: Any] = ["A": "flag-$(B)", "B": "value"]
                    let d2data = try PropertyListSerialization.data(fromPropertyList: d2, format: .xml, options: 0)
                    FileManager.default.createFile(atPath: p2Path, contents: d2data)
                    defer { try? FileManager.default.removeItem(atPath: p2Path) }
                    if let p2 = NXPlist(plistPath: p2Path, withVariables: nil),
                       let r2 = p2.dictionary.expand("$(A)", depth: 0, ownRoot: nil) as? String, r2 == "flag-value" {
                    } else {
                        failures.append("递归展开失败")
                    }
                }
            } else {
                failures.append("NXPlist 初始化失败")
            }

            items.append(BuildExtCheckItem(
                name: "$(VAR) 展开（NXPlist）",
                detail: failures.isEmpty
                    ? "4/4 语义验证通过：点路径/variables 兜底/未命中空串/递归展开"
                    : "失败：\(failures.joined(separator: "；"))",
                passed: failures.isEmpty))
        } catch {
            items.append(BuildExtCheckItem(
                name: "$(VAR) 展开（NXPlist）",
                detail: "异常：\(error.localizedDescription)",
                passed: false))
        }

        // ⑧ DebugDatabase 读写回环（getDatabase → addMessage → save →
        //    重开读回 → reuse/clear 语义）。官方语义注：reuseDatabase=
        //    重置 Internal 桶开始新一轮（NXBuilder get→reuse 顺序）——
        //    读回断言必须在 reuse 之前（首版断言顺序错致 ⑧ 误红）。
        do {
            let path = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("n4check-debug-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(atPath: path) }

            let db = DebugDatabase.getDatabase(ofPath: path)
            db.addMessage(message: "n4-selfcheck-roundtrip", severity: .error)
            db.saveDatabase(toPath: path)

            let reopened = DebugDatabase.getDatabase(ofPath: path)
            /* 先断言持久化回环（reuse 之前——reuse 会重置 Internal 桶） */
            let roundtripOK = reopened.debugObjects.values.flatMap(\.debugItems)
                .contains { $0.message == "n4-selfcheck-roundtrip" }

            /* 再验证 reuse 语义（官方 NXBuilder 顺序）：重置 Internal 桶 */
            reopened.reuseDatabase()
            let reuseResetsOK = reopened.debugObjects["Internal"]?.debugItems.isEmpty == true

            /* clear 语义：清空后无残留 */
            let db2 = DebugDatabase.getDatabase(ofPath: "/dev/null") /* 不存在 → 走新建分支 */
            db2.addMessage(message: "to-be-cleared", severity: .warning)
            db2.clearDatabase()
            let clearOK = db2.debugObjects.values.flatMap(\.debugItems).isEmpty

            items.append(BuildExtCheckItem(
                name: "DebugDatabase 读写",
                detail: roundtripOK && reuseResetsOK && clearOK
                    ? "读写回环 ✓ + reuse 重置语义 ✓ + clear ✓"
                    : "失败：回环=\(roundtripOK ? "✓" : "✗") reuse=\(reuseResetsOK ? "✓" : "✗") clear=\(clearOK ? "✓" : "✗")",
                passed: roundtripOK && reuseResetsOK && clearOK))
        }

        return items
    }

    /// 汇总一行（诊断流/日志用）。
    static func summary(_ items: [BuildExtCheckItem]) -> String {
        let pass = items.filter(\.passed).count
        return "BuildExt 自检 \(pass)/\(items.count) 通过："
            + items.map { "\($0.name)=\($0.passed ? "✓" : "✗")" }.joined(separator: " ")
    }
}
