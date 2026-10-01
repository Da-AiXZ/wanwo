//
//  ModelPickerModal.swift
//  WanWo
//
//  【m7-fix2 · E2 · 按用户 HTML 原型 1:1】「获取可用模型」候选挑选弹窗。
//  原型锚点（设置模型配置原型（带动画）.html :750-896 + :1409-1556）：
//    · mask rgba(12,12,16,.45) + blur(4px)，opacity .3s；
//    · modal 白底圆角20，maxWidth 500，pad 22/22/18，入场
//      translateY(16) scale(.965) → none，opacity .3s / transform .5s；
//    · 标题「选择要添加的模型」+ 右上 icon 关闭钮；副标「以下是模型提供商
//      的可用模型，勾选要添加的模型。」；
//    · picker-toolbar = 搜索圆角999（bg #f5f5f7，focus 白底蓝环）+
//      「全选/取消全选」link；
//    · 候选行 = 勾选框 + 等宽 ID；已添加行 disabled .4 透明、不响应；
//    · 空态「没有匹配的模型」；底部取消 ghost / 添加所选 primary。
//    · 采纳面：**绝不偷偷替用户写配置**（清单12）——勾选集合由父级 onChange
//      回调消费，本弹窗零直写。
//
//  承载方式：fullScreenCover + presentationBackground(.clear)（iOS 16.4+，
//  部署目标 16.6 内）——遮罩+居中卡自绘，逃出 ScrollView 裁剪面。
//  iOS 16.6 红线自查：无 foregroundStyle、无双参 onChange、无 iOS17+ API。
//

import SwiftUI

/// 候选挑选弹窗（原型 .modal 1:1）。
struct ModelPickerModal: View {

    let candidates: [DiscoveredModel]
    /// 目录内已存在的 id（行 disabled）。
    let existingIDs: Set<String>
    /// 采纳勾选（父级消费；空集不回调）。
    let onAdd: ([DiscoveredModel]) -> Void
    let onCancel: () -> Void

    // MARK: - 状态

    @State private var shown = false
    @State private var query = ""
    /// 勾选集合（起笔 = 未添加项全选——原型 :1457-1459）。
    @State private var checked: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Body

