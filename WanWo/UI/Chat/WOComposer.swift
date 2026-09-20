//
//  WOComposer.swift
//  WanWo
//
//  R2c composer 全量批（digest-H 原型 composer 节逐值；引擎 = 既有 ChatViewModel，
//  附件/slash/权限/模型缝全部既有，零引擎改动）：
//  - 卡体：白底 r22 + shadow-soft + 0.5px l3 发丝描边（digest-H Composer 节）
//  - 附件：+ 钮 28px 圆（PhotosPicker 相册/文件两源）→ VM.addDraftImages
//    （intake 预检整批拒绝语义在 VM 层，InputBar.tsx:220-245 1:1）
//  - 附件 chip 条：26px 高、蓝 100 底、圆角 8px、fadeUp .35s 入场、移除钮 16px 圆
//    （digest-H 附件 chips 节；左滑越阈移除沿用用户既定交互形态）
//  - 消息内图片不在本件（WOChatView 气泡侧复用 MessageImagesView，单图 80pt
//    =用户既定裁定）
//  - 发送钮 34px 圆、disabled 透明 .4（digest-H）；运行中同位变停止（dsh
//    primaryStops 语义，VM 层已给 phase）
//  - WOSlashMenu：dd 规格浮出菜单（r20、padding 4、行 min-height 40 圆角 10、
//    digest-H 弹层节）；数据源 = VM.slashCommandList（引擎既有命令面）
//
//  触屏纪律：无 hover 依赖；所有可见交互真响应。
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Composer

struct WOComposer: View {
    @ObservedObject var viewModel: ChatViewModel
    /// 占位文案（digest-H 文案清单：会话中「发消息或做任务…」；hero 变体
    /// 「描述你想要构建的内容…」由宿主传入）。
    var placeholder: String = "发消息或做任务… / 调用指令 @ 文件或对话"

    /// 模型面降级（VM.isModelReady == false：装配失败无 loop，send 静默
    /// no-op）——发送钮诚实禁用，原因由宿主的降级横幅呈现。
    var degraded: Bool = false

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var draftPreview: UIImage?

