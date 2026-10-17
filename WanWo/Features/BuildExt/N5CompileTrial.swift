// N5 编译试验（13 号设计环 N5 验收：真机 buildProject(.export) 对
// hello-world 工程产出合法 ipa + 增量缓存命中）。
// 设计：NXProject.createProject（官方工厂，Config 脚手架齐全）+ 官方
// SwiftUI 模板源码（字节内嵌，$(LDEDisplayName)→HelloWorld）+ 官方
// NXBuilder.buildProject 全链（headsup→clean→prepare→build→install
// .export→package）。模板资源（Shared/Templates/NXCodeTemplate）属 N6+
// UI 环，本试验自写源文件绕开。
// 验证口径：result=true 且 packageURL 存在（Payload/HelloWorld.app 的
// zip 快照；结构解剖=拉回本地细查）。

import Foundation

enum N5CompileTrial {

    static let projectName = "HelloWorld"

    /* 源文件由官方模板链生成：createProject 内部调 NXCodeTemplateMakeProjectStructure
     * （读 bundle 内 Templates/Application/Swift/SwiftUI/——Templates.bundle 资源，
     * 见 docs/gpl-compliance.md §三 d）——自写源文件段已删（与模板铺的文件冲突）。 */

    /// 跑完整试验。completion 回主线程：(成功?, 报告文本)。
    static func run(completion: @escaping (Bool, String) -> Void) {
        let projectsRoot = NXBootstrap.shared().projectsURL

        // ① 官方工厂创建脚手架（Config/Project.plist+Entitlements.plist+Resources）
        guard let project = NXProject.createProject(
            at: projectsRoot,
            withName: projectName,
            withOrganizationIdentifier: "com.wanwo",
            withBundleIdentifier: "com.wanwo.helloworld",
            withSchemeKind: NXProjectSchemeKind.app,
            withLanguageKind: NXProjectLanguageKind.swift,
            withInterfaceKind: NXProjectInterfaceKind.swiftUI
        ) else {
            DispatchQueue.main.async { completion(false, "createProject 返回 nil（脚手架创建失败）") }
            return
        }

        // ② 源文件由 createProject 内部的 NXCodeTemplateMakeProjectStructure
        //    铺设（官方 SwiftUI 模板：HelloWorldApp.swift+ContentView.swift 到工程根）

        // ③ 官方全链构建（MDK 线程池内跑：waitTillDone→NXBuilder→phases）
        let started = Date()
        NXBuilder.buildProject(withProject: project, buildType: .export) { result, _ in
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))

            // ④ 产物验证：package zip 存在 + macho 就位
            let packagePath = project.packageURL.path
            let packageOK = FileManager.default.fileExists(atPath: packagePath)
            let machoOK = FileManager.default.fileExists(atPath: project.machoURL.path)
            var sizeText = "-"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: packagePath),
               let size = attrs[.size] as? NSNumber {
                sizeText = ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
            }

            let passed = result && packageOK && machoOK
            var report: String
            if passed {
                report = "编译成功（\(elapsed)s）· 产物 \(sizeText) @ \(packagePath)"
            } else if result, !packageOK {
                report = "buildProject 报成功但产物缺失（package=\(packageOK) macho=\(machoOK)）@ \(packagePath)"
            } else {
                report = "编译失败（\(elapsed)s）——错误详情见构建日志（debug.json）：\(project.cacheURL.path)/debug.json"
            }
            DispatchQueue.main.async { completion(passed, report) }
        }
    }
}
