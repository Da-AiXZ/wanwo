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
/// 多图 64pt 方格；点击开全屏原图预览。
struct MessageImagesView: View {
    let images: [ImageAttachmentRef]
    let store: AttachmentStore?

    @State private var lightbox: ImageAttachmentRef?

    var body: some View {
        let single = images.count == 1
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(0..<images.count, id: \.self) { index in
                MessageImageCell(ref: images[index], store: store, isSingle: single)
                    .onTapGesture { lightbox = images[index] }
                    .accessibilityLabel(images[index].name ?? "图片")
            }
        }
        .fullScreenCover(item: $lightbox) { ref in
            MessageLightboxView(ref: ref, store: store)
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

    /// 呈现盒（MessageImage.tsx:45-57 singleFit 1:1）：单图长边 240、比率
    /// clamp [0.25,4]、不放大、极端比按 cover 裁切；tile = 64pt 方格。
    private var box: (width: CGFloat, height: CGFloat) {
        guard isSingle else { return (64, 64) }
        let natural = Double(max(1, ref.width)) / Double(max(1, ref.height))
        let ratio = min(4.0, max(0.25, natural))
        let w: CGFloat = ratio >= 1 ? 240 : 240 * CGFloat(ratio)
        let h: CGFloat = ratio >= 1 ? 240 / CGFloat(ratio) : 240
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

/// 全屏原图预览（dsh ImageLightbox 形态：标题「原图预览」+ 关闭钮）。
struct MessageLightboxView: View {
    let ref: ImageAttachmentRef
    let store: AttachmentStore?

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                } else if failed {
                    Text("图片加载失败，点击重试")
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button {
                dismiss()
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
        .navigationTitle("原图预览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await load() }
    }

    private func load() async {
        failed = false
        guard let store else {
            failed = true
            return
        }
        do {
            let stored = try store.readImage(ref)
            image = UIImage(data: stored.data)
            failed = image == nil
        } catch {
            failed = true
        }
    }
}
