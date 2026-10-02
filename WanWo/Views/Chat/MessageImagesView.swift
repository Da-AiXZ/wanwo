//
//  MessageImagesView.swift
//  WanWo
//
//  【形态对齐 dsh】出处：ui-attachment/src/MessageImage.tsx（MessageImage：
//  singleFit 长边 240、比率 clamp [0.25,4]、不放大、多图 64px 方格、失败可
//  重试）+ ui-attachment/src/client/MessageImages.tsx（消息侧 ImageGallery
//  入口）+ ImageLightbox（原图预览）。
//  zh 文案：ui-conversation locales.ts image.* 逐字（:36-40）。
//

import SwiftUI
import UIKit

/// 消息气泡内图片（dsh ImageGallery 形态）：单图 singleFit 尺寸、
/// 多图 64pt 方格；点击回传原图预览。
/// 【T2.8 件2】lightbox 状态上提 ChatView 根层集中管理（对齐 draftPreview
/// 的根层 cover 既有模式）——cover 挂在气泡内深层组件时，宿主视图身份在
/// List/流式重建场景失效 → present 静默失败（SwiftUI 已知坑）；组件内
/// @State lightbox + fullScreenCover 移除，改为 onPreview 回传。
struct MessageImagesView: View {
    let images: [ImageAttachmentRef]
    let store: AttachmentStore?
    /// 点击图片回传（ChatView 根层统一挂载原图预览 cover）。
    let onPreview: (ImageAttachmentRef) -> Void

    var body: some View {
        let single = images.count == 1
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(0..<images.count, id: \.self) { index in
                MessageImageCell(ref: images[index], store: store, isSingle: single)
                    .onTapGesture { onPreview(images[index]) }
                    .accessibilityLabel(images[index].name ?? "图片")
            }
        }
    }
}

/// 单图单元（MessageImage.tsx:79-120 对位）：加载 → 失败可重试；single/tile
/// 两档呈现尺寸。
struct MessageImageCell: View {
    let ref: ImageAttachmentRef
    let store: AttachmentStore?
    let isSingle: Bool

    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Button {
                    attempt += 1
                } label: {
                    Text("图片加载失败，点击重试")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
            } else {
                Text("图片加载中…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: box.width, height: box.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: attempt) { await load() }
    }

    /// 呈现盒（MessageImage.tsx:45-57 singleFit 对位）：单图长边 80、比率
    /// clamp [0.25,4]、不放大、极端比按 cover 裁切；tile = 64pt 方格。
    /// 【用户指定覆盖 dsh 240】T2.6 件7（用户 #22 后半）：dsh singleFit=240
    /// 是 dsh 原值；用户实测定长——80pt 视觉 B 档偏好覆盖，非对齐偏差。
    private var box: (width: CGFloat, height: CGFloat) {
        guard isSingle else { return (64, 64) }
        let natural = Double(max(1, ref.width)) / Double(max(1, ref.height))
        let ratio = min(4.0, max(0.25, natural))
        let w: CGFloat = ratio >= 1 ? 80 : 80 * CGFloat(ratio)
        let h: CGFloat = ratio >= 1 ? 80 / CGFloat(ratio) : 80
        let scale = min(1.0,
                        Double(ref.width) / Double(w),
                        Double(ref.height) / Double(h))
        return (max(1, (w * CGFloat(scale)).rounded()),
                max(1, (h * CGFloat(scale)).rounded()))
    }

    /// 加载（MessageImage.tsx:109-116 对位：retry 复位 + attempt 重载；失败
    /// 置位可重试）。store 缺失 = 会话未装配存储缝（fail closed 呈现失败态）。
    private func load() async {
        image = nil
        failed = false
        guard let store else {
            failed = true
            return
        }
        do {
            let stored = try store.readImage(ref)
            let decoded = UIImage(data: stored.data)
            if let decoded {
                image = decoded
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}

/// 全屏原图预览（统一 viewer——与 AI 引图链路同一承载）。
/// 【M7-Fix2 批4 L1 2026-09-29】用户复测（反馈6 遗留）：AI 引图预览一切
/// 正常、用户自己发的图片点开后 ①单击关闭失效（只有 ✕ 能关）②长按菜单
/// 不弹。根因 = 两条链路两个 viewer（调用链图见 e3-report-batch4.md）：
///   · AI 引图链（好）：WOInlineAgentImage → WOWorkspaceStore
///     .requestImagePreview → WORootFrame fullScreenCover →
///     ImageFullScreenPreview（OpenMinis ImagePreview.swift 逐行移植的
///     UIScrollView 手势仲裁缩放面：单击关/双击缩放/双指捏合/单指拉下
///     dismiss + 长按自绘菜单 复制/存相册/分享 + ✕）。
///   · 用户附件链（坏，本件旧实现）：MessageImagesView.onTapGesture →
///     WOChatView fullScreenCover → 旧 MessageLightboxView（裸 SwiftUI
///     Image scaledToFit，仅 ✕——无单击关/无长按/无缩放）。
/// 修 = 本视图退役"裸 Image"实现，退化为 **ref → 磁盘对象路径解析** 的
/// 薄适配层，直接复用链 A 的同一 viewer（零手势代码复制，两条链路行为
/// 逐帧一致）：
///   · 路径 = AttachmentStore.sha256Hex(of:) + objectPath(root:sha256:)
///     （content-addressed 对象盘位——readImage :205-210 同源算法；
///     ImageFullScreenPreview 内 UIImage(contentsOfFile:) 直读，零拷贝）。
///   · store 缺失/引用非法 → 失败兜底态（黑底点按关闭，与缩放面单击
///     语义一致）；对象文件缺失 → ImageFullScreenPreview 自带
///     "图片不可用"兜底（同链 A）。
struct MessageLightboxView: View {
    let ref: ImageAttachmentRef
    let store: AttachmentStore?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let hostPath = objectHostPath {
            ImageFullScreenPreview(hostPath: hostPath) {
                dismiss()
            }
        } else {
            // store 缺失/引用非法兜底（原 failed 态承接；点按关闭）。
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("图片不可用")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { dismiss() }
        }
    }

    /// 附件对象在盘路径（nil = store 缺失/引用非法——兜底呈现）。
    private var objectHostPath: String? {
        guard let store,
              let sha256 = AttachmentStore.sha256Hex(of: ref) else { return nil }
        return AttachmentStore.objectPath(root: store.root, sha256: sha256).path
    }
}
