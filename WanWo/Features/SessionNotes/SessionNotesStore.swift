//
//  SessionNotesStore.swift
//  WanWo
//
//  【语义移植 · Cline Memory Bank · M8 批2 件 B3】存储与更新 API。
//  语义源：memory-bank.mdx（六文件裁五，见 SessionNotesTypes 件头注）+
//  cline-deepread.md §1（Memory Bank 在 Cline 内核零实现——万我内核化）。
//
//  桶落点（每项目=工作区一桶，接续现有 workspace 根解析 API——登记）：
//    · 项目模式（cwd 落 /var/wanwo/projects/**）：桶 = WanWoPaths.
//      projectsHostRoot(forGuestPath: cwd)/wanwo-notes/——iSH fakefs 持久层
//      真实项目目录内，shell/文件工具/工作区文件树原生可见可手编（与
//      WorkspaceFileAccess 项目模式 rootURL 同一映射面）。
//    · legacy（cwd 空/为 /var/wanwo/workspace）：桶 = 会话 workspace 桶
//      （WanWoPaths.sessionPersistentDir(for:bucket:"workspace")）/wanwo-notes/
//      ——与 WorkspaceFileAccess legacy rootURL 同源；legacy 会话无共享项目
//      目录，桶随会话（登记：与"每项目一桶"的偏差在 legacy 形态下不可消除，
//      第三批项目分桶统一时收编）。
//
//  写纪律（万我增强——Cline 无格式防线，登记）：
//    · 编辑 = 全文重写 + 原子写（markdown 无并发编辑者）。
//    · 固定头标记保留校验：content 首个非空行 ≠ 该文件头标记 → 拒绝写入。
//    · 项目模式落 fakefs 持久层的宿主直写注册 meta.db（与 WorkspaceFileAccess
//      registerFakefsMetadataIfProjectMode 同语义；该方法为 private 不可复用，
//      此处为同语义实现，经 registrar 缝注入以便测试——登记）。
//
//  更新触发（Cline 四条件内核化，memory-bank.mdx :142-146——登记映射）：
//    1. 发现新模式 / 2. 重大变更后 / 4. 需澄清 → 调用方（工具/UI 另批）经
//       applyNoteUpdate(file:content:) 承载；
//    3. 显式"更新记忆库"命令 → 全量复审语义（MUST review ALL files :145）由
//       调用方对五文件逐件 applyNoteUpdate 承载——本批交付存储与更新 API。
//    压缩联动 / 回合收尾两缝见 SessionNotesHooks.swift（本批只交付协议+实现，
//    不接生产——登记）。
//

import Foundation

final class SessionNotesStore: @unchecked Sendable {
    /// 桶宿主目录（<workspace 根>/wanwo-notes/）。
    let notesDirectory: URL
    /// 桶 guest 路径（注入尾注记/工具面引用用）；legacy = 会话工作区桶映射的
    /// /var/wanwo/workspace/wanwo-notes。测试注入形态可为 nil。
    let guestNotesPath: String?
    /// 项目模式（桶落 fakefs 持久层真实项目目录）。
    let isProjectMode: Bool
    /// 写后 fakefs 元数据注册缝（注入以便测试；生产缺省 = 直连 IshExecutorBridge）。
    private let fakefsRegistrar: @Sendable (URL) -> Void

    private static let fileManager = FileManager.default

    // MARK: - 构造

    /// 生产构造（workspace 根解析接续 WanWoPaths 现有 API）。
    /// - Parameters:
    ///   - sessionId: 会话 id（legacy 桶根派生锚）。
    ///   - workspaceCwd: 会话 header cwd（创建时定格，AppEnvironment.makeAgentStack
    ///     writer.header.cwd 同源）。
    init(sessionId: String, workspaceCwd: String?) {
        // M8 批3 件 C2（桶收编）：项目模式桶解析改经 MemoryProjectLayout 同根
        // （wanwo-notes = wanwo-memory 兄弟桶——单一解析权威收口，冻结契约消费；
        // 值语义与原 projectsHostRoot 直解一致，c2-report 登记）。
        if let cwd = workspaceCwd,
           let projectHost = MemoryProjectLayout.memoryBucketURL(forCwd: cwd)?
            .deletingLastPathComponent() {
            self.isProjectMode = true
            self.notesDirectory = projectHost
                .appendingPathComponent(SessionNotesConstants.notesDirName,
                                        isDirectory: true)
            self.guestNotesPath = cwd + "/" + SessionNotesConstants.notesDirName
        } else {
            self.isProjectMode = false
            self.notesDirectory = WanWoPaths.sessionPersistentDir(
                for: sessionId, bucket: "workspace")
                .appendingPathComponent(SessionNotesConstants.notesDirName,
                                        isDirectory: true)
            self.guestNotesPath = WanWoPaths.workspaceLinuxDir + "/"
                + SessionNotesConstants.notesDirName
        }
        self.fakefsRegistrar = { url in
            Self.registerFakefsMetadataIfGuest(url)
        }
    }

