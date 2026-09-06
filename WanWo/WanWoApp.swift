import SwiftUI

@main
struct WanWoApp: App {
    // M1（10-design §7.1/§十一 M1）：根导航 RootView = 会话列表侧栏 + 聊天流 +
    // 设置·Providers。M0 交付物不动：Shell 测试页从侧栏「诊断」进入（M0 真机
    // 验收口径「手动输入 ls」仍可通过——回归入口保留）。
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
        }
    }
}
