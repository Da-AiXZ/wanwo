//
//  WOToastWindow.swift
//  WanWo
//
//  【批0 件2】独立 UIWindow Toast（lody LodyToastOverlay 机制引入）。
//  病灶：WOToast 原挂在视图树 ZStack/overlay 内——无法覆盖 .sheet/
//  .fullScreenCover（审批卡/添加工作区/lightbox 弹出期间 Toast 被盖）。
//  lody 语义（Toast/LodyToastOverlay.swift）：
//    · Toast 独立窗口（windowLevel .alert + 1），盖过一切 presented 面板；
//    · PassThroughWindow 命中穿透——命中落在本窗/root 视图上时返回 nil，
//      空白区域触摸穿透到下层窗口，只让 Toast 卡片区域接触摸；
//    · 空窗即隐藏（无 Toast 时窗口不拦截任何事件）。
//  视觉复用既有 WOToast / WOUndoToast SwiftUI 视图（不重画），经
//  UIHostingController 承载；【CI修49】锚定 keyboardLayoutGuide 上方
//  （屏幕中下、dock 之上）——键盘弹出自动避让（旧链视图树挂载的视觉位）。
//

import SwiftUI
import UIKit

// MARK: - 穿透窗口（lody PassThroughWindow 1:1）

@MainActor
final class WOPassThroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // 命中窗口本体或 root 视图（空白区域）→ 返回 nil 穿透到下层窗口；
        // 命中 Toast 卡片子视图 → 正常返回（卡片自身可交互）。
        if hit === self || hit === rootViewController?.view { return nil }
        return hit
    }
}

// MARK: - Toast 中心宿主（单例；调用点经 WOToastCenter.shared.show / showAction）

@MainActor
final class WOToastCenter {
    static let shared = WOToastCenter()

    private var window: WOPassThroughWindow?
    private var hostController: UIHostingController<AnyView>?
    private var hostWidthConstraint: NSLayoutConstraint?
    private var hostHeightConstraint: NSLayoutConstraint?
    /// 展示代际（同窗连发时旧 Toast 的 onDone 定时器不得提前收掉新 Toast
    /// ——present 递增，settle 校验代际后才隐藏窗口）。
    private var generation = 0

    /// 【CI修49】Toast 锚位=keyboardLayoutGuide 上方 148pt（键盘弹出自动
    /// 避让；未弹时 guide 吸附安全区底——148 ≈ dock 基准 137+12，落位在
    /// dock 上方 ≈ 屏幕中下，旧链 WOToast 挂视图树的视觉位）。
    private static let bottomClearance: CGFloat = 148

    private init() {}

    // MARK: 公共 API