    private var canSend: Bool {
        guard !degraded else { return false }
        switch viewModel.phase {
        case .idle, .failed:
            return !viewModel.isDraftEmpty || !viewModel.draftImages.isEmpty
        default:
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 附件 chip 条（输入框上方；digest-H 附件 chips 形态）。
            if !viewModel.draftImages.isEmpty {
                WODraftImageChips(images: viewModel.draftImages,
                                  onPreview: { draftPreview = $0 },
                                  onRemove: { viewModel.removeDraftImage(id: $0) })
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }

            TextField(placeholder, text: $viewModel.draft, axis: .vertical)
                .font(.system(size: 14))
                .lineSpacing(10) // 14px/24px 行高（digest-H textarea 规格）
                .tint(WOAlias.stateBusinessPrimary) // caret 蓝
                .lineLimit(1...7) // max-height 168px ≈ 7×24px
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if let banner = viewModel.attachmentBanner {
                bannerRow(banner)
            }

            toolRow
        }
        // digest-H composer 卡体：白底 r22 + soft 阴影 + 0.5px l3 发丝描边。
        .background(RoundedRectangle(cornerRadius: 22).fill(WOAlias.bgBase))
        .overlay(RoundedRectangle(cornerRadius: 22)
            .strokeBorder(WOAlias.borderL3, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.03), radius: 16, y: 4)
        .shadow(color: .black.opacity(0.03), radius: 24)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 16)
        // 待发送图原图预览（dsh ImageLightbox 形态；根因修复沿旧 ChatView
        // ——fit 内容占满容器，防 topTrailing 对齐竖图偏移）。
        .fullScreenCover(isPresented: Binding(get: { draftPreview != nil },
                                              set: { if !$0 { draftPreview = nil } })) {
            draftPreviewCover
        }
        .onChange(of: photoSelection) { items in
            guard !items.isEmpty else { return }
            let picked = items
            photoSelection = []
            Task { await intakePhotoSelection(picked) }
        }
    }

    // MARK: 工具行（+ 钮 / 权限 / 模型 / ContextMeter / 发送-停止）

    private var toolRow: some View {
        HStack(spacing: 8) {
            // + 钮 28px 圆（digest-H：导入图片/文件；PhotosPicker 相册两源）。
            // 左侧独占（原型 dock：+ 在左，其余全右）。
            PhotosPicker(selection: $photoSelection, matching: .images) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(WOAlias.labelSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(WOAlias.bgModulePlatform))
                    .overlay(Circle().strokeBorder(WOAlias.borderL2, lineWidth: 0.5))
            }
            .accessibilityLabel("添加图片")

            Spacer(minLength: 0)

            // 右侧组（2026-09-21 用户令：选模型在右边——原型 dock 布局）：
            // 权限胶囊 → 模型 pill → ContextMeter 环 → 发送/停止。

            // 权限胶囊（盾形三态；RiskConfirmation 确认缝内建——one path）。
            PermissionSelectView(
                currentPreset: viewModel.currentPermissionPreset ?? "",
                busy: false,
                onCommand: { line, confirmed in
                    viewModel.runCommandLine(line, confirmed: confirmed)
                })
                .font(.system(size: 12))

            // 模型两级菜单（provider 分组 + effort 层；会话级选择）。
            ModelSelectView(store: viewModel.endpointStore,
                            current: viewModel.currentModelEndpoint,
                            currentEffort: viewModel.sessionEffort,
                            onSelect: { viewModel.selectModel($0) },
                            onEffort: { viewModel.selectEffort($0) })
                .font(.system(size: 12))

            // ContextMeter 环（pressure 在场才显示；F041 压力呈现）。
            if let pressure = viewModel.pressure {
                ContextMeterView(pressure: pressure)
            }

            if viewModel.phase == .streaming {
                // 停止（引擎 cancel；对话环另一半）。
                Button {
                    viewModel.cancel()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(WOStatic.neutral00)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(WOAlias.labelPrimary))
                }
                .buttonStyle(.plain)
                .woPressable()
                .accessibilityLabel("停止")
            } else {
                // 发送钮 34px 圆、disabled 透明 .4（digest-H）。
                Button {
                    viewModel.send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(canSend ? WOStatic.neutral00 : WOAlias.labelTertiary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(canSend ? WOAlias.buttonPrimaryFill
                                                          : WOAlias.bgModulePlatform))
                        .opacity(canSend ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .woPressable()
                .accessibilityLabel("发送")
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    // MARK: 附件横幅（intake 拒绝文案；dsh showToast → 横幅同语义）

    private func bannerRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(WOAlias.stateWarnLabel)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(WOAlias.stateWarnLabel)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                viewModel.attachmentBanner = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(WOAlias.labelTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: 待发送图原图预览 cover

    private var draftPreviewCover: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let draftPreview {
                Image(uiImage: draftPreview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
            }
            Button {
                draftPreview = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color.black.opacity(0.5), in: Circle())
            }
            .padding(14)
            .accessibilityLabel("关闭原图预览")
        }
    }

    // MARK: 附件 intake（旧 ChatView.intakePhotoSelection 1:1 搬运）

    private func intakePhotoSelection(_ items: [PhotosPickerItem]) async {
        var candidates: [ChatViewModel.DraftImageCandidate] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                continue
            }
            candidates.append(.init(data: data,
                                    mediaType: Self.mediaType(of: item.supportedContentTypes),
                                    name: nil))
        }
        viewModel.addDraftImages(candidates)
    }

    /// UTType → 媒体类型白名单映射（dsh mediaTypes 白名单的 iOS 对应物）。
    nonisolated private static func mediaType(of types: [UTType]) -> ImageMediaType? {
        for type in types {
            if type.conforms(to: .png) { return .png }
            if type.conforms(to: .jpeg) { return .jpeg }
            if type.conforms(to: UTType("org.webpproject.webp") ?? .data) { return .webp }
            if type.conforms(to: .gif) { return .gif }
        }
        return nil
    }
}

// MARK: - 待发送图片 chip 条（digest-H：26px 高、蓝 100 底、r8、移除钮 16px 圆）

struct WODraftImageChips: View {
    let images: [ChatViewModel.DraftImage]
    /// 点 chip 回传（原图预览）。
    let onPreview: (UIImage) -> Void
    /// 移除回传（移除钮 / 左滑越阈 / 长按菜单三通道）。
    let onRemove: (UUID) -> Void

