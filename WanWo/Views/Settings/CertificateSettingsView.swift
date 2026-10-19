//
//  CertificateSettingsView.swift
//  WanWo
//
//  【N7b 件②】设置页签名证书分区视图 + 导入 sheet（方案 §二 N7b-2）。
//  官方对照（0.10.3 CertificateController 101 行 + CertificateImporter 137
//  行，UIKit 表单形态）：状态行（validateCertificate 异步——status==0 绿显
//  "Certificate Valid Till <date>"，否则红显 Invalid）+「Import Certificate」
//  入口 → 导入表单（证书文件 + 密码两段，Submit 存储后回调刷新）。
//  万我适配（SwiftUI 呈现，逻辑/文案语义照抄）：
//    · 状态行 = 未配置灰 / 已配置走 SigningSetupService.validateCertificate
//      （绿=有效至 <date>，红=失败原因）——官方同款三态语义；
//    · 导入 sheet = p12 文件选择器 + mobileprovision 文件选择器 + 密码
//      SecureField + 提交（fileImporter 形态——SkillsView 同款 SwiftUI 原生
//      封装）；比官方多一段 mobileprovision 选择器（万我导入式三件套，见
//      CertificateStore 头注）；
//    · 提交 = CertificateStore.save（密码 Keychain + 双文件沙盒落盘）。
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设置页分区视图

struct CertificateSettingsView: View {
    /// 校验结果（未加载 = nil——骨架态）。
    @State private var status: SigningCertificateStatus?
    /// 导入 sheet 呈现。
    @State private var showingImportSheet = false
    /// 清除确认（防误触——三件材料一次清空不可恢复）。
    @State private var showingClearConfirm = false

