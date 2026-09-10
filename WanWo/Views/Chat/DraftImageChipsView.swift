//
//  DraftImageChipsView.swift
//  WanWo
//
//  【T2.7 件1 · 用户指定形态（覆盖 dsh rail——登记为用户偏好）】
//  待发送图片的 composer 内呈现：蓝色文件名 chip（对照用户截图形态：
//  文件 icon + 文件名文字，蓝色调），多 chip 横排可换行（iOS 16 Layout
//  协议流式布局，target 16.6 可用）。
//  交互：
//    · 点 chip = 打开原图预览（复用 ChatView draftPreview fullScreenCover，
//      dsh ImageLightbox 呈现语义不变）；
//    · 左滑过阈值 = 移除（删除交互的用户指定形态为键盘删除键——SwiftUI
//      TextField 无 backspace 事件、`.onKeyPress` 为 iOS 17+（target 16.6
//      不可用）；UITextField/UITextView representable 全量替换经评估牵动
//      过大，呈报替代方案后本批先落左滑 + 长按两条确定性移除通道，详见
//      T2.7 件1 汇报）；
//    · 长按 = 上下文菜单移除（键盘收起态的移除出路；文案 = dsh
//      image.remove「移除图片」）。
//  原 64pt 缩略图 rail（dsh ComposerAttachments/AttachmentRail 形态）随本
//  件移除；T2.6 件5 的移除钮手势修复随形态一并归档（其 hit-testing 教训
//  ——clipShape 只裁渲染不裁命中——由本 chip 的 contentShape 继承）。
//

import SwiftUI

/// 待发送图片 chip 行（可换行横排）。
struct DraftImageChipsView: View {
    let images: [ChatViewModel.DraftImage]
    /// 点 chip 回传（原图预览）。
    let onPreview: (UIImage) -> Void
    /// 移除回传（左滑越阈 / 长按菜单）。
    let onRemove: (UUID) -> Void

    var body: some View {
        ChipFlowLayout(spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                DraftImageChipView(
                    title: Self.chipTitle(for: image, index: index),
                    data: image.data,
                    onPreview: onPreview,
                    onRemove: { onRemove(image.id) })
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    /// chip 标题（intake 已带名用原名；否则按序号 + 扩展名兜底——用户截图
    /// 形态为「文件名文字」，扩展名随媒体类型闭集映射）。
    static func chipTitle(for image: ChatViewModel.DraftImage, index: Int) -> String {
        if let name = image.name, !name.isEmpty { return name }
        let ext: String
        switch image.mediaType {
        case .png: ext = "png"
        case .jpeg: ext = "jpg"
        case .webp: ext = "webp"
        case .gif: ext = "gif"
        }
        return "图片 \(index + 1).\(ext)"
    }
}

/// 单枚蓝色文件名 chip：tap = 预览、左滑越阈 = 移除、长按 = 菜单移除。
private struct DraftImageChipView: View {
    let title: String
    let data: Data
    let onPreview: (UIImage) -> Void
    let onRemove: () -> Void

    /// 左滑位移（只跟随负向；松手回弹或触发移除）。
    @State private var dragX: CGFloat = 0
    /// 移除触发阈值（约两枚指节宽；左滑超过即删，未过阈值回弹归零）。
    private let removeThreshold: CGFloat = -64

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "photo")
                .font(.caption)
            Text(title)
                .font(.footnote)
                .lineLimit(1)
                // 超长文件名截断上限（chip 恒可被容器宽容纳，换行布局不溢出）。
                .frame(maxWidth: 200, alignment: .leading)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.14), in: Capsule())
        // clipShape 只裁渲染不裁命中（P1-5 / T2.6 件5 同源教训）——
        // hit 区以 contentShape 钉回胶囊本体。
        .contentShape(Capsule())
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
        .accessibilityHint("点按两下查看原图，长按可移除")
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onChanged { value in
                // 只跟随负向（左滑）；正向位移不跟随（回零形态）。
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

/// chip 流式换行布局（iOS 16 Layout 协议：逐枚理想尺寸测量、行满换行、
/// 行内顶对齐、行间距 = spacing）。
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth == .infinity ? max(0, x - spacing) : maxWidth
        return CGSize(width: width, height: max(0, y + rowHeight))
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y),
                       anchor: .topLeading,
                       proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
