import SwiftUI

@main
struct WanWoApp: App {
    // M1（10-design §7.1/§十一 M1）：根导航 RootView = 会话列表侧栏 + 聊天流 +
    // 设置·Providers。M0 交付物不动：Shell 测试页从侧栏「诊断」进入（M0 真机
    // 验收口径「手动输入 ls」仍可通过——回归入口保留）。
    @StateObject private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase
    private let lifecycleLogger = AppLogger(category: "AppLifecycle")

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                // M4-B 场景2 取证（探针 C）：冻结窗口显式化——前后台切换
                // 时刻进日志（category AppLifecycle），与进程死亡时刻
                // （ISHShellExecutor[reader] stderr EOF/pipe closed）及
                // "guest exited"（探针 A）直接对齐，把"16 分钟空窗"变成
                // 日志里的显式标记。iOS 16.6：onChange(of:perform:) 单参形态。
                .onChange(of: scenePhase) { phase in
                    lifecycleLogger.info(
                        "app scene phase → \(String(describing: phase))")
                }
        }
    }
}
