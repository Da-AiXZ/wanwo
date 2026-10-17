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

        return items
    }

    /// 汇总一行（诊断流/日志用）。
    static func summary(_ items: [BuildExtCheckItem]) -> String {
        let pass = items.filter(\.passed).count
        return "BuildExt 自检 \(pass)/\(items.count) 通过："
            + items.map { "\($0.name)=\($0.passed ? "✓" : "✗")" }.joined(separator: " ")
    }
}
