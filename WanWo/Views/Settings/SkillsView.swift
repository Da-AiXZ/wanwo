//
//  SkillsView.swift
//  WanWo
//
//  【M4-D 件 D7 · F030 设置页最小面】列表/启停/导入（scope brief R4：最小
//  功能版，视觉 M9 对齐）。取证登记：dsh apps/web 无技能设置页原件（src 仅
//  4 个引导文件，技能面只有 e2e slash 菜单测试）——最小素净版落定，M9 对齐
//  登记随收。SwiftUI 形态沿 WanWo Settings 族（MCPServersView 同款：List+
//  行内 Toggle+footer；启停即改即生效——store.revision 驱动全部 registry
//  实例缓存失配重扫，通道③跨实例实现见 SkillSettingsStore 头注）。
//
//  列表口径：user+bundled 两根（displayRegistry）；project 根=会话工作区桶，
//  跨会话不可见是 D2 review 已登记的分层固有语义，设置页不列。展示用
//  snapshotIncludingDisabled（覆盖层不滤——要能重新启用）；会话消费面走
//  snapshot（已滤）。
//
//  导入：SwiftUI fileImporter（底层 UIDocumentPickerViewController——F071
//  picker 面的 SwiftUI 原生封装，单/批量统一交付，allowsMultipleSelection）。
//

import SwiftUI
import UniformTypeIdentifiers

struct SkillsView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var store: SkillSettingsStore

    /// 设置页展示注册表（user+bundled 两根，见头注；settings 注入=覆盖层宿主）。
    private let displayRegistry: SkillRegistry

    @State private var snapshot = SkillSnapshot(summaries: [], errors: [])
    @State private var showingImporter = false
    @State private var importNotice: String?

    init(environment: AppEnvironment) {
        self.environment = environment
        _store = ObservedObject(wrappedValue: environment.skillSettingsStore)
        displayRegistry = SkillRegistry(
            roots: [
                .init(source: .user, baseURL: WanWoPaths.skillsPersistentDir),
                .init(source: .bundled,
                      baseURL: WanWoPaths.skillsPersistentDir
                          .appendingPathComponent(".bundled", isDirectory: true)),
            ],
            settings: environment.skillSettingsStore)
    }

    var body: some View {
        List {
            Section {
                ForEach(snapshot.summaries, id: \.name) { summary in
                    skillRow(summary)
                }
            } header: {
                Text("技能")
            } footer: {
                Text("停用后技能从模型目录/工具/触发面整体移除，即时生效。"
                     + "会话工作区（.agents/skills）技能按会话独立，不在本列表。")
            }
            if !snapshot.errors.isEmpty {
                Section("扫描问题") {
                    ForEach(snapshot.errors, id: \.self) { error in
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button {
                    showingImporter = true
                } label: {
                    Label("导入技能文件…", systemImage: "square.and.arrow.down")
                }
                if let importNotice {
                    Text(importNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("导入")
            } footer: {
                Text("支持技能目录（含 SKILL.md）或 .md 文件，可多选；导入到持久"
                     + "技能目录（全部会话可用），同名跳过。")
            }
        }
        .navigationTitle("Skills")
        .onAppear { reload() }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: SkillsView.importTypes,
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
    }

    /// folder + .md（UTType 无内置 md——按扩展名构造，回退 plainText）。
    private static let importTypes: [UTType] = [
        .folder,
        UTType(filenameExtension: "md") ?? .plainText,
    ]

    @ViewBuilder
    private func skillRow(_ summary: SkillSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(summary.name)
                    .font(.headline)
                Text(summary.source.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { !store.isDisabled(summary.name) },
                    set: { enabled in
                        store.setDisabled(!enabled, name: summary.name)
                        reload()
                    }))
                    .labelsHidden()
            }
            Text(summary.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func reload() {
        // 失效即重扫（导入/外部变更后的展示对齐；快照幂等低成本）。
        displayRegistry.invalidate()
        snapshot = displayRegistry.snapshotIncludingDisabled()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importNotice = "导入失败：\((error as NSError).localizedDescription)"
        case .success(let urls):
            let outcome = SkillImporter.importItems(
                at: urls, into: WanWoPaths.skillsPersistentDir)
            // 通道③跨实例：revision 递增 → 活动 registry 缓存失配重扫。
            store.noteExternalChange()
            reload()
            importNotice = Self.notice(for: outcome, selectedCount: urls.count)
        }
    }

    /// 单/批量判定的最小呈现（单项直陈，批量计数；登记：文案面）。
    private static func notice(for outcome: SkillImportResult,
                               selectedCount: Int) -> String {
        var parts: [String] = []
        let verb = selectedCount == 1 ? "导入" : "批量导入 \(selectedCount) 项"
        if !outcome.imported.isEmpty {
            parts.append("\(verb)成功 \(outcome.imported.count) 项")
        } else {
            parts.append("\(verb)：无可导入项")
        }
        if !outcome.skipped.isEmpty {
            parts.append("同名跳过 \(outcome.skipped.count) 项")
        }
        if !outcome.failed.isEmpty {
            parts.append("失败 \(outcome.failed.count) 项")
        }
        return parts.joined(separator: "，")
    }
}