    var body: some View {
        ChipFlowLayout(spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                WODraftImageChip(
                    title: DraftImageChipsView.chipTitle(for: image, index: index),
                    data: image.data,
                    onPreview: onPreview,
                    onRemove: { onRemove(image.id) })
            }
        }
    }
}

/// 单枚 chip：tap = 预览、移除钮/左滑越阈/长按菜单 = 移除；fadeUp .35s 入场。
private struct WODraftImageChip: View {
    let title: String
    let data: Data
    let onPreview: (UIImage) -> Void
    let onRemove: () -> Void

    /// 左滑位移（只跟随负向；松手回弹或触发移除——用户既定交互形态沿旧件）。
    @State private var dragX: CGFloat = 0
    private let removeThreshold: CGFloat = -64

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "photo")
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(WOAlias.labelSecondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(WOStatic.neutral00.opacity(0.72)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除图片")
        }
        .foregroundColor(WOAlias.stateBusinessPrimary)
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .frame(height: 26)
        // digest-H 附件 chips：蓝 100 底（#E4EDFD = deepseek100）圆角 8px。
        .background(RoundedRectangle(cornerRadius: 8).fill(WOStatic.deepseek100))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .offset(x: dragX)
        .animation(.interactiveSpring(response: 0.3), value: dragX)
        .onTapGesture {
            if let ui = UIImage(data: data) { onPreview(ui) }
        }
        .gesture(swipeGesture)
        .contextMenu {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("移除图片", systemImage: "trash")
            }
        }
        .accessibilityLabel("待发送图片 \(title)")
        .accessibilityHint("点按两下查看原图，可移除")
        .modifier(WOEntryModifier(offset: CGSize(width: 0, height: 8),
                                  scale: 1, duration: 0.35, animate: true))
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onChanged { value in
                dragX = min(0, value.translation.width)
            }
            .onEnded { value in
                if value.translation.width < removeThreshold {
                    onRemove()
                }
                dragX = 0
            }
    }
}

// MARK: - Slash 命令菜单（digest-H dd 弹层规格；数据源 = VM.slashCommandList）

struct WOSlashMenu: View {
    /// 当前过滤词（"" = 全列；"/np" 前缀过滤——MenuView 查询细化语义）。
    let query: String
    let commands: [SlashCommandRegistry.Command]
    let onPick: (SlashCommandRegistry.Command) -> Void

    /// 设计高度上限（MenuView.tsx:25 / PopupSelectView.tsx:22 MAX_HEIGHT 320）。
    private let maxHeight: CGFloat = 320

    private var filtered: [SlashCommandRegistry.Command] {
        let prefix = query.trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { return commands }
        return commands.filter { "/\($0.name)".hasPrefix(prefix) }
    }

    var body: some View {
        // 少量命令直接整列呈现（ScrollView 贪吃高度——几张命令也撑满 320 造成
        // 空腔）；超出设计上限才滚动封顶（MAX_HEIGHT 320）。
        Group {
            if filtered.count > 7 {
                ScrollView { menuList }
                    .frame(height: maxHeight)
            } else {
                menuList
            }
        }
        .frame(maxWidth: 420)
        // digest-H dd 弹层：r20、白底、发丝描边 + 阴影。
        .background(RoundedRectangle(cornerRadius: 20).fill(WOAlias.bgBase))
        .overlay(RoundedRectangle(cornerRadius: 20)
            .strokeBorder(WOAlias.borderL2, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
        .accessibilityLabel("指令菜单")
    }

    private var menuList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if filtered.isEmpty {
                Text("无匹配指令")
                    .font(.system(size: 12))
                    .foregroundColor(WOAlias.labelTertiary)
                    .padding(12)
            }
            ForEach(filtered, id: \.name) { command in
                Button {
                    onPick(command)
                } label: {
                    // 行 = 名称 + 描述（MenuView.tsx 行形态；dd 行 40px 圆角 10）。
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("/\(command.name)")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(WOAlias.labelPrimary)
                        Text(command.summary)
                            .font(.system(size: 12))
                            .foregroundColor(WOAlias.labelTertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(WOAlias.bgBase))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
    }
}
