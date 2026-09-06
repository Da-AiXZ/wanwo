import SwiftUI

/// 跨线程 console 缓冲：ISHKernel 输出回调写入，界面 Timer 轮询读取。
enum ConsoleHub {
    private static let lock = NSLock()
    private static var _text = ""

    static var text: String {
        lock.withLock { _text }
    }

    static func append(_ s: String) {
        lock.withLock {
            _text += s
            if _text.count > 64_000 {
                _text = String(_text.suffix(32_000))
            }
        }
    }

    static func clear() {
        lock.withLock { _text = "" }
    }
}

/// M0.2：iSH 接入验证（OpenMinis 生产版 ISHKernel 驱动）。
/// 流程：首启解包 rootfs.tar → ISHKernel.boot → 执行 `uname -a` → 输出上屏。
struct RootView: View {
    enum Phase: Equatable {
        case installing
        case booting
        case running
        case done
        case failed(String)
    }

    @State private var phase: Phase = .installing
    @State private var shown: String = ""
    @State private var unameResult: String = ""
    private let timer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch phase {
            case .installing:
                Label("正在装配 Alpine rootfs（仅首次）…", systemImage: "externaldrive.badge.timemachine")
                    .font(.footnote).foregroundStyle(Color.secondary)
            case .booting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("内核启动中…").font(.footnote).foregroundStyle(Color.secondary)
                }
            case .running, .done:
                Label(phase == .done ? "Linux 已启动" : "执行验收命令中…",
                      systemImage: phase == .done ? "checkmark.seal.fill" : "gearshape.2")
                    .font(.footnote).foregroundStyle(Color.green)
            case .failed(let msg):
                Label("失败：\(msg)", systemImage: "xmark.octagon.fill")
                    .font(.footnote).foregroundStyle(Color.red)
            }

            ScrollView {
                Text(shown.isEmpty ? "（等待内核输出…）" : shown)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(shown.isEmpty ? Color.secondary : Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color.black.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
        .task { await run() }
        .onReceive(timer) { _ in
            shown = unameResult.isEmpty ? ConsoleHub.text : unameResult
        }
    }

    private var displayTextProxy: String { shown }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("万我").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("M0.2 · iSH 接入验证").font(.subheadline).foregroundStyle(Color.secondary)
        }
    }

    private func run() async {
        // 1. 首启装配（解包 rootfs.tar）
        if !FirstRun.isInstalled {
            do { try FirstRun.install() } catch {
                phase = .failed("rootfs 装配失败：\((error as NSError).localizedDescription)")
                return
            }
        }

        ConsoleHub.clear()
        ISHKernel.shared.outputCallback = { data in
            if let s = String(data: data, encoding: .utf8) {
                ConsoleHub.append(s)
            }
        }

        phase = .booting

        // 2. 拉内核（重量级，后台线程；bootWithRootPath 自带完整初始化与崩溃信号处理）
        let bootErr: String? = await Task.detached(priority: .userInitiated) { () -> String? in
            let rc = RootView.bootKernel()
            return rc == 0 ? nil : "boot rc=\(rc)"
        }.value

        if let bootErr {
            phase = .failed(bootErr)
            return
        }
        phase = .running

        // 3. 启动交互式 shell（executeCommand 负责起 PTY + /bin/sh；
        //    不先起 shell，executeCommandAndWait 的输入无人接收）
        let shellErr: Int32 = await Task.detached(priority: .userInitiated) { () -> Int32 in
            let rc = ISHKernel.shared.executeCommand(["/bin/sh", "-l"])
            if rc != 0 { return rc }
            // 给 shell 一点启动时间（提示符出现前注入命令会被回显吞掉）
            Thread.sleep(forTimeInterval: 1.5)
            return 0
        }.value

        if shellErr != 0 {
            phase = .failed("shell 启动失败 rc=\(shellErr)")
            return
        }

        // 4. 执行验收命令（executeCommandAndWait 自带完成检测与超时）
        let result = await Task.detached(priority: .userInitiated) { () -> (String, String?) in
            var out: String?
            var err: Error?
            ISHKernel.shared.executeCommandAndWait(
                "uname -a; echo; echo '万我 M0.2 · Alpine/AArch64 已启动'; id; cat /etc/alpine-release",
                timeout: 20,
                completion: { o, e in out = o as String?; err = e }
            )
            return (out ?? "", err?.localizedDescription)
        }.value

        if let err = result.1, !err.isEmpty {
            phase = .failed("验收命令失败：\(err)")
            return
        }
        unameResult = result.0
        phase = .done
    }

    /// bootWithRootPath 返回后内核可能仍在异步初始化：轮询 isBooted 兜底（最多 30s）。
    private static func bootKernel() -> Int32 {
        let rc = ISHKernel.shared.boot(withRootPath: FirstRun.rootURL.path)
        if rc != 0 { return rc }
        for _ in 0..<300 {
            if ISHKernel.shared.isBooted { return 0 }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return -99
    }
}
