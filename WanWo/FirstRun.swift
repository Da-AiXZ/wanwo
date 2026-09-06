import Foundation

/// 首启装配：把 bundle 内的 rootfs.tar（fakefs 格式：data/ + meta.db）解到 App 容器。
/// fakefs 的权限/属主在 meta.db 里；tar 头里的 mode 用于还原文件权限（双保险）。
enum FirstRun {
    static var rootURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("root", isDirectory: true)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("meta.db").path)
    }

    /// 解包 bundle 的 rootfs.tar → Documents/root（含 data/ 与 meta.db）
    static func install() throws {
        guard let tar = Bundle.main.url(forResource: "rootfs", withExtension: "tar") else {
            throw NSError(domain: "WanWo.FirstRun", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bundle 内未找到 rootfs.tar 资源"])
        }
        try MiniTar.extract(archive: tar, to: rootURL)
        // 确认关键产物存在
        guard FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("meta.db").path),
              FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("data").path) else {
            throw NSError(domain: "WanWo.FirstRun", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "rootfs 解包后缺少 meta.db/data"])
        }
    }
}