    /// 瞬时横幅（视觉 = 既有 WOToast；holdMs 缺省 WOToast.holdDefault）。
    func show(text: String, icon: Image? = nil,
              holdMs: TimeInterval = WOToast.holdDefault) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let token = beginPresentation()
        present(AnyView(
            WOToast(text: trimmed, icon: icon, holdMs: holdMs, onDone: { [weak self] in
                self?.settle(token: token)
            })
            // 【P2-4 修】代际 identity：连续同文本 show 时宿主换根但 SwiftUI
            // 结构不变 → 旧视图不重挂载、onAppear 不重放，计时全灭而代际校验
            // 又拒绝旧 onDone → 窗口滞留。绑代际令牌强制重挂载，onAppear
            // 必然重放（WOToast 自身 .id(text) 同款既有手段；去抖路线需宿主
            // 侧接管视图内部计时，复杂度不值）。
            .id(token)
            .frame(maxWidth: .infinity, alignment: .center)
        ))
    }

    /// 带动作条（视觉 = 既有 WOUndoToast；hold 秒后自动退场，动作回调只发
    /// 一次——onUndo 后 WOUndoToast 自行 onDone 收口）。
    func showAction(text: String, actionTitle: String, hold: TimeInterval = 5.0,
                    action: @escaping () -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let token = beginPresentation()
        present(AnyView(
            WOUndoToast(text: trimmed, undoLabel: actionTitle, hold: hold,
                        onUndo: action, onDone: { [weak self] in
                self?.settle(token: token)
            })
            // 【P2-4 修】同 show——代际 identity 强制重挂载。
            .id(token)
            .frame(maxWidth: .infinity, alignment: .center)
        ))
    }

    // MARK: 私有装配

    /// 展示代际推进（返回本次令牌供 onDone 校验）。
    private func beginPresentation() -> Int {
        generation += 1
        return generation
    }

    /// 退场收口（WOToast/WOUndoToast 自计时 onDone 调用）：内容清空 +
    /// 窗口隐藏（空窗不拦截事件——lody hideIfEmpty 同语义）。
    private func settle(token: Int) {
        guard token == generation else { return }
        hostController?.rootView = AnyView(EmptyView())
        window?.isHidden = true
    }

    private func present(_ root: AnyView) {
        attachIfNeeded()
        guard let window, let rootVC = window.rootViewController else { return }
        if let host = hostController {
            // 复用宿主：换根即换内容（代际令牌防旧 onDone 误收）。
            host.rootView = root
            refitHost(host, width: window.frame.width)
        } else {
            let host = UIHostingController(rootView: root)
            host.view.backgroundColor = .clear
            rootVC.addChild(host)
            rootVC.view.addSubview(host.view)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            // intrinsic 尺寸：宿主视图 = Toast 卡片实际大小（不整窗铺盖，
            // 命中面最小化——lody 卡片级 hitTest 穿透的万我等价）。
            // 【CI修47】sizingOptions(.intrinsicSize) 在 CI SDK 报 no member，
            // 改 systemLayoutSizeFitting 手动量内容尺寸 + 固定宽高约束（等价）。
            NSLayoutConstraint.activate([
                host.view.centerXAnchor.constraint(
                    equalTo: rootVC.view.centerXAnchor),
                // 【CI修49】底部锚位（键盘避让）：keyboardLayoutGuide 跨窗
                // 跟随系统键盘 frame；未弹键盘时吸附安全区底（home indicator
                // 上方）——constant 抬 148 落 dock 上方。
                host.view.bottomAnchor.constraint(
                    equalTo: rootVC.view.keyboardLayoutGuide.topAnchor,
                    constant: -Self.bottomClearance),
            ])
            let widthC = host.view.widthAnchor
                .constraint(equalToConstant: 0)
            let heightC = host.view.heightAnchor
                .constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([widthC, heightC])
            hostWidthConstraint = widthC
            hostHeightConstraint = heightC
            refitHost(host, width: window.frame.width)
            host.didMove(toParent: rootVC)
            hostController = host
        }
        window.isHidden = false
        window.layoutIfNeeded()
    }

    /// 【CI修47→修49】手动量内容尺寸并更新宿主宽高约束。
    /// 修49 量测修正（真机病灶：Toast 只剩图标无文字）：
    ///   · 宽度**固定**为 min(窗宽−32, 420)（旧 hPriority .defaultHigh 下
    ///     fitting 求解可把可压缩的 Text 压没——真机胶囊只剩 16pt 图标）；
    ///   · 量高前 setNeedsLayout+layoutIfNeeded 强制 SwiftUI 完成首帧
    ///     render（rootView 刚设即量 = 量到未渲染中间态）；
    ///   · hPriority .required 定宽求解，纵向 fittingSizeLevel 取自然高。
    ///   胶囊视觉不受影响：WOToast 的 Capsule 背景挂内容 HStack（不贪婪），
    ///   固定宽容器内仍按内容自适应宽 + 居中。
    private func refitHost(_ host: UIHostingController<AnyView>, width: CGFloat) {
        let targetWidth = max(120, min(width - 32, 420))
        hostWidthConstraint?.constant = targetWidth
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let fit = host.view.systemLayoutSizeFitting(
            CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        hostHeightConstraint?.constant = ceil(fit.height)
    }

    /// 惰性挂窗（lody attachIfNeeded 同构：前景活跃场景优先，兜底首场景 /
    /// 主屏边界；root = 透明 UIViewController——穿透判定锚点）。
    private func attachIfNeeded() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first
        let win: WOPassThroughWindow
        if let scene {
            win = WOPassThroughWindow(windowScene: scene)
            win.frame = scene.coordinateSpace.bounds
        } else {
            win = WOPassThroughWindow(frame: UIScreen.main.bounds)
        }
        win.windowLevel = .alert + 1
        win.backgroundColor = .clear
        let root = UIViewController()
        root.view.backgroundColor = .clear
        win.rootViewController = root
        window = win
    }
}
