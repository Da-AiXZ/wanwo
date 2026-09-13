//
//  SkillSettingsStore.swift
//  WanWo
//
//  【M4-D 件 D7 · F030 设置面持久宿主】启停覆盖（skills-settings.json
//  {"disabledSkills": [...]}）。语义锚点：codex selection.rs ExplicitSkillLookup
//  .disabled_paths + is_skill_enabled（:26-28）——WanWo 形态=按 name 的覆盖层
//  （平台差异登记：codex 按路径禁用，WanWo 设置页按名启停——名字是发现面唯一
//  身份键，skills.md:85）。
//
//  消费形态（registry 出口过滤覆盖层）：
//    · DisabledIndex（@unchecked Sendable，自带锁）= registry 快照路径任意线程
//      消费的读面（contains）+ 缓存对齐键（revision）；
//    · revision 递增（启停 replace / 导入 noteExternalChange）→ 所有 registry
//      实例缓存键失配 → 下一快照重扫（失效三通道③的跨实例实现——设置页改动
//      对活动会话即时生效，无需逐实例 invalidate）；
//    · 启停过滤在 registry snapshot 出口逐读评估（数组遍历成本可忽略），
//      设置页列表面走 snapshotIncludingDisabled（覆盖层不滤——要能重新启用）。
//
//  文件位置：config/skills-settings.json（Application Support 约定——
//  providers.json / permission-default.json / mcp-servers/servers.json 同族）。
//  损坏容忍：单键数组结构，整体回退空集 + 记日志（MCPStore 逐条容忍的单键
//  退化形态，round-trip 无未知键丢弃面——WanWo 唯一写者）。
//

import Foundation

@MainActor
final class SkillSettingsStore: ObservableObject {

    /// skills-settings.json 唯一键。
    static let disabledKey = "disabledSkills"

    /// 线程安全读面（registry 任意线程消费；主线程写、跨线程读同源）。
    let disabledIndex = DisabledIndex()

    /// 已停用技能名（UI 绑定面；与 disabledIndex 同步更新）。
    @Published private(set) var disabledSkills: Set<String>

    private let fileURL: URL
    private static let logger = AppLogger(category: "SkillSettings")

    init(fileURL: URL) {
        self.fileURL = fileURL
        let loaded = Self.readDisabled(fileURL: fileURL)
        disabledSkills = loaded
        disabledIndex.replace(loaded)
    }

    /// 便捷判定（走线程安全索引；UI 与测试共用）。
    func isDisabled(_ name: String) -> Bool {
        disabledIndex.contains(name)
    }

    /// 启停一项（幂等；无变化不落盘）。
    func setDisabled(_ disabled: Bool, name: String) {
        var updated = disabledSkills
        if disabled {
            updated.insert(name)
        } else {
            updated.remove(name)
        }
        guard updated != disabledSkills else { return }
        disabledSkills = updated
        disabledIndex.replace(updated)
        persist(updated)
    }

    /// 外部变更通知（D7 导入落盘后调用）：revision 递增 → registry 实例缓存
    /// 失配重扫；objectWillChange 驱动设置页列表刷新。
    func noteExternalChange() {
        disabledIndex.bumpRevision()
        objectWillChange.send()
    }

    // MARK: - 磁盘读写

    private func persist(_ disabled: Set<String>) {
        let payload: [String: Any] = [Self.disabledKey: disabled.sorted()]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]) else {
            Self.logger.error("skills-settings encode failed")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("skills-settings write failed: "
                              + "\(String(describing: error))")
        }
    }

    /// 损坏容忍读：文件缺失=空集（首次）；结构不符=空集+日志（不整 App 崩）。
    private static func readDisabled(fileURL: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root[disabledKey] as? [String] else {
            logger.error("skills-settings.json unparseable at \(fileURL.path) — ignoring")
            return []
        }
        return Set(list)
    }

    // MARK: - 线程安全索引

    /// 禁用名索引 + revision（@unchecked Sendable：NSLock 护全部可变态；
    /// registry 快照路径（扫描线程/组装线程）与主线程 UI 共享消费）。
    final class DisabledIndex: @unchecked Sendable {
        private let lock = NSLock()
        private var disabled: Set<String> = []
        private var revision = 0

        /// 缓存对齐键（registry snapshot 缓存键的一部分——变化即重扫）。
        var currentRevision: Int {
            lock.lock()
            defer { lock.unlock() }
            return revision
        }

        func contains(_ name: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return disabled.contains(name)
        }

        func replace(_ updated: Set<String>) {
            lock.lock()
            defer { lock.unlock() }
            disabled = updated
            revision += 1
        }

        func bumpRevision() {
            lock.lock()
            defer { lock.unlock() }
            revision += 1
        }
    }
}