    /// 测试/注入构造（目录与 guest 路径直给；registrar 可换 no-op）。
    init(notesDirectory: URL, guestNotesPath: String?,
         isProjectMode: Bool = false,
         fakefsRegistrar: @Sendable (URL) -> Void = { _ in }) {
        self.notesDirectory = notesDirectory
        self.guestNotesPath = guestNotesPath
        self.isProjectMode = isProjectMode
        self.fakefsRegistrar = fakefsRegistrar
    }

    // MARK: - 桶生命周期

    /// 空文件起步（memory-bank.mdx "initialize memory bank" 的确定性等价：
    /// 建桶 + 五文件各只含固定头标记一行，不预填内容——登记）。幂等：
    /// 已存在的文件不动（用户手编内容不覆写）。
    func ensureBucket() {
        try? Self.fileManager.createDirectory(at: notesDirectory,
                                              withIntermediateDirectories: true)
        for file in SessionNoteFile.allCases {
            let url = notesDirectory.appendingPathComponent(file.fileName)
            guard !Self.fileManager.fileExists(atPath: url.path) else { continue }
            writeAtomic(url, data: Data((SessionNotesHeader.marker(for: file) + "\n").utf8))
        }
    }

    // MARK: - 读

    /// 读某文件（剥头标记后的正文；trim 后空 / 文件不存在 / 读失败 = nil——
    /// 注入端槽位缺省零扰动语义）。
    func readBody(_ file: SessionNoteFile) -> String? {
        let url = notesDirectory.appendingPathComponent(file.fileName)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let body = SessionNotesHeader.body(afterMarker: raw, for: file)
        return body.isEmpty ? nil : body
    }

    // MARK: - 显式更新 API（Cline 触发条件 1/2/3/4 的统一承载面）

    /// 全文重写式更新（纯函数语义：确定性校验 + 原子落盘；"更新记忆库"的全量
    /// 复审编排由调用方承载——工具/UI 另批，登记）。
    /// - Throws: SessionNotesError.headerMarkerMissing（头行被删/被改=拒绝写入
    ///   防格式漂移——万我增强，Cline 无格式防线）。
    func applyNoteUpdate(file: SessionNoteFile, content: String) throws {
        guard SessionNotesHeader.isPresent(in: content, for: file) else {
            throw SessionNotesError.headerMarkerMissing(file)
        }
        let url = notesDirectory.appendingPathComponent(file.fileName)
        try? Self.fileManager.createDirectory(at: notesDirectory,
                                              withIntermediateDirectories: true)
        writeAtomic(url, data: Data(content.utf8))
    }

    // MARK: - 注入（SessionNotesInjection 的数据面）

    /// 注入尾注记引用的 guest 路径形态（nil = 测试注入形态，尾注记省略路径）。
    var guestReference: String? { guestNotesPath }

    // MARK: - 原子写与 fakefs 注册

    private func writeAtomic(_ url: URL, data: Data) {
        let fm = Self.fileManager
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        var isDir: ObjCBool = false
        let targetExists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        do {
            if targetExists && isDir.boolValue {
                try? fm.removeItem(at: tmp)
                return
            }
            if targetExists {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                _ = try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            return
        }
        // 项目模式：宿主直写须同步注册 fakefs 元数据（meta.db 为存在真相源；
        // 与 WorkspaceFileAccess.registerFakefsMetadataIfProjectMode 同语义，
        // registrar 缝承载——登记）。
        fakefsRegistrar(url)
    }

    /// 宿主 URL → guest 路径反推 + fakefs 元数据注册（guestRoot 之外的路径
    /// 静默跳过——fail open，与 WorkspaceFileAccess 同语义）。
    private static func registerFakefsMetadataIfGuest(_ url: URL) {
        var p = url.standardizedFileURL.path
        if p.hasPrefix("/private") { p = String(p.dropFirst("/private".count)) }
        let guestRootPath = RootfsInstaller.shared.dataPath.standardizedFileURL.path
        guard p.hasPrefix(guestRootPath + "/") else { return }
        let guestPath = "/" + String(p.dropFirst(guestRootPath.count + 1))
        IshExecutorBridge.ensureParentDirsInMetaDB(for: guestPath)
        IshExecutorBridge.ensureFakefsMetadata(for: guestPath, isDirectory: false)
    }
}