    var body: some View {
        List {
            Section {
                statusRow
            } header: {
                Text("证书状态")
            } footer: {
                Text("用于构建产物签名安装（N7 链）。需 adhoc 开发证书"
                     + "（含 get-task-allow），Distribution 证书不支持。")
            }
            Section {
                Button {
                    showingImportSheet = true
                } label: {
                    Label("导入证书", systemImage: "square.and.arrow.down")
                }
                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    Label("清除证书", systemImage: "trash")
                }
                .disabled(!isConfiguredLocally())
            } footer: {
                Text("密码存 Keychain；p12 与描述文件存 App 沙盒"
                     + "（Application Support/WanWoSigning/）。")
            }
        }
        .navigationTitle("签名证书")
        .task { await refreshStatus() }
        .sheet(isPresented: $showingImportSheet, onDismiss: {
            Task { await refreshStatus() }
        }) {
            CertificateImportSheet()
        }
        .confirmationDialog(
            "清除已导入的签名证书？", isPresented: $showingClearConfirm,
            titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                CertificateStore.clear()
                status = nil
                Task { await refreshStatus() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 状态行（官方 CertificateController.updateCertificateState 三态）

    @ViewBuilder
    private var statusRow: some View {
        if let status = status {
            HStack(spacing: 10) {
                Image(systemName: iconName(for: status))
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.message)
                    Text(detailLine(for: status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(statusColor(for: status))
        } else {
            // 骨架态（校验进行中——checkCert 走 openssl 解析，非即时）。
            HStack(spacing: 10) {
                ProgressView()
                Text("校验中…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 三态配色（官方语义：有效绿/无效红/未配置灰）。
    private func statusColor(for status: SigningCertificateStatus) -> Color {
        if !status.configured {
            return Color.secondary
        }
        if status.isValid {
            return Color.green
        }
        return Color.red
    }

    private func iconName(for status: SigningCertificateStatus) -> String {
        if !status.configured {
            return "seal"
        }
        if status.isValid {
            return "checkmark.seal.fill"
        }
        return "xmark.seal.fill"
    }

    /// 第二行细目（有效期/导入时间——拆步拼接防插值链雷区形态）。
    private func detailLine(for status: SigningCertificateStatus) -> String {
        if status.isValid, let date = status.expirationDate {
            return "有效期至 " + Self.formatDate(date)
        }
        let importDate = CertificateStore.importDate
        if let importDate = importDate {
            return "导入于 " + Self.formatDate(importDate)
        }
        return ""
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// 按钮可用性兜底（status 未加载时用存储面直查）。
    private func isConfiguredLocally() -> Bool {
        if let status = status {
            return status.configured
        }
        return CertificateStore.isConfigured
    }

    /// 异步刷新（SigningSetupService.checkCert 桥接 await）。
    private func refreshStatus() async {
        let fresh = await SigningSetupService.validateCertificate()
        status = fresh
    }
}

// MARK: - 导入 sheet（官方 CertificateImporter 三段形态 SwiftUI 化）

struct CertificateImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// p12 选择结果。
    @State private var p12URL: URL?
    /// mobileprovision 选择结果。
    @State private var profileURL: URL?
    /// p12 导出密码（官方 hint "i.e 123456" 语义）。
    @State private var password = ""
    /// 文件选择器呈现（单一实例——装机复测实证：同视图挂两个 .fileImporter
    /// 时 SwiftUI presentation 互相抢占，仅最后一个生效（描述文件能弹、p12
    /// 静默无反应）——合并为单选择器按扩展名自动分流，两行入口共用。
    @State private var isFilePickerPresented = false
    /// 提交失败信息（官方 NotificationServer.NotifyUser(.error) 同语义，
    /// sheet 内改行内红字）。
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    fileRow(
                        title: "证书文件 (p12)",
                        selectedName: p12FileName,
                        systemImage: "key.fill",
                        isPresented: $isFilePickerPresented)
                } footer: {
                    Text("从证书颁发机构导出的 .p12 身份证书（含私钥）。")
                }
                Section {
                    fileRow(
                        title: "描述文件 (mobileprovision)",
                        selectedName: profileFileName,
                        systemImage: "doc.text.fill",
                        isPresented: $isFilePickerPresented)
                } footer: {
                    Text("与证书配套的 adhoc 描述文件（.mobileprovision）。")
                }
                Section {
                    SecureField("i.e 123456", text: $password)
                } header: {
                    Text("证书密码")
                }
                if let message = errorMessage {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("导入证书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提交") { submit() }
                        .disabled(!isSubmitReady() || isSubmitting)
                }
            }
            .fileImporter(
                isPresented: $isFilePickerPresented,
                // 全量 .data（UTType(tag:) 动态解析的 UTI 在文档选择器呈现
                // 上不可靠——p12 选择器静默失败实证之一）；选错类型由
                // routePickedFile 按扩展名校验给行内红字。
                allowedContentTypes: [.data]) { result in
                guard let url = Self.selectedURL(from: result) else { return }
                Self.routePickedFile(
                    url,
                    toP12: { p12URL = $0 },
                    toProfile: { profileURL = $0 },
                    onError: { errorMessage = $0 })
            }
        }
    }

    // MARK: 行视图

    /// 文件选择行（已选显文件名，未选显入口文案）。
    private func fileRow(
        title: String, selectedName: String?, systemImage: String,
        isPresented: Binding<Bool>) -> some View {
        Button {
            isPresented.wrappedValue = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(selectedName ?? "点击选择文件…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: 提交（官方 importButton 语义：读文件→存储→dismiss→回调刷新）

    private var p12FileName: String? {
        p12URL?.lastPathComponent
    }

    private var profileFileName: String? {
        profileURL?.lastPathComponent
    }

    /// 提交就绪（两件文件齐 + 非提交中）。
    private func isSubmitReady() -> Bool {
        let p12Ready = p12URL != nil
        let profileReady = profileURL != nil
        return p12Ready && profileReady
    }

    private func submit() {
        guard let p12 = p12URL, let profile = profileURL else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            do {
                let p12Data = try Self.readData(from: p12)
                let profileData = try Self.readData(from: profile)
                try CertificateStore.save(
                    p12: p12Data, password: password, profile: profileData)
                dismiss()
            } catch {
                // 官方语义："Something went wrong importing the certificate!"
                errorMessage = "导入失败：\(error.localizedDescription)"
                isSubmitting = false
            }
        }
    }

    // MARK: 文件读取助手

    /// fileImporter 结果展开（失败 = nil——行视图回退"未选择"态）。
    private static func selectedURL(from result: Result<URL, Error>) -> URL? {
        if case .success(let url) = result {
            return url
        }
        return nil
    }

    /// 安全域读文件（fileImporter 交付的是 security-scoped URL——读取期间
    /// 须持访问权；官方 Data(contentsOf:) 直读同语义，万我补作用域纪律）。
    private static func readData(from url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try Data(contentsOf: url)
    }

    /// 扩展名 → UTType（已废弃——UTType(tag:) 动态解析的 UTI 在文档选择器
    /// 呈现上不可靠，统一走 [.data] + 扩展名分流）。

    /// 选择结果按扩展名分流（p12 → 证书段；mobileprovision → 描述文件段；
    /// 其他 → 行内红字提示。全拆步防插值链雷区形态）。
    private static func routePickedFile(
        _ url: URL,
        toP12: (URL) -> Void,
        toProfile: (URL) -> Void,
        onError: (String) -> Void) {
        let ext = url.pathExtension.lowercased()
        if ext == "p12" {
            toP12(url)
            return
        }
        if ext == "mobileprovision" {
            toProfile(url)
            return
        }
        onError("请选择 .p12 证书或 .mobileprovision 描述文件（当前为 ." + ext + "）")
    }
}
