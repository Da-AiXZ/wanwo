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

    // 官方 Shared/Templates/Application/Swift/SwiftUI/ContentView.swift 原文
    static let contentViewSource = """
    import SwiftUI

    struct ContentView: View {
    \tvar body: some View {
    \t\tVStack {
    \t\t\tImage(systemName: "globe")
    \t\t\t\t.imageScale(.large)
    \t\t\t\t.foregroundStyle(.tint)
    \t\t\tText("Hello, world!")
    \t\t}
    \t\t.padding()
    \t}
    }
    """

    // 官方 Shared/Templates/Application/Swift/SwiftUI/$(LDEDisplayName)App.swift 原文
    static let appSourceTemplate = """
    import SwiftUI

    @main
    struct $(LDEDisplayName)App: App {
    \tvar body: some Scene {
    \t\tWindowGroup {
    \t\t\tContentView()
    \t\t}
    \t}
    }
    """

    /// 跑完整试验。completion 回主线程：(成功?, 报告文本)。
    static func run(completion: @escaping (Bool, String) -> Void) {
        let projectsRoot = NXBootstrap.shared().projectsURL

        // ① 官方工厂创建脚手架（Config/Project.plist+Entitlements.plist+Resources）
        guard let project = NXProject.createProject(
            at: projectsRoot,
            withName: projectName,
            withOrganizationIdentifier: "com.wanwo",
            withBundleIdentifier: "com.wanwo.helloworld",
            withSchemeKind: NXProjectSchemeKindApp,
            withLanguageKind: NXProjectLanguageKindSwift,
            withInterfaceKind: NXProjectInterfaceKindSwiftUI
        ) else {
            DispatchQueue.main.async { completion(false, "createProject 返回 nil（脚手架创建失败）") }
            return
        }

        // ② 写 SwiftUI 两源文件（官方模板内容，占位符替换）到工程根
        //（PhaseEngine 经 LDEFilesFinder 扫工程根全部 .swift，排除 Resources/Config）
        do {
            let appSource = appSourceTemplate
                .replacingOccurrences(of: "$(LDEDisplayName)", with: projectName)
            try appSource.write(to: project.url.appendingPathComponent("\(projectName)App.swift"),
                                atomically: true, encoding: .utf8)
            try contentViewSource.write(to: project.url.appendingPathComponent("ContentView.swift"),
                                        atomically: true, encoding: .utf8)
        } catch {
            DispatchQueue.main.async { completion(false, "写源文件失败：\(error.localizedDescription)") }
            return
        }

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
