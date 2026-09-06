import SwiftUI

@main
struct WanWoApp: App {
    var body: some Scene {
        WindowGroup {
            // M0.4：Shell 测试页（手动输入 `ls` 验收，10-design §十一 M0.4）。
            // 根导航 RootView 按里程碑推进再引入（§七 UI 全部重做）。
            ShellTestView()
        }
    }
}