    var body: some View {
        ZStack {
            mask
            modalCard
        }
        .onAppear {
            checked = Set(visibleAll.map(\.id).filter { !existingIDs.contains($0) })
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : WOMP.ease(WOMP.durMask)) {
                shown = true
            }
        }
    }

    // MARK: 遮罩（rgba(12,12,16,.45) + blur(4px)；点遮罩关闭）

    private var mask: some View {
        Rectangle()
            .fill(Color(red: 12.0 / 255.0, green: 12.0 / 255.0, blue: 16.0 / 255.0).opacity(0.45))
            .background(.ultraThinMaterial)
            .ignoresSafeArea()
            .opacity(shown ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            .animation(reduceMotion ? .easeOut(duration: 0.15) : WOMP.ease(WOMP.durMask),
                       value: shown)
    }

    // MARK: 居中卡（原型 .modal）

    private var modalCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            Text("以下是模型提供商的可用模型，勾选要添加的模型。")
                .font(.system(size: 13))
                .foregroundColor(WOMP.text2)
                .lineSpacing(4)
                .padding(.top, 10)
                .padding(.bottom, 16)
            toolbar
            pickerList
            actions
        }
        // 原型 .modal 内边距 pad 22/22/18（:771）——缺了内容会直贴 r20 圆角。
        .padding(.top, 22)
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .background(Color.white)
        .cornerRadius(20)
        .shadow(color: Color.black.opacity(0.4), radius: 90, y: 40)
        .shadow(color: Color.black.opacity(0.12), radius: 16, y: 4)
        .padding(.horizontal, 24)
        .frame(maxWidth: 500)
        .frame(maxHeight: 640)
        .opacity(shown ? 1 : 0)
        // opacity .3s（原型 :761）——紧贴 .opacity 生效，只管透明度。
        .animation(reduceMotion ? .easeOut(duration: 0.15) : WOMP.ease(WOMP.durMask),
                   value: shown)
        .scaleEffect(shown ? 1 : 0.965)
        .offset(y: shown ? 0 : 16)
        // 主体 transform .5s（原型双时长：opacity .3s / transform .5s）。
        .animation(reduceMotion ? .easeOut(duration: 0.15) : WOMP.ease(WOMP.durModalIn),
                   value: shown)
    }

    // MARK: 头（标题 + icon 关闭）

    private var head: some View {
        HStack(spacing: 10) {
            Text("选择要添加的模型")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(WOMP.text)
            Spacer(minLength: 8)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WOMP.text2)
                    .frame(width: 44, height: 44) // 触屏 ≥44pt（视觉原型 34px）
                    .contentShape(Rectangle())
            }
            .buttonStyle(WOProtoPressStyle())
            .accessibilityLabel("关闭")
        }
    }

    // MARK: 工具行（搜索 + 全选）

    private var toolbar: some View {
        HStack(spacing: 14) {
            searchField
            WOLinkButton(title: allOn ? "取消全选" : "全选") { toggleAll() }
        }
        .padding(.bottom, 6)
    }

    @FocusState private var searchFocused: Bool

    private var searchField: some View {
        TextField("搜索模型", text: $query,
                  prompt: Text("搜索模型").foregroundColor(WOMP.placeholder))
            .font(.system(size: 13))
            .foregroundColor(WOMP.text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($searchFocused)
            .padding(.horizontal, 16)
            .frame(minHeight: 44) // 触屏命中
            .background(Capsule().fill(searchFocused ? Color.white : WOMP.editPanelBg))
            .overlay(Capsule().strokeBorder(searchFocused ? WOMP.blue : Color.clear, lineWidth: 1))
            .overlay(Capsule().strokeBorder(searchFocused ? WOMP.blueRing : Color.clear, lineWidth: 3))
            .animation(.easeOut(duration: 0.25), value: searchFocused)
    }

    // MARK: 候选列表

    private var pickerList: some View {
        ScrollView {
            VStack(spacing: 0) {
                if visible.isEmpty {
                    Text("没有匹配的模型")
                        .font(.system(size: 13))
                        .foregroundColor(WOMP.text3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                }
                ForEach(visible, id: \.id) { candidate in
                    optionRow(candidate)
                }
            }
        }
        .frame(minHeight: 120, maxHeight: 340)
    }

    private func optionRow(_ candidate: DiscoveredModel) -> some View {
        let isExisting = existingIDs.contains(candidate.id)
        let isChecked = checked.contains(candidate.id)
        return Button {
            guard !isExisting else { return }
            if isChecked { checked.remove(candidate.id) } else { checked.insert(candidate.id) }
        } label: {
            HStack(spacing: 10) {
                WOCheckboxBox(checked: isChecked, disabled: isExisting)
                Text(candidate.id)
                    .font(.system(size: 12.8, design: .monospaced))
                    .foregroundColor(WOMP.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44) // 触屏命中
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isExisting ? Color.clear : Color.black.opacity(0.0)))
            .contentShape(Rectangle())
            .opacity(isExisting ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isExisting)
        .accessibilityLabel(candidate.id)
        .accessibilityAddTraits(isChecked ? [.isSelected] : [])
    }

    // MARK: 底部动作

    private var actions: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            WOProtoButton(title: "取消", kind: .ghost) { close() }
            WOProtoButton(title: "添加所选", kind: .primary) { confirm() }
                .opacity(pickedModels.isEmpty ? 0.4 : 1)
                .disabled(pickedModels.isEmpty)
        }
        .padding(.top, 16)
    }

    // MARK: - 数据

    private var visibleAll: [DiscoveredModel] {
        // 空查询时全量（含已存在项——行 disabled 展示）。
        candidates
    }

    private var visible: [DiscoveredModel] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return candidates }
        return candidates.filter {
            $0.id.lowercased().contains(q)
                || $0.name?.lowercased().contains(q) == true
        }
    }

    private var allOn: Bool {
        let boxes = visible.filter { !existingIDs.contains($0.id) }
        return !boxes.isEmpty && boxes.allSatisfy { checked.contains($0.id) }
    }

    private var pickedModels: [DiscoveredModel] {
        candidates.filter { checked.contains($0.id) && !existingIDs.contains($0.id) }
    }

    private func toggleAll() {
        let boxes = visible.filter { !existingIDs.contains($0.id) }
        if allOn {
            boxes.forEach { checked.remove($0.id) }
        } else {
            boxes.forEach { checked.insert($0.id) }
        }
    }

    private func confirm() {
        let picked = pickedModels
        close()
        onAdd(picked)
    }

    private func close() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : WOMP.ease(WOMP.durMask)) {
            shown = false
        }
        // 出场动画后真正卸载（原型 :1531-1535 的 320ms 时序；fullScreenCover
        // 卸载由父级 isPresented 驱动——300ms 后收）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onCancel()
        }
    }
}
