//
//  WOMessageListView.swift
//  WanWo
//
//  【批 2 · 跟随精修 5 件】
//    · 件 1：逐帧指数收敛跟随——CADisplayLink（.main/.common）驱动，
//      WOMessageListSupport.advanceHeight（lody ChatScroll.advance 1:1，
//      response 0.10 + 亚像素 minimumStep）每帧向 bottomOffset 收敛；
//      贴底唯一执行点 = display link tick（viewDidLayoutSubviews 不再直接
//      写 offset，只做锚定恢复与 link 唤醒）；自停/重启条件 lody 同型。
//    · 件 2：拖拽断开完整状态机（lody pauseTracking/resumeTrackingAtBottom
//      语义：willBeginDragging 即断；didEndDragging(!decelerate)/
//      didEndDecelerating 回底距 ≤1pt 恢复）+ 回底按钮（右下悬浮，距底
//      >resumeDistance(80) 且非跟随态现形；UIKit 内层按钮=lody overlay
//      同构，免 Binding 往返——简报 SwiftUI overlay 形态建议的等价替代，
//      回报登记）。
//    · 件 3：contentInset 让位——composer 座位组超出旧链基准（137）的
//      增量 → contentInset.bottom（lody updateBottomInset 语义：让位与
//      滚动位置解耦、变更才写）；静态 sectionInset bottom 189 保留
//      （批 1 QA 判值=旧链 spacer 语义）；键盘维持 SwiftUI 避让（视口
//      缩短天然解耦，不双补——回报登记分立关系）。
//    · 件 4：离屏流式冻结——live 行滚出视口 ±80/160 迟滞带（未冻/已冻）
//      → sync 跳过该行 reconfigure（syncedNodes 基线冻结在旧值、版本不
//      bump=行高冻结），回带一次性追平到最新；只冻显示不冻推进
//     （typeCursor/finishSettling 语义零耦合）。
//    · 件 5：打字机节奏 WOTextReveal（CKTextReveal 万我形态，VM 侧）。
//  生命周期铁律：display link invalidate 路径齐全（自停/deinit/shutdown
//  [representable dismantle]/会话切换 bindIfNeeded）。
//
//  【批 1 · 件 1/2/3/5】UIKit 消息列表骨架——UIViewControllerRepresentable 承载：
//    · 件 1：UICollectionView + DiffableDataSource（单 section；item identity
//      = 既有代际化节点 id）；updateUIView 驱动 sync（displayNodes → 窗口切片
//      → flatten → 全量比对 → reconfigureItems 变更行 → apply(非动画)）。
//      33Hz live 更新 = 同 id 内容变 → reconfigure + 重测该行（其余行零触碰）；
//      无变化帧（WOMListNode 全等）零 apply——33Hz no-op 守卫。
//    · 件 2：行高三级缓存（WOHostSizingPool：宽度绑定高度缓存 / 池内视图 /
//      重测）+ 自定义 layout 精确 frame 直给。
//    · 件 3：历史分页窗口（VM historyWindowStart 尾部 50 节点）+ 4ms 时间预算
//      切片量高 + 顶部预取（offset < 240）+ 锚定恢复。
//    · 件 5：apply 耗时/规模探针（WOChatProbe 环形缓冲 + >8ms os_log）。
//  手势：tap（cancelsTouchesInView=false + 同时识别）→ onBackgroundTap。
//  键盘：SwiftUI 避让缩 representable（批 1 语义保留；composer 动态增量走
//  contentInset，见件 3）。
//

import SwiftUI
import UIKit
import os

// MARK: - Representable（WOChatView 宿主面）

struct WOMessageListView: UIViewControllerRepresentable {
    /// 列表数据宿主（窗口状态读写缝）。
    let viewModel: ChatViewModel
    /// 单一渲染数据源（WOChatView body 求值 displayNodes 传入——33Hz live
    /// 变化驱动 SwiftUI 重求值 → updateUIView → core.sync）。
    let nodes: [ConversationProjector.DisplayNode]
    let phase: ChatViewModel.Phase
    let sessionId: String
    /// 【rail hint R1 第四跳】列宽目标提示（cols.center 原值；0=未提供/直注
    /// 宿主）——updateUIViewController 经 applyUpdate 透传 core（每来源一次
    /// 下发，非逐帧；core 侧 processWidthHint 六步消费）。
    /// 声明序注意：memberwise init 参数序=声明序，本属性须在 bottomAllowance
    /// 之前（WOChatView 调用点 widthHint 紧随 sessionId）。
    var widthHint: CGFloat = 0
    /// 批 2 件 3：composer 座位组超出旧链基准的动态让位增量
    ///（max(0, composerChromeHeight - 137)；变更才写 contentInset.bottom）。
    var bottomAllowance: CGFloat
    /// 点消息区（cell 外）回调——区外关闭 slash/@ 菜单。
    var onBackgroundTap: () -> Void
    /// 顶栏丝线判定回调（scrollTop > 4）。
    var onHeadScrolled: (Bool) -> Void
    /// 消息气泡图片原图预览（原 messagePreview @State binding 的闭包形）。
    var onImagePreview: (ImageAttachmentRef) -> Void

    final class Coordinator {
        let core = WOMessageListCore()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> WOMessageListCore {
        context.coordinator.core
    }

    func updateUIViewController(_ core: WOMessageListCore, context: Context) {
        core.applyUpdate(viewModel: viewModel, nodes: nodes, phase: phase,
                         sessionId: sessionId,
                         bottomAllowance: bottomAllowance,
                         onBackgroundTap: onBackgroundTap,
                         onHeadScrolled: onHeadScrolled,
                         onImagePreview: onImagePreview,
                         widthHint: widthHint)
    }

    /// 批 1 P2-4 清偿：视图拆解（会话页离场）→ 切片链作废 + display link
    /// invalidate（生命周期铁律第四条路径）。
    static func dismantleUIViewController(_ uiViewController: WOMessageListCore,
                                          coordinator: Coordinator) {
        uiViewController.shutdown()
    }
}

// MARK: - 精确 frame layout（件 2；高度问池，池未命中才量）

protocol WOMessageListLayoutDelegate: AnyObject {
    func listLayout(_ layout: WOMessageListLayout,
                    heightForItemAt indexPath: IndexPath,
                    width: CGFloat) -> CGFloat
}

final class WOMessageListLayout: UICollectionViewLayout {
    weak var delegate: WOMessageListLayoutDelegate?

    /// 【重做批5 · 排版宽度解耦 2026-10-07】prepare 一律按此宽度排版，**不读
    /// collectionView.bounds.width**——侧栏开合动画期间 UIKit 对容器 resize
    /// 强制 invalidate 布局（视频实测：动画中间帧内容已 reflow，且此期间
    /// shouldInvalidateLayout 的返回值被绕过）——prepare 爱被调多少次，输出
    /// 恒定=cell 纹丝不动（超出部分被容器裁剪，"窗框动、画不动"）。宽度稳定
    /// 后由 core 一次切换（layoutWidth=新宽+回传真值落池+invalidate+锚定）。
    var layoutWidth: CGFloat = 0
    /// 排版宽度与容器实际宽不一致（动画中）→ 通知 core 进流体重排/去抖切换。
    var onLiveWidthChange: ((CGFloat) -> Void)?

    /// digest-H .msgs gap 16。
    var lineSpacing: CGFloat = 16
    /// 【批1-QA P2-1 修】逐值折算（QA 复核裁定 75/189，原 58/172 各漏探针
    /// 附属元素的相邻间距）：
    ///   顶部 75 = padding 58 + 顶部探针 1pt + 探针→首条 gap 16；
    ///   底部 189 = 末条→148 让位 spacer gap 16 + spacer 148 + spacer→尾部
    ///   探针 gap 16 + 探针 1pt + 收尾 padding 8。
    /// 与旧 LazyVStack 链首/末条到内容边界的几何逐值一致（视觉零变化）。
    var sectionInset = UIEdgeInsets(top: 75, left: 16, bottom: 189, right: 16)

    private var itemFrames: [CGRect] = []
    private var contentHeight: CGFloat = 0

    // MARK: 【rail T02】确定性混合接口（架构文档 §3.7）
    //
    // rail 期布局 = 两端已知布局的 O(n) 线性插值：from=旧宽 itemFrames 快照、
    // to=目标宽池身高累加帧。prepare 早退 → 零 delegate 询问/零量高/
    // 零 onLiveWidthChange；layoutAttributesForElements 直读已混合帧（零改动）。

    /// rail 混合在途（prepare 早退门；core 经 beginRail/updateRailProgress/
    /// endRail 驱动）。
    private(set) var isRailActive = false
    /// 旧端帧（rail 启动时 itemFrames 快照；restart 时=当前混合帧快照）。
    private var railFromFrames: [CGRect] = []
    /// 新端帧（预计算完成时按目标宽 O(n) 累加）。
    private var railToFrames: [CGRect] = []
    /// 旧端内容高（beginRail 时刻 contentHeight 快照；restart 时=当前混合值）。
    private var railFromContentHeight: CGFloat = 0
    /// 新端内容高（toFrames 累加推导：末行 maxY + bottom inset）。
    private var railToContentHeight: CGFloat = 0

    /// rail 期混合内容高（core offset 算术消费；非 rail 期=普通 contentHeight）。
    var currentContentHeight: CGFloat { contentHeight }

    /// 启动 rail：存两端帧快照、itemFrames 置旧端（p=0 状态）。两端内容高
    /// 由本函数自足推导（from=当前 contentHeight；to=toFrames 末行 maxY +
    /// bottom inset——toFrames 由 core 以同一 sectionInset/lineSpacing 累加，
    /// 几何口径一致）。restart 场景 from=当前混合帧/混合高，插值从中途续跑。
    func beginRail(fromFrames: [CGRect], toFrames: [CGRect]) {
        railFromFrames = fromFrames
        railToFrames = toFrames
        railFromContentHeight = contentHeight
        railToContentHeight = toFrames.last.map { $0.maxY + sectionInset.bottom }
            ?? (sectionInset.top + sectionInset.bottom)
        itemFrames = fromFrames
        contentHeight = railFromContentHeight
        isRailActive = true
    }

    /// 逐帧混合：O(n) 逐行 blendFrame 写 itemFrames + blendHeight 写
    /// contentHeight。缺失行语义（R9-7）：缺 from 端=to 直用（流式插入的
    /// 新行）；缺 to 端=from 直用（防御，行被删）。
    func updateRailProgress(_ p: CGFloat) {
        guard isRailActive else { return }
        let count = max(railFromFrames.count, railToFrames.count)
        itemFrames.removeAll(keepingCapacity: true)
        itemFrames.reserveCapacity(count)
        for i in 0..<count {
            let hasFrom = i < railFromFrames.count
            let hasTo = i < railToFrames.count
            switch (hasFrom, hasTo) {
            case (true, true):
                itemFrames.append(WOMessageListSupport.blendFrame(
                    railFromFrames[i], railToFrames[i], Double(p)))
            case (false, true):
                itemFrames.append(railToFrames[i])
            case (true, false):
                itemFrames.append(railFromFrames[i])
            default:
                break
            }
        }
        contentHeight = WOMessageListSupport.blendHeight(
            railFromContentHeight, railToContentHeight, Double(p))
    }

    /// rail 结束：itemFrames 定格新端帧（一次切真布局——prepare 随后按新
    /// layoutWidth 正常运行，两端帧一致零跳变）。
    func endRail() {
        itemFrames = railToFrames
        contentHeight = railToContentHeight
        railFromFrames = []
        railToFrames = []
        isRailActive = false
    }

    /// rail 中途作废（restart 链取消分支 R9-8 专用）：解除冻结、**保持当前
    /// 混合帧原样**（随后 prepare 按 layoutWidth 重建——调用方保证 layoutWidth
    /// 已是期望值）。与 endRail 的差异：不切 toFrames（restart 链取消时
    /// to 端属于被放弃的目标）。
    func abortRail() {
        isRailActive = false
        railFromFrames = []
        railToFrames = []
    }

    override func prepare() {
        super.prepare()
        // 【rail T02】rail 期早退：零 delegate 询问、零量高、零 onLiveWidth
        // Change——混合帧原样供 layoutAttributesForElements 消费（确定性优先，
        // 架构文档 §3.7/R4）。
        if isRailActive { return }
        guard let collectionView, collectionView.numberOfSections > 0 else {
            itemFrames = []
            contentHeight = sectionInset.top + sectionInset.bottom
            return
        }
        // 【重做批5 · 解耦】容器实际宽 ≠ 排版宽（含冷启动 layoutWidth=0 态——
        // 【QA 确认轮 P0-1 修】去掉 layoutWidth > 0 门：0 态必须放行上报，
        // 否则收养分支不可达=冷启动永久空白）→ 通知 core（core 去抖后一次
        // 切换；0 态走收养采认）。本 prepare 仍按当前 layoutWidth 输出。
        if abs(collectionView.bounds.width - layoutWidth) > 0.5 {
            onLiveWidthChange?(collectionView.bounds.width)
        }
        let width = layoutWidth - sectionInset.left - sectionInset.right
        guard width > 1 else {
            itemFrames = []
            contentHeight = sectionInset.top + sectionInset.bottom
            return
        }
        let count = collectionView.numberOfItems(inSection: 0)
        itemFrames.removeAll(keepingCapacity: true)
        itemFrames.reserveCapacity(count)
        var y = sectionInset.top
        for item in 0..<count {
            let height = delegate?.listLayout(
                self, heightForItemAt: IndexPath(item: item, section: 0),
                width: width) ?? 44
            itemFrames.append(CGRect(x: sectionInset.left, y: y,
                                     width: width, height: height))
            y += height + lineSpacing
        }
        contentHeight = (count > 0 ? y - lineSpacing : sectionInset.top)
            + sectionInset.bottom
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        // itemFrames 依 y 有序；窗口 50 条量级线性扫描成本可忽略（批 2 需要
        // 时升二分）。只在 rect 内产出——回收语义由 UIScrollView 惯例承接。
        var attributes: [UICollectionViewLayoutAttributes] = []
        for (index, frame) in itemFrames.enumerated()
        where frame.maxY >= rect.minY && frame.minY <= rect.maxY {
            let attrs = UICollectionViewLayoutAttributes(
                forCellWith: IndexPath(item: index, section: 0))
            attrs.frame = frame
            attributes.append(attrs)
        }
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < itemFrames.count else { return nil }
        let attrs = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attrs.frame = itemFrames[indexPath.item]
        return attrs
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        // 【重做批5 · 宽度冻结 2026-10-07】恒 false：bounds 逐帧变化（右栏
        // 开合/旋转/分栏的中间态）不触发布局重算——cell frame 绝对定位保持
        // 旧宽形态（内容静止不 reflow 不跳变，仅可视区域变化）；宽度稳定后
        // 由 drainStaleSweep 稳定分支一次 invalidate 重摆+切片重测渐进修正。
        // 旧实现"宽度变→true"=prepare 每帧跑→池按宽度取值 miss→同步量高
        // （离屏环境与显示环境状态分叉）+fallback 跳变+stale 切片+回传桥
        // 多路写入——真机"宽度变化内容上下抽搐/叠影"根因（list-diag 帧 3
        // 实锤：全体行跳大 621pt 次帧回落）。滚动 origin 变化本就 false。
        return false
    }

    /// 【批4 真机诊断】itemFrames 只读快照（dumpLayoutSnapshot 消费——
    /// 空白洞/偏移定位：frame 与池高、视口范围三者对账）。
    func snapshotFrames() -> [CGRect] { itemFrames }
}

// MARK: - Core（列表生命周期与同步全量逻辑）

@MainActor
final class WOMessageListCore: UIViewController, UICollectionViewDelegate {

    private enum Section: Hashable { case main }

    // MARK: 输入（applyUpdate 更新）

    private var viewModel: ChatViewModel?
    private var nodes: [ConversationProjector.DisplayNode] = []
    private var phase: ChatViewModel.Phase = .loading
    private var sessionId = ""
    private var onBackgroundTap: (() -> Void)?
    private var onHeadScrolled: ((Bool) -> Void)?
    private var onImagePreview: ((ImageAttachmentRef) -> Void)?

    // MARK: 件 2 池 / 件 1 账本（会话切换 reset）

    private let pool = WOHostSizingPool()
    private let ledger = WOEntryLedger()
    private var context = WONodeContext(
        sessionId: "", attachmentStore: nil,
        onImagePreview: { _ in },
        phase: .loading, justEndedStreaming: false, settledBubbleIDs: [],
        ledger: WOEntryLedger(), freshlyInsertedIDs: [])

    // MARK: 件 1 同步簿记

    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!
    private var messageLayout: WOMessageListLayout!
    private var collectionView: UICollectionView!
    /// 最近一次 sync 的条目（Equatable 比对 + 锚定索引）。
    private var currentItems: [WOMListNode] = []
    /// id → 最近入库条目（变更检测；33Hz no-op 守卫的比对基线）。
    private var syncedNodes: [String: WOMListNode] = [:]
    /// 【批4 诊断实证修】首次定位直写位（bindIfNeeded 置位；首个非空 apply
    /// 完成时直写贴底——旧链 display link 收敛在"行高陆续修正"期被持续
    /// 推远，真机 apply+3s 实证 offset 差 1425pt 未到位（打开后内容上掠
    /// 数秒/停在半路）。lody 首次定位同为直写语义；流式跟随仍走 display
    /// link 不受影响）。
    private var needInitialPositioning = false
    /// 【重做批4·四修】打开会话初始稳定期（首次贴底直写起 2s）：期间行高
    /// 修正（Markdown 解析/富格式切换）免动画直写——逐行动画叠加收敛链 =
    /// 真机"加载完后整个对话从头滚一遍到底部"的观感根源；直写=打开即稳。
    /// 【2026-10-09】切换结算窗（rail 落地，R7）亦复用此窗（1s，后写
    /// 者赢）——切换后首批回报/stale 切片重测走直写，防"收尾反复抽动"。
    private var initialStabilizingUntil: CFTimeInterval = 0
    /// 【打开定位 修复3-e】稳定期结束兜底校准挂位（tryInitialPositioning
    /// 置位；settleSnapIfDue 到期一次性消费——任何交错把贴底弄丢时强制
    /// 归位，用户已拖拽则不动作）。
    private var stabilizingSnapPending = false
    /// id → 内容版本（内容变 → bump → 池高度签名失效 → 重测）。
    private var contentVersions: [String: Int] = [:]
    private var lastPhase: ChatViewModel.Phase?
    /// 【CI修50】apply 重入防护簿记（真机 12:24 闪退根治——.ips 栈：apply
    /// 的更新块内 UIKit 触发 _notifyDidScroll → scrollViewDidScroll →
    /// maybeExpandHistory/sync → 再 apply，diffing 队列 barrier_sync 断言
    /// abort）。在途期 sync 只记待办，completion 后链式补发（diffable 官方
    /// 合法续发点）。
    private var applyInFlight = false
    private var syncPending = false
    /// 【QA P1-1 修】挂起期累积的解冻透传集：scrollViewDidScroll 回带链的
    /// sync(forceUnfreeze:) 若被在途 apply 挂起，drain 补发无参 sync 会让
    /// 内部评估以"未冻 80 带"把刚解冻行（d∈80~160）秒回冻——D2 迟滞带
    /// 修复打穿（基线永不追平+逐帧 churn）。挂起时并集累积，drain 透传。
    private var syncPendingUnfreeze: Set<String> = []
    /// 【CI修50】扩窗锚定的延迟入位：finishHistoryExpansion 的 sync 若被
    /// 在途 apply 挂起，锚定不能直写 pendingAnchorRestore（会被下一次
    /// layout pass 对**旧帧**提前消费 = 扩窗跳位）——先寄存，apply 落地
    /// （completion）后转移。
    private var deferredExpansionAnchor: AnchorRestore?
    /// 【CI修50】列宽动画期推迟重测切片（右栏开合丝滑化）：宽度仍在变的
    /// layout pass 不 drain（prepare 照常收集 stale），宽度稳定后的第一个
    /// pass 一次清账——重测工作量挪出动画帧。
    /// 【重做批5 · 宽度解耦状态机】当前排版宽（layout.layoutWidth 同步；只在
    /// rail 落地时更新）。
    private var stableLayoutWidth: CGFloat = 0

    // MARK: 【rail R1 第五跳】hint 簿记（架构文档 §3.6）
    /// 最新 hint（cols.center 原值；applyUpdate 每次刷新）。
    private var widthHint: CGFloat = 0
    /// 已消费（precompute/rail 启动依据）的 hint 值——幂等去重 +
    /// "hint==stable 无动作"门（body 重复求值不重复起跑）。
    private var activeHintWidth: CGFloat = 0

    // MARK: 【rail R2】目标宽预计算（4ms/8ms 切片）
    /// 预计算切片状态（rail 启动前置——两端布局的"新端"来源）。
    private struct RailPrecompute {
        /// hint（目标视口宽）。
        let targetViewportWidth: CGFloat
        /// hint − sectionInset.left − right（池键宽口径，与 contentWidth() 同源）。
        let targetContentWidth: CGFloat
        /// railPrecomputeGen 快照（重启/切换作废）。
        let generation: Int
        /// snapshot 内已量行游标。
        var cursor: Int
        /// 启动时刻 currentItems 快照（身份固定；新增行走 startRail 同步补量）。
        let snapshot: [WOMListNode]
        let startedAt: CFTimeInterval
    }
    private var railPrecompute: RailPrecompute?
    private var railPrecomputeGen = 0

    // MARK: 【rail R3-R7】确定性宽度动画状态机
    private struct WidthRail {
        /// 落地写 stableLayoutWidth/layoutWidth。
        let targetViewportWidth: CGFloat
        let startTime: CFTimeInterval
        /// WOMotion.sidebarRailDuration（曲线/时长单源，零硬编码副本）。
        let duration: CFTimeInterval
        let followsBottomAtStart: Bool
        /// !followsBottom 时启动捕获（captureTopAnchor 语义，跳 meta 行）；
        /// 锚行被移除时 offset 降级内容高差兜底（R9-7，fromContentHeight 消费）。
        let anchor: (id: String, viewportY: CGFloat)?
        /// rail 起点内容高（beginRail 前快照）——锚行缺失兜底算术用（R9-7：
        /// off += blendH − fromH）。文档 §3.6 字段外的补充承载，报告登记。
        let fromContentHeight: CGFloat
    }
    private var widthRail: WidthRail?
    /// rail 期锚定 offset 直写防刷屏基线（RAIL-TICK off 变 >0.5pt 才记）。
    private var railDiagLastOff: CGFloat = -1
    /// 结算窗 commit 计数（RAIL-END settleCount；finishWidthRail 置窗、
    /// 1s 后补记并熄灯；代际令牌防 restart 链串窗）。
    private var railSettleCounting = false
    private var railSettleCommitCount = 0
    private var railSettleGeneration = 0

    // MARK: 【rail T05 P1】空闲预热（四契约宽度批量池预热）
    private var prewarmWorkItem: DispatchWorkItem?
    private var prewarmGen = 0

    // MARK: 件 2/批 2 簿记

    private var historyLoading = false
    private var expanding = false
    /// 扩窗代际令牌（会话切换/视图拆解使在途切片作废）。
    private var expansionGeneration = 0
    /// 【重做批3 · R1】扩窗完成落在滚动中 → 静止后补提交（finishHistoryExpansion
    /// 置位；didEnd 系列消费）。
    private var scrollEndExpansionPending = false

    // MARK: 【重做批6】同出生长插值（新行入场几何侧——参考件《同出丝滑效果》）

    /// 生长动画种类（2026-10-09 披露/入场分家）：
    /// - .entrance：新行入场同出生长——coGrowEase 0.66s（既有验收行为原样）。
    /// - .disclosure：思考/工具行展开收起——disclosureEase(0.4,0,0.2,1) 0.32s
    ///   （参考件曲线，与 Motion.swift 全库唯一曲线同款），且动画期间**不做
    ///   贴底重钉**（表头钉死语义，用户拍板 2026-10-09：底部展开时下方内容
    ///   被推出屏不拉回）。
    private enum GrowthKind {
        case entrance
        case disclosure
    }

    /// 单行生长动画参数（from→to 高度插值；start=驱动 tick 时刻基准）。
    private struct GrowthAnim {
        let from: CGFloat
        let to: CGFloat
        let start: CFTimeInterval
        let duration: TimeInterval
        var kind: GrowthKind = .entrance
    }
    /// 行 id → 生长动画（池=数据真值瞬时入库；layout 查询经 growthDisplay
    /// 高度覆盖——显示层从 0 长到真值，物理顶开旧行+内容淡入=同出）。
    private var growthAnims: [String: GrowthAnim] = [:]
    /// 参考件时长：新行 0→真值 0.66s，与 SwiftUI 侧纯淡入（WOEntryModifier
    /// duration 0.66）同步——同一参考件参数。
    private static let growthDuration: TimeInterval = 0.66

    /// 新插入 non-user 行入队生长（applyUpdate 检测后调；seen/instantLive 行
    /// 跳过=历史静默/刚看过语义不生长）。to=同步量高入池取真值（插入帧格子
    /// 高 0，首帧 prepare 命中池值被插值覆盖）。
    private func enqueueGrowthIfEligible(_ item: WOMListNode) {
        guard case .bubble(let bubble) = item.kind else { return }
        if case .user = bubble.kind { return } // user 行=mInR 横移（无生长）
        let id = item.id
        // 后台/未挂窗不入队（display link 无法驱动=行停在 0 高不可见）——
        // 直接以池值呈现（后台无动画语义正确）。
        guard collectionView?.window != nil,
              growthAnims[id] == nil,
              !ledger.seenIDs.contains(id),
              !(viewModel?.settledBubbleIDs ?? []).contains(id) else { return }
        // instantLive（流式中落盘的 assistant/reasoning=刚在直播看过）不生长。
        let kindTag: String = {
            switch bubble.kind {
            case .assistant: return "assistant"
            case .reasoning: return "reasoning"
            default: return "other"
            }
        }()
        if id.hasPrefix("live-") == false,
           (phase == .streaming || (viewModel?.justEndedStreaming ?? false)),
           kindTag == "assistant" || kindTag == "reasoning" { return }
        let width = contentWidth()
        let target = pool.height(id: id, width: width,
                                 signature: "v\(contentVersions[id] ?? 0)",
                                 makeContent: { [weak self] in
                                     guard let self else { return AnyView(Color.clear) }
                                     return self.makeNodeContent(item, reportsHeight: false)
                                 })
        growthAnims[id] = GrowthAnim(from: 0, to: target,
                                     start: CACurrentMediaTime(),
                                     duration: Self.growthDuration)
    }

    /// 生长插值当前显示高度（layout 查询覆盖；nil=无动画/已完成→用池值）。
    /// 曲线按种类分派：.disclosure=disclosureEase（参考件 0.4,0,0.2,1）；
    /// .entrance=coGrowEase（既有同出曲线，不动）。
    fileprivate func growthDisplayHeight(id: String) -> CGFloat? {
        guard let anim = growthAnims[id] else { return nil }
        let elapsed = CACurrentMediaTime() - anim.start
        guard elapsed < anim.duration else { return nil }
        let x = Double(max(0, elapsed / anim.duration))
        let eased: Double
        switch anim.kind {
        case .disclosure:
            eased = WOMessageListSupport.disclosureEase(x)
        case .entrance:
            eased = WOMessageListSupport.coGrowEase(x)
        }
        return anim.from + (anim.to - anim.from) * CGFloat(eased)
    }

    // MARK: 批 2 件 1 display link（贴底唯一执行点）

    private var motionLink: CADisplayLink?
    private var motionTime: CFTimeInterval = 0

    // MARK: 批 2 件 3 让位簿记

    /// 已生效的 contentInset.bottom（lody :23 同款 guard：变更才写）。
    private var appliedBottomInset: CGFloat = -1

    // MARK: 批 2 件 4 离屏冻结簿记

    /// 冻结中的 live 行 id（回带/落盘后清理；内容基线=syncedNodes 冻结前值）。
    private var frozenLiveIDs: Set<String> = []

    // MARK: 批 2 件 2 回底按钮

    private var backToBottomButton: UIButton!
    private var backToBottomContainer: UIView?
    /// 【批2-QA D1 修】显式状态位（替代 isHidden/alpha 反推）——hide 判定
    /// 独立于动画态，杜绝"已显示态收到 hide 被提前 return 卡死屏上"。
    private var backToBottomShown = false

    // MARK: 跟随/滚动簿记

    /// 跟随断开状态机（批 2 件 2 升级为 lody 完整语义）：willBeginDragging
    /// 即断（手指一碰绝不 yank）；松手/惯性停时距底 ≤1pt 恢复。
    private var followsBottom = true
    /// 锚定恢复（扩窗完成后首个 layout pass 消费一次）。
    private struct AnchorRestore {
        let anchor: (id: String, viewportY: CGFloat)?
        let oldContentHeight: CGFloat
    }
    private var pendingAnchorRestore: AnchorRestore?

    // MARK: 探针簿记（纯记录辅助状态；不参与任何逻辑分支/判定）
    /// H 系列回报路由防刷屏（"tag|id" → 上次记录高度；差 <1pt 跳过记录）。
    private var fluidDiagLastH: [String: CGFloat] = [:]

    // MARK: 生命周期

    override func loadView() {
        let layout = WOMessageListLayout()
        messageLayout = layout
        // 【rail T04 #15】fallback 接线改挂 handleContainerWidthFallback：
        // hint 管道是唯一宽度权威——本路径只保留冷启动收养 + LIVE-CHANGE
        // 探针，其余一律早退（旧流体重排链退役）。
        layout.onLiveWidthChange = { [weak self] width in
            self?.handleContainerWidthFallback(width)
        }
        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.alwaysBounceVertical = true
        // SwiftUI 已把 representable 布进安全区内—— UIKit 侧不再自动补 inset
        //（双补会让顶部 padding 变 75+safeArea）。
        cv.contentInsetAdjustmentBehavior = .never
        cv.allowsSelection = false
        cv.showsVerticalScrollIndicator = true
        cv.keyboardDismissMode = .none
        view = cv
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let cv = view as! UICollectionView
        collectionView = cv
        messageLayout.delegate = self
        // 【批1-QA P0-1 修】cell 注册（漏带 = 首帧 dequeue 即
        // NSInternalInconsistencyException 崩溃）。
        cv.register(WONodeCell.self, forCellWithReuseIdentifier: "WONodeCell")
        // 【批1-QA P1-1 修】UIScrollViewDelegate 接线（漏带 = scrollViewDid
        // Scroll 永不回调 → 丝线死/followsBottom 恒 true/「载入更早」不可用）。
        cv.delegate = self
        installBackToBottomButton(on: cv)
        dataSource = UICollectionViewDiffableDataSource<Section, String>(
            collectionView: cv) { [weak self] collectionView, indexPath, itemID in
                self?.cellProvider(collectionView, indexPath, itemID)
                    ?? UICollectionViewCell()
        }
        // 区外点按关闭 slash/@ 菜单（cancelsTouchesInView=false：SwiftUI 内
        // 部按钮/contextMenu 触控不受影响；同时识别防吞）。
        let tap = UITapGestureRecognizer(target: self,
                                         action: #selector(handleBackgroundTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        cv.addGestureRecognizer(tap)
        // 【批4 真机修复】Markdown 解析完成订阅（行高自愈）：量高 host 与
        // 未显示行的池高度停留 Text 近似值——解析完成广播后此处 remeasure
        //（缓存已命中 → 同步真文档 → 真值）+ 提交修正，contentSize 不再
        // 依赖"行滚进视口→显示 cell 回传"才收敛。
        markdownParsedObserver = NotificationCenter.default.addObserver(
            forName: WOMarkdownDocumentCache.documentParsedNotification,
            object: nil, queue: .main) { [weak self] note in
                let text = note.userInfo?["text"] as? String
                MainActor.assumeIsolated {
                    self?.handleMarkdownParsed(text)
                }
            }
    }

    /// 【批4 真机诊断】保底触发（completion+3s 之外的兜底——列表首次出现在
    /// 屏幕后 3s 必有一次快照；用户复现"打开即空白"的最稳取证点）。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.dumpLayoutSnapshot(reason: "appear+3s")
        }
    }

    /// 【批4 真机修复】解析完成 → 匹配行重测自愈（照 runRemeasureSlice 的
    /// 提交模式：remeasure 已直写 cache，previous 比对后 commitHeightChange
    /// 绕过 updateHeight 死区门）。文本匹配口径与渲染一致（autolink 后的
    /// 段文本）；同文本多行全量 remeasure（幂等）；频率=解析完成一次一行，
    /// 线性扫描 50 条成本可忽略。
    private func handleMarkdownParsed(_ text: String?) {
        guard let text, !text.isEmpty,
              let cv = collectionView, cv.window != nil else { return }
        // 【rail】rail/预计算在途 → 挂起自愈（池真值已按目标宽落位，rail 后
        // 结算窗/stale 链自然收敛；rail 期提交会与 railTick offset 直写打架）。
        guard widthRail == nil, railPrecompute == nil else { return }
        let width = contentWidth()
        for item in currentItems {
            guard case .bubble(let bubble) = item.kind,
                  case .assistant(let body) = bubble.kind else { continue }
            let matches = WONodeBubbleView.splitAgentSegments(body).contains { segment in
                !segment.text.isEmpty
                    && WONodeBubbleView.autolinkBareURLs(segment.text) == text
            }
            guard matches else { continue }
            let previous = pool.cachedHeight(id: item.id, width: width)
            let height = pool.remeasure(
                id: item.id, width: width,
                signature: "v\(contentVersions[item.id] ?? 0)",
                makeContent: { [weak self] in
                    guard let self else { return AnyView(Color.clear) }
                    return self.makeNodeContent(item, reportsHeight: false)
                })
            if previous != height {
                commitHeightChange(id: item.id, height: height, collectionView: cv)
            }
        }
    }

    // MARK: 【批4 真机诊断】布局快照落文件（空白洞/偏移定位取证）

    /// 布局快照 dump（限频 1.5s）：视口 ±1200pt 内每行的 frame / 池高 /
    /// 内容版本三元对账 + 全局 offset/contentSize/inset。文件
    /// Documents/list-diag.log（文件 App 可见可分享，WOEntryDiag 同款形态
    /// +256KB 截半守护）。判定口径：
    ///   · 空白区「无行 frame」（相邻 frame.minY 间隔 > 行高）→ 布局 y 累加洞
    ///   · 「frame 高 ≫ pool 高」→ layout 未按池刷新（invalidate 链断）
    ///   · 「pool 高大 + 渲染空」→ cell 内容渲染问题（非布局）
    ///   · 「pool 高 ≈ 0」→ 量高低值固化（Markdown/图片异步链）
    private var lastDiagDump = TimeInterval(0)

    func dumpLayoutSnapshot(reason: String) {
        guard let cv = collectionView, !currentItems.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastDiagDump >= 1.5 else { return }
        lastDiagDump = now
        var lines: [String] = []
        lines.append("===== \(reason) phase=\(String(describing: phase)) =====")
        lines.append(String(format: "offset=%.0f contentH=%.0f viewport=%.0f adjT=%.0f adjB=%.0f follows=%d items=%d width=%.0f layoutW=%.0f stableW=%.0f rail=%d",
                            cv.contentOffset.y, cv.contentSize.height, cv.bounds.height,
                            cv.adjustedContentInset.top, cv.adjustedContentInset.bottom,
                            followsBottom ? 1 : 0, currentItems.count,
                            cv.bounds.width - messageLayout.sectionInset.left
                                - messageLayout.sectionInset.right,
                            messageLayout.layoutWidth, stableLayoutWidth,
                            widthRail != nil ? 1 : 0))
        let frames = messageLayout.snapshotFrames()
        let top = cv.contentOffset.y - 1200
        let bottom = cv.contentOffset.y + cv.bounds.height + 1200
        let width = contentWidth()
        for (index, frame) in frames.enumerated()
        where frame.maxY >= top && frame.minY <= bottom {
            guard index < currentItems.count else { break }
            let item = currentItems[index]
            let poolH = pool.cachedHeight(id: item.id, width: width) ?? -1
            lines.append(String(format: "  #%-3d %@ %@ y=%.0f h=%.0f pool=%.0f v%d",
                                index, item.id, Self.describeKind(item.kind),
                                frame.minY, frame.height, poolH,
                                contentVersions[item.id] ?? 0))
        }
        // 【批4 真机诊断·渲染层】可见 cell 的"实际内容绘制高度"对拍——
        // hostViewFrame=SwiftUI 视图在 cell 内的实际框；hostIntrinsicHeight=
        // 内容理想高。三者关系：账本 h≈布局 frame.h 应成立；若
        // intrinsic ≪ frame → cell 占位大内容画不满 = 用户看到的"空白"。
        for case let cell as WONodeCell in cv.visibleCells {
            guard let indexPath = cv.indexPath(for: cell),
                  indexPath.item < currentItems.count else { continue }
            let frame = indexPath.item < frames.count
                ? frames[indexPath.item] : .zero
            lines.append(String(format: "  CELL #%d %@ layoutH=%.0f drawH=%.0f intrinsic=%.0f",
                                indexPath.item, currentItems[indexPath.item].id,
                                frame.height, cell.hostViewFrame.height,
                                cell.hostIntrinsicHeight))
        }
        WOLayoutDiag.write(lines.joined(separator: "\n"))
    }

    private static func describeKind(_ kind: WOMListNodeKind) -> String {
        switch kind {
        case .bubble(let bubble):
            switch bubble.kind {
            case .assistant(let text): return "assistant(\(text.count)ch)"
            case .reasoning(let text): return "reasoning(\(text.count)ch)"
            case .user: return "user"
            case .tool: return "tool"
            default: return String(describing: bubble.kind).prefix(20).description
            }
        case .history: return "history"
        case .loading: return "loading"
        case .beam: return "beam"
        case .failed: return "failed"
        }
    }

    // MARK: 输入入口（representable updateUIViewController →）

    func applyUpdate(viewModel: ChatViewModel,
                     nodes: [ConversationProjector.DisplayNode],
                     phase: ChatViewModel.Phase,
                     sessionId: String,
                     bottomAllowance: CGFloat,
                     onBackgroundTap: @escaping () -> Void,
                     onHeadScrolled: @escaping (Bool) -> Void,
                     onImagePreview: @escaping (ImageAttachmentRef) -> Void,
                     widthHint: CGFloat = 0) {
        loadViewIfNeeded() // updateUIView 早于视图挂载的防御（dataSource 就位）
        bindIfNeeded(viewModel)
        // 【打开定位 修复3-a】会话身份变化也重新武装首帧定位——bindIfNeeded
        // 只认 VM 实例身份（!==），VM 复用换 sessionId 的切换路径下
        // needInitialPositioning 永不置位 = 打开零定位停顶（通路B 封口）。
        // 【QA P2-2 修】上一会话若停在拖拽断跟随态，定位 guard 会被拦——
        // 换会话即重新跟随（WORootFrame .id(sessionId) 整树重建时本块不可达，
        // bindIfNeeded 已全量重置；本块属纯防御路径，仍补齐）。
        if sessionId != self.sessionId {
            needInitialPositioning = true
            initialStabilizingUntil = 0
            stabilizingSnapPending = false
            followsBottom = true
        }
        self.nodes = nodes
        self.phase = phase
        self.sessionId = sessionId
        self.onBackgroundTap = onBackgroundTap
        self.onHeadScrolled = onHeadScrolled
        self.onImagePreview = onImagePreview
        // 【rail R1 第五跳】hint 刷新（消费在 applyUpdate 尾部 processWidthHint
        // ——六步语义，替代旧 trySwitch retry 钩子位）。
        self.widthHint = widthHint
        // 批 2 件 3：composer 动态让位（lody updateBottomInset 语义——变更
        // 才写、与滚动位置解耦）。
        updateBottomInset(bottomAllowance)
        sync()
        // 【rail R1】hint 消费位（R1 六步语义；hint 是唯一宽度权威）。
        processWidthHint()
        // 【rail T05 P1】空闲预热调度（0.6s 去抖；streaming/rail 让位）。
        schedulePrewarm()
    }

    /// 会话切换（viewModel 身份变）→ 全量重置（池/账本/簿记/快照）。
    private func bindIfNeeded(_ newViewModel: ChatViewModel) {
        guard viewModel !== newViewModel else { return }
        viewModel = newViewModel
        // 生命周期铁律（会话切换路径）：display link 停 + 在途量高切片作废。
        stopMotion()
        expansionGeneration += 1
        // 【CI修49】在途 stale 重测切片作废（新会话重来；pool.retain([])
        // 同步清 pending 锚/队列）。
        remeasureGen += 1
        remeasureQueue.removeAll()
        remeasureActive = false
        // 【CI修50】apply 待办/解冻累积一并清（旧会话的挂起请求对新会话
        // 无意义；drain 侧补发的 sync 用新会话状态自然重放）。
        syncPending = false
        syncPendingUnfreeze = []
        pool.retain([])
        ledger.reset()
        growthAnims = [:] // 【重做批6】会话切换清生长队列（旧会话动画作废）
        syncedNodes = [:]
        contentVersions = [:]
        currentItems = []
        lastPhase = nil
        historyLoading = false
        expanding = false
        followsBottom = true
        // 【批4 诊断实证修】新会话首次定位直写位（首个非空 apply 落地贴底）。
        needInitialPositioning = true
        initialStabilizingUntil = 0
        // 【重做批5 · 解耦】排版宽初始化（容器实际宽；之后只在 rail 落地时
        // 更新——resize 动画期间恒定，冻结门按它对账）。
        stableLayoutWidth = collectionView?.bounds.width ?? 0
        messageLayout.layoutWidth = stableLayoutWidth
        // 【rail R9-2】rail 全量清理（会话切换不跨残留；新会话走
        // needInitialPositioning 全量重置）。
        widthRail = nil
        railPrecompute = nil
        railPrecomputeGen += 1
        activeHintWidth = 0
        railSettleCounting = false
        if messageLayout.isRailActive { messageLayout.endRail() }
        // 探针簿记清零（live- 前缀 id 跨会话复用——旧会话残留会让新会话同
        // id 高度差 <1pt 的回报被防刷屏过滤误吞，污染取证）。
        fluidDiagLastH = [:]
        // P1 预热作废。
        prewarmGen += 1
        prewarmWorkItem?.cancel()
        prewarmWorkItem = nil
        pendingAnchorRestore = nil
        // 【CI修50】扩窗锚定寄存一并清（旧会话的锚对新会话无意义）。
        deferredExpansionAnchor = nil
        // 【重做批3 · R1】滚动停止门待办一并清。
        scrollEndExpansionPending = false
        frozenLiveIDs = []
        // 批 2 件 2：按钮状态位复位（会话切换不残留隐藏中断态）。
        backToBottomShown = false
        if let container = backToBottomContainer {
            container.isHidden = true
            container.alpha = 0
        }
        if dataSource != nil {
            if applyInFlight {
                // 【QA P0-R2 修】在途 apply → 只挂待办（落地后 drain 用新
                // 会话状态重放全量快照）。此处若并发提交第二个 apply，单布尔
                // applyInFlight 必然错账（completion 清位时序与 UIKit 内部
                // apply 串行化顺序耦合），.ips 同栈崩溃面重开——不变量
                // 「任一时刻至多一个 apply 在途」必须由本守卫维持。
                syncPending = true
            } else {
                // 【QA P1-2 修】清空走 applySnapshot 统一收口（applyInFlight
                // 簿记 + completion drain 同套——裸 apply 在更新块内触发
                // _notifyDidScroll → sync 再 apply 的 .ips 同类崩溃面封死）；
                // 空快照下附加动作（probe/贴底/按钮判定）均无害。
                applySnapshot(NSDiffableDataSourceSnapshot<Section, String>(),
                              changedCount: 0)
            }
        }
    }

    // MARK: 件 1 同步（updateUIView 33Hz 热路径）

    private func sync(forceUnfreeze: Set<String> = []) {
        guard let viewModel, dataSource != nil else { return }
        // 【CI修50】apply 在途 → 只记待办（completion 后 drain 补发）；
        // 解冻集并集累积【QA P1-1】（挂起丢集=回带行被 80 带秒回冻）。
        if applyInFlight {
            syncPending = true
            syncPendingUnfreeze.formUnion(forceUnfreeze)
            return
        }
        // 批 2 件 4：离屏冻结评估先行（跟随中恒不冻；回带解冻集在变更检测
        // 中强制追平）。滚动驱动的回带（无内容变化帧）另经 scrollViewDid
        // Scroll 调本评估——【批2-QA D2 修】解冻集经 forceUnfreeze 透传并在
        // 内部评估中排除：解冻后立即按 80 带再评估会把刚解冻行（d>80）秒回
        // 冻，打穿 160 迟滞带（抖动根源）；透传行本帧跳过再评估，下一滚动帧
        // 才按 80 带参与。
        // 【CI修49 拍板②】seedLedgerIfNeeded 挪至插入检测处（返回 justSeeded
        // 供动画排除；原 sync 开头的独立调用删除——幂等保护会让同帧二次调
        // 用恒 false，justSeeded 判定失效）。
        let unfrozen = updateFrozenStreams(excluding: forceUnfreeze)
            .union(forceUnfreeze)
        let (slice, _) = WOMessageListSupport.windowedSlice(
            nodes: nodes, start: viewModel.historyWindowStart)
        let items = WOMessageListSupport.flatten(
            nodes: slice, phase: phase,
            hasEarlierHistory: viewModel.hasEarlierHistory,
            historyLoading: historyLoading)
        // 【CI修49 拍板②】插入检测先行（context 需要本帧新插入集——SwiftUI
        // 入场豁免面）。首屏/扩窗/非跟随帧的新行同样进集（豁免 instant 无
        // 害——本来无人看动画/已被 seen 门静默），但**插入动画**只在跟随态。
        let previousIDsPre = Set(currentItems.map(\.id))
        let insertedIDs = Set(items.map(\.id)).subtracting(previousIDsPre)
        // 本帧是否刚补种（首屏 seed / 相位变化补种）——同帧插入动画排除
        // （首屏历史静默呈现 + 回合尾落盘节点 instantLive"刚看过不重播"
        // 语义都靠它保住；同出动画主场景=streaming 中新 live 节点帧）。
        // 种子位维护（seedLedgerIfNeeded 副作用——首屏/相位边界补种）；
        // 【重做批3 · R2】justSeeded 返回值原消费方（插入动画排除）随
        // animatedInsert 路线废弃，显式丢弃（批 6 行高生长的种子排除若需
        // 要再接回）。
        _ = seedLedgerIfNeeded(viewModel)
        context = makeContext(freshlyInserted: insertedIDs)
        // 【重做批6 · 同出生长】新插入行几何侧入队（格子 0→真值 0.66s 生长，
        // SwiftUI 侧同出淡入经 freshlyInsertedIDs 传递——both 参考件同步）。
        // seen/instantLive/user 行不入队（历史静默/刚看过/mInR 语义）。
        if !insertedIDs.isEmpty {
            for item in items where insertedIDs.contains(item.id) {
                enqueueGrowthIfEligible(item)
            }
            if !growthAnims.isEmpty { startMotion() }
        }

        // 33Hz no-op 守卫：条目全等且无解冻行 → 零 apply。有解冻行 → 追平
        // （基线同步到最新 + 单次 reconfigure，"内容照常累积、显示一次性追"）。
        if items == currentItems {
            guard !unfrozen.isEmpty else { return }
            var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(currentItems.map(\.id))
            for id in unfrozen {
                if let item = currentItems.first(where: { $0.id == id }) {
                    syncedNodes[id] = item
                    contentVersions[id, default: 0] += 1
                }
            }
            snapshot.reconfigureItems(Array(unfrozen))
            applySnapshot(snapshot, changedCount: unfrozen.count)
            return
        }

        // 变更检测：id 不变内容变 → reconfigure；新 id → 插入（cellProvider
        // 以最新节点构建，无需 reconfigure）。冻结中的 live 行（且本帧未解冻）
        // 跳过基线更新与 reconfigure——内容基线保持冻结前值（解冻帧一次性
        // 追平），版本不 bump = 池高度签名不变 = 行高冻结。
        let previousIDs = Set(currentItems.map(\.id))
        // 【rail R9-7 land-on-identity-change】rail 期节点身份集变化（插入/
        // 删除）→ rail 立即落地（跳终态 + 结算窗收敛）——退化为"瞬切 +
        // 1s 结算窗"，无锚定瞬移风险面（流式高频插入防 rail 弯曲/高频重启）。
        if widthRail != nil, previousIDs != Set(items.map(\.id)) {
            messageLayout.updateRailProgress(1)
            finishWidthRail(writeOffset: true)
        }
        var ids: [String] = []
        var changed: [String] = []
        for item in items {
            ids.append(item.id)
            if frozenLiveIDs.contains(item.id) {
                // 冻结中且本帧未解冻：基线不动、reconfigure 跳过（continue）。
                continue
            }
            if let old = syncedNodes[item.id] {
                if old != item {
                    syncedNodes[item.id] = item
                    contentVersions[item.id, default: 0] += 1
                    if previousIDs.contains(item.id) { changed.append(item.id) }
                }
            } else {
                syncedNodes[item.id] = item
            }
        }
        let itemIDs = Set(ids)
        syncedNodes = syncedNodes.filter { itemIDs.contains($0.key) }
        contentVersions = contentVersions.filter { itemIDs.contains($0.key) }
        currentItems = items

        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems(ids)
        if !changed.isEmpty { snapshot.reconfigureItems(changed) }
        // 【重做批3 · 验证记录 R2】同出动画不走 diffable 插入动画（lody 原版
        // 默认分支恒无动画 apply；用户参考件《同出丝滑效果》语义=新行高度
        // 生长，由批 6 的行高插值队列实现——insertedIDs 判定链保留，作为批 6
        // 的 freshlyInsertedIDs 透传与 SwiftUI 豁免缝）。
        let insertedHasNonUser = items.contains { item in
            guard insertedIDs.contains(item.id) else { return false }
            if case .bubble(let bubble) = item.kind,
               case .user = bubble.kind { return false }
            return true
        }
        _ = insertedHasNonUser // 批 6 消费位（本阶段恒无动画 apply）
        applySnapshot(snapshot, changedCount: changed.count)
        // 行移出数据集 → 池/高度随行清理。扩窗量高进行中跳过——被测节点
        // 尚未入库，不可清（提交后 sync 自然覆盖）。
        if !expanding {
            pool.retain(itemIDs)
        }
    }

    /// apply 收口（探针 + 贴底触发：批 2 件 1——apply 完成后内容可能增长，
    /// followsBottom 时经 scrollToBottom 唤醒/维持 display link 收敛贴底）。
    /// 【重做批3 · 验证记录 R2】animatingDifferences 恒 false（lody 原版同款
    /// ——diffable 插入动画路线废弃，同出动画批 6 经行高插值队列重做）。
    private func applySnapshot(_ snapshot: NSDiffableDataSourceSnapshot<Section, String>,
                               changedCount: Int) {
        let startTime = CACurrentMediaTime()
        let itemCount = snapshot.itemIdentifiers.count
        // 【CI修50】重入防护：置位 → apply → completion 清位 + 补发在途
        // sync（非动画 apply 的 completion 同步回调，链式续发为官方合法点；
        // 与 lody applying/needsApply 门同构，2026-10-06 对拍验证）。
        applyInFlight = true
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.applyInFlight = false
            WOChatProbe.shared.record(
                durationMs: (CACurrentMediaTime() - startTime) * 1000,
                itemCount: itemCount,
                reconfigureCount: changedCount,
                poolCount: self.pool.poolCount)
            self.drainPendingSync()
            // 【CI修50】寄存的扩窗锚定随快照落地入位（下一次 layout pass
            // 对新帧消费）。
            if let restore = self.deferredExpansionAnchor {
                self.deferredExpansionAnchor = nil
                self.pendingAnchorRestore = restore
            }
            // 【批4 诊断实证修】首次定位直写（首个非空 apply 落地即贴底，
            // 消灭"收敛追着行高修正跑"的数秒上掠/半路停顿；display link
            // 保留给流式跟随与后续内容变化）。
            // 【真机根修 2026-10-09】消耗条件收紧到"首个含正文(bubble)的
            // apply"：loading 占位帧不再消耗，稳定期从内容首帧起算。
            // 【打开定位 修复3-b/c】几何就绪门 + 推迟重试——stableLayoutWidth
            // ==0（bind 冷启动采到 bounds=0 的帧）时 prepare 按 width<1 排版
            // 排不出真高度，落点≈顶=机会白烧（通路A）；未就绪推迟不消耗，
            // viewDidLayoutSubviews 每帧重试（tryInitialPositioning 双入口）。
            self.tryInitialPositioning(forceLayout: true)
            // 【批4 真机诊断】apply 落地 3s 后布局快照（打开会话稳态取证；
            // 限频器挡高频 apply 的重复排程）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.dumpLayoutSnapshot(reason: "apply+3s")
            }
        }
        // 内容变 → 行高可能变 → 失效 layout（prepare 重问池：签名 bump 的
        // 行重测，其余行缓存直读零触碰）。
        if changedCount > 0 {
            messageLayout.invalidateLayout()
        }
        // 批 2 件 1：贴底触发（lody applyRows→scrollToBottom 同型——距底
        // >0.5 才 startMotion，已在底不空转）。
        if followsBottom {
            scrollToBottom()
        }
        updateBottomButton()
    }

    /// 【CI修50】apply 落地后补发在途 sync（每次 drain 只消费一个待办位；
    /// 补发的 sync 若再遇在途会重新挂起，链自然终止）。挂起期累积的解冻
    /// 集一并透传【QA P1-1】。
    private func drainPendingSync() {
        guard syncPending else { return }
        syncPending = false
        let unfreeze = syncPendingUnfreeze
        syncPendingUnfreeze = []
        sync(forceUnfreeze: unfreeze)
    }

    // MARK: 【打开定位 2026-10-09 修复3】首帧贴底（不变量：打开后首个含正文
    // 的帧 + 几何就绪 → 直写贴底；2s 稳定期结束兜底校准）

    /// 首帧定位（双补跑入口：apply completion / viewDidLayoutSubviews）。
    /// 几何未就绪（stableLayoutWidth==0——bind 冷启动采到 bounds=0 的帧）
    /// 时**推迟不消耗**（通路A 封口：layoutWidth=0 的 prepare 排不出真高度，
    /// 落点≈顶=机会白烧）；推迟后每帧由 viewDidLayoutSubviews 重试直至
    /// 就绪消耗。写前强制布局保证 contentSize 真值（completion 路径）。
    private func tryInitialPositioning(forceLayout: Bool) {
        guard needInitialPositioning, followsBottom,
              stableLayoutWidth > 0,
              let cv = collectionView, cv.bounds.width > 1,
              currentItems.contains(where: { item in
                  if case .bubble = item.kind { return true }
                  return false
              }) else { return }
        needInitialPositioning = false
        initialStabilizingUntil = CACurrentMediaTime() + 2.0
        stabilizingSnapPending = true
        // completion 路径新数据的 prepare 可能还没跑 → 先强制一轮再取贴底
        // 落点；viewDidLayoutSubviews 路径 prepare 刚跑过（contentSize 本帧
        // 真值）→ 不重复强制（防布局重入）。
        if forceLayout { cv.layoutIfNeeded() }
        let bottom = self.bottomOffset
        cv.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
    }

    /// 稳定期结束兜底（修复3-e）：打开后 2s 校准——仍跟随、未拖拽、距底
    /// >1pt（任何交错把贴底弄丢）→ 一次直写归位。一次性消费；用户已拖拽
    /// （followsBottom=false）绝不动作。
    private func settleSnapIfDue() {
        guard stabilizingSnapPending,
              CACurrentMediaTime() >= initialStabilizingUntil else { return }
        stabilizingSnapPending = false
        guard followsBottom, let cv = collectionView,
              !cv.isDragging, !cv.isDecelerating,
              abs(cv.contentOffset.y - bottomOffset) > 1 else { return }
        // 【流体诊断】稳定期兜底校准执行探针（低频 note 必落盘）+ 冲刷
        // 结算窗缓冲（H-DIRECT/H-LATE/COMMIT 全量落档）。
        WOFluidDiag.note("SETTLE-SNAP off=\(String(format: "%.1f", cv.contentOffset.y)) -> \(String(format: "%.1f", bottomOffset))")
        WOFluidDiag.dump(reason: "settle-snap")
        cv.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false)
    }

    /// 入场账本补种（原 seedEntry + onChange(phase) 补种语义逐帧对齐）：
    /// ①首个非 loading 相位帧 seedAll（历史/恢复静默呈现）；②相位变化落到
    /// 非 .streaming → 回合尾新增节点即时呈现不播动画。
    /// 只在相位变化帧补种（非每帧）——idle 期新入场节点（乐观 u-pending）
    /// 不被误种，mInR 动画保持。
    /// 【CI修49 拍板②】返回本帧是否刚补种（同帧插入动画排除依据——首屏
    /// 历史静默 + 回合尾落盘 instantLive"刚看过不重播"）。
    @discardableResult
    private func seedLedgerIfNeeded(_ viewModel: ChatViewModel) -> Bool {
        guard phase != lastPhase else { return false }
        var justSeeded = false
        if !ledger.seeded, phase != .loading {
            ledger.seedAll(viewModel.bubbles.map(\.id))
            ledger.markSeeded()
            justSeeded = true
        }
        if phase != .streaming {
            ledger.seedAll(viewModel.bubbles.map(\.id))
            justSeeded = true
        }
        lastPhase = phase
        return justSeeded
    }

    private func makeContext(freshlyInserted: Set<String>) -> WONodeContext {
        WONodeContext(
            sessionId: sessionId,
            attachmentStore: viewModel?.attachmentStore,
            onImagePreview: { [weak self] ref in self?.onImagePreview?(ref) },
            phase: phase,
            justEndedStreaming: viewModel?.justEndedStreaming ?? false,
            settledBubbleIDs: viewModel?.settledBubbleIDs ?? [],
            ledger: ledger,
            freshlyInsertedIDs: freshlyInserted)
    }

    private func cellProvider(_ collectionView: UICollectionView,
                              _ indexPath: IndexPath,
                              _ itemID: String) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: "WONodeCell", for: indexPath) as? WONodeCell else {
            return UICollectionViewCell()
        }
        let node = syncedNodes[itemID]
            ?? currentItems.first(where: { $0.id == itemID })
            // 不可达防御（itemID 恒来自 snapshot；CI修47：枚举无 .note case，
            // 用最无害的 .loading 占位）。
            ?? WOMListNode(id: itemID, kind: .loading)
        cell.configure(content: makeNodeContent(node))
        return cell
    }

    /// 条目内容统一装配缝（CI修48 收口三处重复构造：cellProvider /
    /// measureNode / listLayout 量高闭包）。WONodeItemContent + .id（identity
    /// 锚，复用语义不动）；reportsHeight=true 时外包 WOHeightReporting
    /// 【QA P1-1 收窄】上报桥只属于显示面（cellProvider 默认）——两处量高
    /// 闭包传 false：离屏 host 的 preference 若在 layout prepare 重入现场
    /// 触发（systemLayoutSizeFitting 同步布局的版本分歧行为面），会在
    /// itemFrames 半重建态执行 invalidateLayout/captureTopAnchor（未定义
    /// 行为面），摘除即封死。
    private func makeNodeContent(_ item: WOMListNode,
                                 reportsHeight: Bool = true) -> AnyView {
        if reportsHeight {
            return AnyView(
                WONodeItemContent(node: item, context: context)
                    .modifier(WOHeightReporting(id: item.id) { [weak self] id, height in
                        self?.nodeHeightChanged(id: id, height: height)
                    })
                    .id(item.id)
            )
        }
        return AnyView(WONodeItemContent(node: item, context: context).id(item.id))
    }

    /// SwiftUI 内容实测高度回传（CI修48）。
    /// 时序：cell 挂载 → 异步内容就绪（Markdown 解析/图片加载/展开）→
    /// GeometryReader 值变 → 上报 → 池缓存修正 → invalidateLayout 重排。
    /// 防线【QA P2-1 注释纠偏】：window guard 只确认显示面已挂窗（桥已
    /// 经 reportsHeight=false 收窄到显示面，离屏 host 无上报面）；真正
    /// 防风暴 = 池内 0.5pt 死区 + 量值一致后同值吞掉。签名随上报传入
    /// 【QA P1-2】（当前内容版本——heights 被清空后首写即真签名，杜绝
    /// "" 签名条目被空态重测覆盖 → 永久溢出窗口）。
    func nodeHeightChanged(id: String, height: CGFloat) {
        guard let cv = collectionView, cv.window != nil else { return }
        // 【rail R6 门】rail 在途/预计算在途 → 上报不入账本、不弯 rail（确定性
        // 优先——预计算真值已在池内=显示真值，rail 后修正量≈0；rail 后可见行
        // 真值经既有报告链 + 1s 结算窗自然修正，离屏行走 stale 切片）。
        // 在途 growthAnim 终点同步刷新（既有 QA P2-2 语义保留——防动画到期
        // 落点停在旧值小回跳）。探针 H-DROP-RAIL。
        // （旧 fluid 门随流体重排机器退役——本门替换其位置，语义对照
        // 架构文档 R6/R8-#10。）
        if widthRail != nil || railPrecompute != nil {
            if let active = growthAnims[id] {
                growthAnims[id] = GrowthAnim(from: active.from, to: height,
                                             start: active.start,
                                             duration: active.duration,
                                             kind: active.kind)
            }
            fluidDiagH("H-DROP-RAIL", id: id, height: height,
                       "H-DROP-RAIL id=\(id) h=\(String(format: "%.1f", height)) rail=\(widthRail != nil) precompute=\(railPrecompute != nil)")
            return
        }
        guard abs(cv.bounds.width - stableLayoutWidth) <= 0.5,
              stableLayoutWidth > 0 else {
            // 【流体诊断】宽度门丢弃路由探针（guard else 面内插桩，逻辑
            // 等价；H 系列防刷屏过滤同款——同 id 高度差 <1pt 跳过）。
            fluidDiagH("H-DROP-WG", id: id, height: height,
                       "H-DROP-WG id=\(id) h=\(String(format: "%.1f", height)) bounds=\(cv.bounds.width) stable=\(stableLayoutWidth)")
            return
        }
        let width = contentWidth()
        let previous = pool.cachedHeight(id: id, width: width)
        // 【批4 真机诊断】大跳变落行（|Δ|>150pt）——残余问题定位探针。
        if let previous, abs(previous - height) > 150 {
            heightJumpLog.error("wo-height-jump id=\(id, privacy: .public) old=\(previous, format: .fixed(precision: 0)) new=\(height, format: .fixed(precision: 0))")
        }
        let signature = contentVersions[id].map { "v\($0)" }
        guard pool.updateHeight(id: id, width: width, height: height,
                                signature: signature) else { return }
        // 【2026-10-09 修复2】动画在途时同行的后续回报**并入在途动画**（从
        // 当前显示位续跑剩余时长、更新终点）——不许重起/直写插队打断，收缩
        // 动画保持单向单速（用户实测"正常播→跳过一段→继续正常播"=时间驱动
        // 插值被中途打断的面，双保险之一）。
        if growthAnims[id] != nil {
            if let display = growthDisplayHeight(id: id) {
                let active = growthAnims[id]!
                let remaining = max(0.08, active.start + active.duration
                    - CACurrentMediaTime())
                growthAnims[id] = GrowthAnim(from: display, to: height,
                                             start: CACurrentMediaTime(),
                                             duration: remaining,
                                             kind: active.kind)
                messageLayout.invalidateLayout()
                return
            }
            // 【QA P2-1 修】动画已过期（display link 清理前的窗口期）→ 摘除
            // 条目走下方正常路由——防 entrance 行以 from=0 重生长一闪。
            growthAnims[id] = nil
        }
        // 运动分流（CI修50 归一 + 重做批6 插值 + 2026-10-09 披露单时钟）：
        // ①打开稳定期 / 流式 live 行 → 直写（打开即稳 / 贴底收敛独占）。
        // ②大幅变化（|Δ|≥20pt）→ 引擎插值，按种类分派：
        //   - live-* 行（未跟随态流式）→ .entrance（既有行为原样）。
        //   - 思考/工具披露（非 live）→ .disclosure（disclosureEase 0.32s，
        //     参考件曲线）。from 取**当前显示高**（插值在途时反向切换连续，
        //     不回跳）。
        //   披露动画期间不做贴底重钉（:979 旧补偿已删——表头钉死语义：
        //   布局为自上而下累计，格子高度变化本就不动自身 origin，唯一能
        //   拖走表头的是 contentOffset 变化）；底部展开时按用户拍板断开
        //   跟随（下方内容被推出屏不拉回，回底钮接管）。
        // ③小修正 → 直写瞬调（与 R0 LazyVStack 行高瞬变一致）。
        let initialStabilizing = CACurrentMediaTime() < initialStabilizingUntil
        let isLiveRow = id.hasPrefix("live-")
        let liveStreaming = followsBottom && isLiveRow
        if initialStabilizing || liveStreaming {
            // 【流体诊断】结算窗/流式直写路由探针（纯记录）。
            let oldDesc = previous.map { String(format: "%.1f", $0) } ?? "nil"
            fluidDiagH("H-DIRECT", id: id, height: height,
                       "H-DIRECT id=\(id) h=\(String(format: "%.1f", height)) old=\(oldDesc) settle=\(CACurrentMediaTime() < initialStabilizingUntil ? "window" : "init")")
            commitHeightChange(id: id, height: height, collectionView: cv)
            return
        }
        if let prev = previous, abs(prev - height) >= 20 {
            let kind: GrowthKind = isLiveRow ? .entrance : .disclosure
            let display = growthDisplayHeight(id: id) ?? prev
            // 【流体诊断】披露/入场动画路由探针（纯记录）。
            fluidDiagH("H-ANIM", id: id, height: height,
                       "H-ANIM id=\(id) kind=\(kind) from=\(String(format: "%.1f", display)) to=\(String(format: "%.1f", height))")
            // 时长恒 0.32（QA P1-2）：本分支新旧两路由历史时长均为 0.32；
            // 0.66 只属于 enqueueGrowthIfEligible 的新行入场路径，不得外溢。
            growthAnims[id] = GrowthAnim(from: display, to: height,
                                         start: CACurrentMediaTime(),
                                         duration: 0.32,
                                         kind: kind)
            messageLayout.invalidateLayout()
            // 【QA P1-1 修】无条件启动驱动（growth tick 不依赖 tracking；自停
            // 条件 growthAnims 非空保活）——非跟随态此前不 startMotion=插值
            // 停在首帧。
            startMotion()
            switch kind {
            case .entrance:
                if followsBottom { scrollToBottom() }
            case .disclosure:
                if followsBottom {
                    // 【修复3-d】只有该行当前**在视口内**才断跟随（用户正看
                    // 着它展开=下方内容被推出屏的语义，用户拍板的取舍）；离
                    // 屏行的高度修正不许偷走跟随状态——打开期"永不回底"的
                    // 开关误关通道封口。
                    let rowVisible = cv.indexPathsForVisibleItems.contains { path in
                        path.item < currentItems.count
                            && currentItems[path.item].id == id
                    }
                    if rowVisible {
                        followsBottom = false
                        updateBottomButton()
                    }
                }
            }
            return
        }
        // 【流体诊断】结算窗过期后的最终直写回报探针（疑似贴底收尾后抽动
        // 源，必看；纯记录）。
        let lateOld = previous.map { String(format: "%.1f", $0) } ?? "nil"
        let lateDelta = previous.map { String(format: "%.1f", height - $0) } ?? "nil"
        fluidDiagH("H-LATE", id: id, height: height,
                   "H-LATE id=\(id) h=\(String(format: "%.1f", height)) old=\(lateOld) delta=\(lateDelta)")
        commitHeightChange(id: id, height: height, collectionView: cv)
    }

    /// 高度提交公共体【QA P1-2 拆分】：锚定 + invalidate + 贴底。回传路径与
    /// 切片重测路径共用。
    /// 【重做批6 · 运动单源化 2026-10-07】恒直写（animated 参数删除）：
    /// 几何运动只许一个驱动者——展开期=SwiftUI 时钟（逐帧上报驱动格子），
    /// 同出生长=display link 插值队列，贴底=display link 收敛。布局永不
    /// 动画化（UIViewPropertyAnimator 已删=撕裂/叠影根治）。打开稳定期贴底
    /// 直写钉底（无收敛动画=无"打开后滚动播放"感）。
    private func commitHeightChange(id: String, height: CGFloat,
                                    collectionView cv: UICollectionView) {
        // 【流体诊断】直写公共体入口探针（纯记录）。
        WOFluidDiag.record("COMMIT id=\(id) h=\(String(format: "%.1f", height)) follow=\(followsBottom) anchor-pending=\(pendingAnchorRestore != nil)")
        // 【rail R10】结算窗 commit 计数（RAIL-END settleCount 消费）。
        if railSettleCounting { railSettleCommitCount += 1 }
        if !followsBottom, !expanding {
            pendingAnchorRestore = AnchorRestore(
                anchor: captureTopAnchor(),
                oldContentHeight: cv.contentSize.height)
        }
        messageLayout.invalidateLayout()
        // 【批4 诊断实证修】异步补标一次（幂等）：SwiftUI 的 onPreference
        // Change 常嵌在 hosting 布局链（= collectionView layout pass 内）
        // ——pass 内 invalidate 存在被 UIKit 忽略的面（list-diag.log 实锤
        // frame=23/pool=47 脱钩）。若首个 invalidate 已生效，此处为无变化
        // 的空标记；循环终止=池值稳定（updateHeight 0.5pt 死区）。
        DispatchQueue.main.async { [weak self] in
            self?.messageLayout.invalidateLayout()
        }
        if followsBottom {
            if CACurrentMediaTime() < initialStabilizingUntil {
                // 打开会话初始稳定期：瞬写贴底（钉底，修正推高 contentSize
                // 时视口跟随——无收敛动画=无"从中部滚到底"播放感）。
                cv.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false)
            } else {
                scrollToBottom()
            }
        }
    }

    // MARK: 件 2 高度问池（layout delegate）

    private func contentWidth() -> CGFloat {
        // 【重做批5 · 解耦】对账口径 = 排版宽（池条目宽度绑定 layoutWidth；
        // resize 动画期间回传按排版宽对账，rail 落地后同宽落池）。
        return stableLayoutWidth - messageLayout.sectionInset.left
            - messageLayout.sectionInset.right
    }

    /// 单个 displayNode（plain=1 条 / process=组内平铺多条）量高入库。
    private func measureNode(_ node: ConversationProjector.DisplayNode,
                             width: CGFloat) {
        let listNodes: [WOMListNode]
        switch node {
        case .plain(let bubble):
            listNodes = [WOMListNode(id: bubble.id, kind: .bubble(bubble))]
        case .process(let group):
            listNodes = group.bubbles.map {
                WOMListNode(id: $0.id, kind: .bubble($0))
            }
        }
        for item in listNodes {
            pool.height(id: item.id, width: width,
                        signature: "v\(contentVersions[item.id] ?? 0)",
                        makeContent: { [weak self] in
                            guard let self else { return AnyView(Color.clear) }
                            // QA P1-1：量高路径不挂上报桥（离屏 host 无上报面）。
                            return self.makeNodeContent(item, reportsHeight: false)
                        })
        }
    }

    // MARK: 件 3 历史扩窗（顶部预取 + 4ms 预算切片 + 锚定恢复）

    /// 【CI修49】宽度变化 stale 重测切片（右栏开合/旋转根治第二半）：
    /// 列宽动画逐帧变化 → prepare 逐帧 stale 收集 →【CI修50】动画中只收集
    /// 不清账，稳定后 drain 追加队列 → 4ms 预算 + 8ms 让位（lody
    /// prepareHistorySlice 同参）后台重测 → 经 commitHeightChange(免动画)
    /// 提交（锚定恢复保视线）。
    /// 队列模式：新 batch 追加不中断在途切片（pendingRemasure 去重防
    /// 重复入队）；单条执行时校验宽度仍等于当前 contentWidth——不等
    /// （动画还在变）丢弃，宽度稳定后的问询重新入队。
    private var remeasureQueue: [WOHostSizingPool.StaleEntry] = []
    private var remeasureActive = false
    /// 切片代际（会话切换/视图拆解作废）。
    private var remeasureGen = 0
    /// 【批4 真机修复】Markdown 解析完成广播订阅（viewDidLoad 建，deinit 撤）。
    private var markdownParsedObserver: NSObjectProtocol?
    /// 【批4 真机诊断】行高大跳变落行（Console 过滤 category=height）。
    private let heightJumpLog = Logger(subsystem: "WanWo", category: "height")

    private func drainStaleSweep() {
        // 【rail R6】rail/预计算在途 → 不清账（stale 留池内，rail 后既有切片
        // 渐进重测——rail 期 prepare 早退本就不收集，此 guard 双保险）。
        guard widthRail == nil, railPrecompute == nil else { return }
        // 【重做批5 · 解耦】旧宽度检测分支拆除——宽度变化改由 layout.prepare
        // 的 onLiveWidthChange 直报（容器 resize 强制 invalidate 绕过
        // shouldInvalidateLayout，旧检测在 viewDidLayoutSubviews 里每帧把
        // lastStableWidth 更新成中间宽 = 冻结门失效 = 逐帧 reflow 抖动根因）。
        // 本函数现在只做：stale 批量调度（内容版本变化路径仍用）。
        let batch = pool.drainStaleSweep()
        guard !batch.isEmpty else { return }
        remeasureQueue.append(contentsOf: batch)
        guard !remeasureActive else { return }
        remeasureActive = true
        runRemeasureSlice(generation: remeasureGen, index: 0)
    }

    // MARK: 【rail R1-R7】确定性宽度动画（预计算 + 插值 + 精确锚定）
    //  旧流体重排机器（逐帧布局快照/宽度状态机/去抖 timer/0.55s 时长门/
    //  同帧双排版/逐帧补偿/宽度比近似分支）随 R8 删除清单整体退役——本节为
    //  唯一宽度状态机（架构文档 §4/R1-R7/R9）。

    // MARK: 流体诊断探针辅助（纯记录；只读，无 layoutIfNeeded 不引入布局重入）

    /// H 系列回报路由记录（防刷屏：同 tag+id 高度差 <1pt 跳过——纯记录辅助，
    /// 不影响主逻辑）。
    private func fluidDiagH(_ tag: String, id: String, height: CGFloat,
                            _ line: String) {
        let key = tag + "|" + id
        if let last = fluidDiagLastH[key], abs(last - height) < 1 { return }
        fluidDiagLastH[key] = height
        WOFluidDiag.record(line)
    }

    /// 【rail R8-#15】layout.prepare 检测到容器宽 ≠ 排版宽（fallback 路径）。
    /// hint 管道是唯一宽度权威——本函数只保留冷启动收养 + LIVE-CHANGE 探针，
    /// 其余一律早退（旧流体重排/去抖切换链退役）。
    private func handleContainerWidthFallback(_ width: CGFloat) {
        guard width != stableLayoutWidth, width > 1 else { return }
        // 【流体诊断】宽度 fallback 路由探针（保留标签 LIVE-CHANGE）。
        WOFluidDiag.record("LIVE-CHANGE w=\(width) stable=\(stableLayoutWidth) rail=\(widthRail != nil)")
        // 【QA P0-1 修·冷启动收养】首次挂载 loadViewIfNeeded 不触发布局 →
        // bindIfNeeded 采到 bounds=0 → stableLayoutWidth/layoutWidth 恒 0 →
        // 列表永久空白。layoutWidth 为 0 时直接采认当前宽（无旧数据需保护，
        // 无需预重测/锚定）。常规宽度变化一律走 hint 管道（processWidthHint
        // ⑥同款收养语义——hint 缺席的直注宿主由此兜底）。
        if stableLayoutWidth == 0, messageLayout.layoutWidth == 0 {
            stableLayoutWidth = width
            messageLayout.layoutWidth = width
            messageLayout.invalidateLayout()
        }
    }

    // MARK: 【rail R1】hint 消费（applyUpdate 尾部；六步语义）

    private func processWidthHint() {
        // ① 守卫：未挂窗/无数据源 → 不动作（后续 applyUpdate 重入本函数）。
        guard collectionView?.window != nil, dataSource != nil else { return }
        // ② hint ≤ 100 → 拒（全屏折算 center=0：旧布局冻结被 clipped；宽度
        // 回来 hint>100 走正常路径——R9-3）。
        guard widthHint > 100 else { return }
        // ③ hint == stable → 幂等无动作（R9-8：关回原位且 precompute 未完成
        // → 作废 precompute 直接 return，无 rail）。
        if abs(widthHint - stableLayoutWidth) <= 0.5 {
            activeHintWidth = widthHint
            // 【QA P0 修 2026-10】rail 在途变体（快速连开连关）：rail 起跑后
            // 关回原位 → 本分支原先只 abortRail（解除布局冻结）而**漏清
            // widthRail/不停 motionLink**——后续 tick 继续跑，p≥1 时
            // finishWidthRail→endRail 会把 itemFrames/stable 切到被放弃目标
            // 的 toFrames（真实容器宽已回原位）→ 布局永久错宽卡死（第④步
            // 幂等门吞掉后续同值 hint，无自愈）。修法：widthRail/railSettle
            // 簿记与布局冻结一起熄灯 + 停表；abortRail 选型不变（保持混合帧，
            // 不切被放弃目标的 toFrames）。
            if messageLayout.isRailActive || widthRail != nil {
                widthRail = nil
                railSettleCounting = false
                stopMotion()
                if messageLayout.isRailActive {
                    messageLayout.abortRail()
                    messageLayout.invalidateLayout()
                }
            }
            if railPrecompute != nil {
                railPrecomputeGen += 1
                railPrecompute = nil
            }
            return
        }
        // ④ body 重复求值幂等门（同 hint 重入拦下）。
        if widthHint == activeHintWidth { return }
        // ⑤ rail/precompute 在途且目标已变 → 重启链（R9-1/R9-4）。
        if let rail = widthRail {
            if abs(rail.targetViewportWidth - widthHint) <= 0.5 {
                activeHintWidth = widthHint
                return
            }
            restartRail(to: widthHint)
            return
        }
        if let precompute = railPrecompute {
            if abs(precompute.targetViewportWidth - widthHint) <= 0.5 {
                activeHintWidth = widthHint
                return
            }
            // 作废重启（前次 gen 作废；连续 resize = restart 链，R9-4）。
            railPrecomputeGen += 1
            railPrecompute = nil
        }
        // ⑥ 冷启动收养（旧宽度状态机收养分支语义迁入）。
        if stableLayoutWidth == 0 {
            stableLayoutWidth = widthHint
            messageLayout.layoutWidth = widthHint
            activeHintWidth = widthHint
            messageLayout.invalidateLayout()
            return
        }
        activeHintWidth = widthHint
        startPrecompute(targetViewportWidth: widthHint)
    }

    /// 【rail R9-1】rail 中途换目标：fromFrames=当前混合 itemFrames（快照），
    /// 目标=新 hint 预计算（池大概率缓存命中，同帧可启）；新 WidthRail 于
    /// startRail 重置时钟（RAIL-START 重复 note——每次起跑必落）。
    private func restartRail(to newHint: CGFloat) {
        guard collectionView?.window != nil, dataSource != nil else { return }
        // 旧 rail 簿记熄灯（不写 offset 不结算——新 rail 起跑重置基线）。
        widthRail = nil
        railSettleCounting = false
        activeHintWidth = newHint
        // 布局保持 rail 冻结态（当前混合帧原样，prepare 持续早退）；
        // startPrecompute 完成时 beginRail(fromFrames: 混合快照, toFrames: 新端)
        // 从中途续跑。
        startPrecompute(targetViewportWidth: newHint)
    }

    // MARK: 【rail R2】预计算切片（4ms 预算 + 8ms 间隙；railPrecomputeGen 防串）

    /// rail 前置条件门 + 切片启动。rail 未启动期间 layoutWidth 恒旧值 →
    /// prepare 产物不变 → "窗框动画不动"，零跳变（旧布局冻结语义）。
    private func startPrecompute(targetViewportWidth: CGFloat) {
        guard collectionView?.window != nil, dataSource != nil else { return }
        let targetContentWidth = targetViewportWidth
            - messageLayout.sectionInset.left - messageLayout.sectionInset.right
        guard targetContentWidth > 1 else { return }
        railPrecomputeGen += 1
        let generation = railPrecomputeGen
        railPrecompute = RailPrecompute(
            targetViewportWidth: targetViewportWidth,
            targetContentWidth: targetContentWidth,
            generation: generation,
            cursor: 0,
            // 启动时刻 currentItems 快照（身份固定；流式新增行走 startRail
            // 同步补量——身份集变化本身走 land-on-identity-change，R9-7）。
            snapshot: currentItems,
            startedAt: CACurrentMediaTime())
        runPrecomputeSlice(generation)
    }

    private func runPrecomputeSlice(_ generation: Int) {
        guard var pc = railPrecompute, pc.generation == generation else { return }
        guard collectionView?.window != nil, dataSource != nil else {
            // 离场（R9-10）：作废（rail 不再起跑；下一 hint 重入重建）。
            railPrecompute = nil
            return
        }
        let sliceStart = CACurrentMediaTime()
        while pc.cursor < pc.snapshot.count,
              (CACurrentMediaTime() - sliceStart) < 0.004 {
            let item = pc.snapshot[pc.cursor]
            pc.cursor += 1
            // 缓存命中即跳过（P1 预热的主收益面；未命中 remeasure 同步量高
            // + 直写 cache，与既有量高路径同缝——reportsHeight=false 不挂
            // 上报桥）。
            if pool.cachedHeight(id: item.id, width: pc.targetContentWidth) != nil {
                continue
            }
            _ = pool.remeasure(
                id: item.id, width: pc.targetContentWidth,
                signature: "v\(contentVersions[item.id] ?? 0)",
                makeContent: { [weak self] in
                    guard let self else { return AnyView(Color.clear) }
                    return self.makeNodeContent(item, reportsHeight: false)
                })
        }
        railPrecompute = pc
        if pc.cursor < pc.snapshot.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
                guard let self, self.railPrecompute?.generation == generation else { return }
                self.runPrecomputeSlice(generation)
            }
            return
        }
        // 预计算完成 → rail 起跑（precomputeMs 观测点=RAIL-START，R9-5）。
        let precomputeMs = (CACurrentMediaTime() - pc.startedAt) * 1000
        railPrecompute = nil
        startRail(targetViewportWidth: pc.targetViewportWidth,
                  targetContentWidth: pc.targetContentWidth,
                  precomputeMs: precomputeMs)
    }

    // MARK: 【rail R3-R5】rail 起跑 / 逐帧 tick / 落地

    /// rail 起跑：toFrames=按 currentItems 顺序对池值 O(n) 累加（y 起点
    /// sectionInset.top，x=left，宽=targetContentWidth，步进 lineSpacing）；
    /// fromFrames=当前 itemFrames 快照（restart 时=混合帧）；锚/贴底基线
    /// 捕获 → startMotion → RAIL-START。
    private func startRail(targetViewportWidth: CGFloat,
                           targetContentWidth: CGFloat,
                           precomputeMs: Double) {
        guard let cv = collectionView, cv.window != nil, dataSource != nil else { return }
        // warm 统计先于补量（真反映预计算/预热命中率）。
        let warmCount = currentItems.filter {
            pool.cachedHeight(id: $0.id, width: targetContentWidth) != nil
        }.count
        var toFrames: [CGRect] = []
        toFrames.reserveCapacity(currentItems.count)
        var y = messageLayout.sectionInset.top
        for item in currentItems {
            // 池值直用；预计算快照外新增行（流式插入）同步补量一次。
            let height = pool.cachedHeight(id: item.id, width: targetContentWidth)
                ?? pool.remeasure(
                    id: item.id, width: targetContentWidth,
                    signature: "v\(contentVersions[item.id] ?? 0)",
                    makeContent: { [weak self] in
                        guard let self else { return AnyView(Color.clear) }
                        return self.makeNodeContent(item, reportsHeight: false)
                    })
            toFrames.append(CGRect(x: messageLayout.sectionInset.left, y: y,
                                   width: targetContentWidth, height: height))
            y += height + messageLayout.lineSpacing
        }
        let fromContentHeight = messageLayout.currentContentHeight
        messageLayout.beginRail(fromFrames: messageLayout.snapshotFrames(),
                                toFrames: toFrames)
        let followsBottomAtStart = followsBottom
        let anchor: (id: String, viewportY: CGFloat)? = followsBottomAtStart
            ? nil : captureTopAnchor()
        widthRail = WidthRail(
            targetViewportWidth: targetViewportWidth,
            startTime: CACurrentMediaTime(),
            duration: WOMotion.sidebarRailDuration,
            followsBottomAtStart: followsBottomAtStart,
            anchor: anchor,
            fromContentHeight: fromContentHeight)
        railDiagLastOff = cv.contentOffset.y - 1000
        WOFluidDiag.note(String(
            format: "RAIL-START(target=%.1f warm=%d/%d precomputeMs=%.1f)",
            targetViewportWidth, warmCount, currentItems.count, precomputeMs))
        startMotion()
    }

    /// 每帧 tick（advanceMotion 顶部 rail 分支独占该帧——收敛/生长不参与）。
    /// 曲线/时长读 Motion.swift 单源（R3，零硬编码副本）；offset 精确直写
    /// （R5：与混合帧同一套算术——确定性优先，不依赖 UIKit 本帧是否已应用
    /// 布局）；p≥1 自停落地（R7）。
    private func railTick(_ link: CADisplayLink, collectionView cv: UICollectionView) {
        guard let rail = widthRail else { return }
        let elapsed = max(0, link.targetTimestamp - rail.startTime)
        let p = min(1.0, elapsed / rail.duration)
        let eased = CGFloat(WORailCurve.progress(p))
        messageLayout.updateRailProgress(eased)
        messageLayout.invalidateLayout()
        // offset 直写：贴底=blendH 落点；非贴底=锚行 blend minY − viewportY。
        // 拖拽/惯性中不抢（正常情况 willBeginDragging 已走 cancelWidthRail，
        // 此为双保险）。
        if !cv.isDragging, !cv.isDecelerating {
            var target: CGFloat?
            if rail.followsBottomAtStart {
                target = CGFloat(WOMessageListSupport.bottomOffset(
                    contentHeight: Double(messageLayout.currentContentHeight),
                    viewportHeight: Double(cv.bounds.height),
                    topInset: Double(cv.adjustedContentInset.top),
                    bottomInset: Double(cv.adjustedContentInset.bottom)))
            } else if let anchor = rail.anchor,
                      let index = currentItems.firstIndex(where: { $0.id == anchor.id }) {
                let frames = messageLayout.snapshotFrames()
                if index < frames.count {
                    target = frames[index].minY - anchor.viewportY
                }
            }
            if target == nil, !rail.followsBottomAtStart {
                // 锚行被移除降级（R9-7）：按内容高差平移兜底。
                target = cv.contentOffset.y
                    + (messageLayout.currentContentHeight - rail.fromContentHeight)
            }
            if let target {
                cv.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                // 【流体诊断】RAIL-TICK（off 变 >0.5pt 才记，防刷屏）。
                if abs(target - railDiagLastOff) > 0.5 {
                    WOFluidDiag.record(String(format: "RAIL-TICK p=%.3f off=%.1f",
                                              p, target))
                    railDiagLastOff = target
                }
            }
        }
        if p >= 1 {
            finishWidthRail(writeOffset: true)
        }
    }

    /// 【rail R7】rail 落地（旧"一次切换"的重构落地件）：一次切真
    /// 布局，零修正零级联。无假切换面——无 0.55s 时长门、无去抖容差
    /// 对账、无 0.5pt 键漂移（落地宽=hint 显式值，非上报真值）。
    /// 无 pendingAnchorRestore（非贴底态末帧已钉锚位）。
    private func finishWidthRail(writeOffset: Bool) {
        guard let rail = widthRail else { return }
        widthRail = nil
        messageLayout.endRail()
        stableLayoutWidth = rail.targetViewportWidth
        messageLayout.layoutWidth = rail.targetViewportWidth
        // 探针：FLUID-SWITCH 标签保留连续性（rail 落地继续发）+ 缓冲冲刷。
        WOFluidDiag.note(String(
            format: "FLUID-SWITCH rail-target=%.1f dur=%.3f settleWindow=+1.0",
            rail.targetViewportWidth, CACurrentMediaTime() - rail.startTime))
        WOFluidDiag.dump(reason: "rail-end")
        initialStabilizingUntil = CACurrentMediaTime() + 1.0
        stabilizingSnapPending = rail.followsBottomAtStart
        messageLayout.invalidateLayout()
        // 结算窗 commit 计数（RAIL-END settleCount=窗内 COMMIT 数；窗满补记，
        // 代际令牌防 restart 链串窗）。
        railSettleCounting = true
        railSettleCommitCount = 0
        railSettleGeneration += 1
        let settleGeneration = railSettleGeneration
        let railDuration = CACurrentMediaTime() - rail.startTime
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in
            guard let self, self.railSettleCounting,
                  self.railSettleGeneration == settleGeneration else { return }
            self.railSettleCounting = false
            WOFluidDiag.note(String(
                format: "RAIL-END dur=%.3f settleCount=%d",
                railDuration, self.railSettleCommitCount))
        }
        // 贴底态收尾（既有 QA P2-1 修同款）：async 内先 layoutIfNeeded 确保
        // 新宽 prepare 跑完、contentSize 为新真值，再落 offset。
        if writeOffset, rail.followsBottomAtStart {
            DispatchQueue.main.async { [weak self] in
                guard let self, let cv = self.collectionView, cv.window != nil else { return }
                cv.layoutIfNeeded()
                cv.setContentOffset(CGPoint(x: 0, y: self.bottomOffset), animated: false)
            }
        }
        // rail tick 自停（R7：link.invalidate——startMotion 既有 guard 天然
        // 防重入，后续几何运动按需重启）。
        stopMotion()
    }

    /// 【rail R9-6】拖拽/惯性接管：跳终态落地（stable=目标、结算窗）但
    /// **不写 offset**（用户接管）；后续修正走结算窗直写。
    private func cancelWidthRail(userTakeover: Bool) {
        guard widthRail != nil else { return }
        _ = userTakeover // 语义标记（当前唯一调用点=用户拖拽接管）
        messageLayout.updateRailProgress(1)
        finishWidthRail(writeOffset: false)
    }

    // MARK: 【rail T05 P1】空闲预热（四契约宽度批量池预热）

    /// 契约候选内容宽（架构文档 §R2）：[viewport−56, viewport−280,
    /// viewport−456, viewport−680] − 32（insets 合计）。非法值/当前内容宽剔除。
    private func prewarmWidths(viewport: CGFloat) -> [CGFloat] {
        var widths: [CGFloat] = []
        let current = contentWidth()
        for delta in [CGFloat(56), 280, 456, 680] {
            let w = viewport - delta - 32
            guard w > 1, abs(w - current) > 0.5 else { continue }
            if !widths.contains(w) { widths.append(w) }
        }
        return widths
    }

    /// 空闲预热调度（0.6s 去抖；streaming 暂停、rail/precompute 在途让位）。
    private func schedulePrewarm() {
        guard phase != .streaming, widthRail == nil, railPrecompute == nil else { return }
        prewarmWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startPrewarm() }
        prewarmWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func startPrewarm() {
        guard let cv = collectionView, cv.window != nil, dataSource != nil,
              !currentItems.isEmpty else { return }
        guard widthRail == nil, railPrecompute == nil, phase != .streaming else { return }
        let widths = prewarmWidths(viewport: cv.bounds.width)
        guard !widths.isEmpty else { return }
        prewarmGen += 1
        runPrewarmSlice(generation: prewarmGen, widths: widths,
                        widthIndex: 0, cursor: 0, rowsWarmed: 0)
    }

    /// 预热切片（4ms 预算 + 8ms 间隙复用；cachedHeight 命中即跳过；批粒度
    /// PREWARM record；rail/precompute 抢占即作废——rail 几何优先）。
    private func runPrewarmSlice(generation: Int, widths: [CGFloat],
                                 widthIndex: Int, cursor: Int, rowsWarmed: Int) {
        guard generation == prewarmGen, widthIndex < widths.count else { return }
        guard collectionView?.window != nil, dataSource != nil else { return }
        guard widthRail == nil, railPrecompute == nil, phase != .streaming else { return }
        let width = widths[widthIndex]
        let sliceStart = CACurrentMediaTime()
        var index = cursor
        var warmed = rowsWarmed
        while index < currentItems.count,
              (CACurrentMediaTime() - sliceStart) < 0.004 {
            let item = currentItems[index]
            index += 1
            if pool.cachedHeight(id: item.id, width: width) != nil { continue }
            warmed += 1
            _ = pool.remeasure(
                id: item.id, width: width,
                signature: "v\(contentVersions[item.id] ?? 0)",
                makeContent: { [weak self] in
                    guard let self else { return AnyView(Color.clear) }
                    return self.makeNodeContent(item, reportsHeight: false)
                })
        }
        if index >= currentItems.count {
            WOFluidDiag.record(String(format: "PREWARM(w=%.1f rows=%d)", width, warmed))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
                guard let self, generation == self.prewarmGen else { return }
                self.runPrewarmSlice(generation: generation, widths: widths,
                                     widthIndex: widthIndex + 1, cursor: 0,
                                     rowsWarmed: 0)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
            guard let self, generation == self.prewarmGen else { return }
            self.runPrewarmSlice(generation: generation, widths: widths,
                                 widthIndex: widthIndex, cursor: index,
                                 rowsWarmed: warmed)
        }
    }

    private func runRemeasureSlice(generation: Int, index: Int) {
        guard generation == remeasureGen else {
            remeasureActive = false
            return
        }
        let sliceStart = CACurrentMediaTime()
        var cursor = index
        // 视图已拆（会话页离场）→ 队列清空退出（shutdown 已 bump 代际，
        // 本防御兜底 window 已 nil 的窗口期；【QA R1】逐条释放去重锚——
        // 瞬态离场不经 retain([]) 时该批行后续宽度变化不被锚挡）。
        guard let cv = collectionView, cv.window != nil else {
            for entry in remeasureQueue { pool.cancelPendingRemasure(id: entry.id) }
            remeasureQueue.removeAll()
            remeasureActive = false
            return
        }
        while cursor < remeasureQueue.count,
              (CACurrentMediaTime() - sliceStart) < 0.004 {
            let entry = remeasureQueue[cursor]
            cursor += 1
            // 【QA P1-3】丢弃路径（宽度又变/行已移除）必须释放去重锚——
            // 否则该行后续所有宽度变化永不重新入队（stale 自愈链失效）。
            guard entry.width == contentWidth(),
                  let item = currentItems.first(where: { $0.id == entry.id }) else {
                pool.cancelPendingRemasure(id: entry.id)
                continue
            }
            // 【重做批4·四修】可见行跳过离屏重测——显示 cell 在新宽度下
            // SwiftUI 自动重排并经回传桥回报真值（回传桥是显示环境的独家
            // 真值源）。离屏量高环境与显示环境 @State 独立（展开态行被离屏
            // 量出收起高度会把真值写回假值=宽度变化横跳源之一）；rekeyWidth
            // 把账本宽度对齐当前宽度（高度暂维持旧值，回传修正随之而来），
            // 并释放去重锚防 stale 积压。
            let visibleIDs = Set(cv.indexPathsForVisibleItems.compactMap { path -> String? in
                guard path.item < currentItems.count else { return nil }
                return currentItems[path.item].id
            })
            if visibleIDs.contains(entry.id) {
                pool.rekeyWidth(id: entry.id, width: contentWidth())
                continue
            }
            // 【QA P1-2】remeasure 已直写 cache——提交走 commitHeightChange
            // 绕过 updateHeight 死区门（同值恒 false 会吞掉上屏）；仅高度
            // 真变（含首知 previous=nil）才提交。
            let previous = pool.cachedHeight(id: entry.id, width: entry.width)
            let height = pool.remeasure(
                id: entry.id, width: entry.width,
                signature: "v\(contentVersions[entry.id] ?? 0)",
                makeContent: { [weak self] in
                    guard let self else { return AnyView(Color.clear) }
                    return self.makeNodeContent(item, reportsHeight: false)
                })
            if previous != height {
                // 【CI修50】宽度修正提交免动画（锚定恢复保视线稳定；逐条
                // 动画 = 真机右栏"内容上下抽搐"根因之一）。
                commitHeightChange(id: entry.id, height: height,
                                   collectionView: cv)
            }
        }
        remeasureQueue.removeFirst(cursor)
        if remeasureQueue.isEmpty {
            remeasureActive = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
            guard let self, self.remeasureActive, generation == self.remeasureGen else { return }
            self.runRemeasureSlice(generation: generation, index: 0)
        }
    }

    private func maybeExpandHistory() {
        guard let viewModel, viewModel.hasEarlierHistory,
              !historyLoading, !expanding,
              collectionView.bounds.width > 1,
              collectionView.contentOffset.y < 240 else { return }
        startHistoryExpansion()
    }

    private func startHistoryExpansion() {
        guard let viewModel else { return }
        expanding = true
        historyLoading = true
        // 锚点与基线先于头条 loading 态捕获（头条变高不影响锚定精度）。
        let anchor = captureTopAnchor()
        let oldContentHeight = collectionView.contentSize.height
        let generation = expansionGeneration
        let bounds = WOMessageListSupport.historyWindowBounds(
            total: nodes.count, start: viewModel.historyWindowStart,
            pageSize: viewModel.historyPageSize)
        let width = contentWidth()
        sync() // 头条 loading 态上屏（快照级 apply，窗口未动）

        var cursor = bounds.expandedStart
        let target = viewModel.historyWindowStart
        // 4ms 预算切片量高（lody prepareHistorySlice 同参：单轮超预算至少
        // 一条防饿死；切片间隔 8ms 让出主线程——33Hz live 更新不被阻塞）。
        // 纯函数镜像 = WOMessageListSupport.measureSlice（单测断言预算边界，
        // 本处为真实时钟形态）。
        func slice() {
            guard generation == expansionGeneration, expanding else { return }
            let sliceStart = CACurrentMediaTime()
            repeat {
                guard cursor < target, cursor < nodes.count else { break }
                measureNode(nodes[cursor], width: width)
                cursor += 1
            } while cursor < target && (CACurrentMediaTime() - sliceStart) < 0.004
            if cursor < target {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.008,
                                              execute: slice)
            } else {
                finishHistoryExpansion(expandedStart: bounds.expandedStart,
                                       anchor: anchor,
                                       oldContentHeight: oldContentHeight,
                                       generation: generation)
            }
        }
        slice()
    }

    private func finishHistoryExpansion(expandedStart: Int,
                                        anchor: (id: String, viewportY: CGFloat)?,
                                        oldContentHeight: CGFloat,
                                        generation: Int) {
        guard generation == expansionGeneration, let viewModel else {
            expanding = false
            historyLoading = false
            return
        }
        historyLoading = false
        viewModel.commitHistoryWindowExpansion(to: expandedStart)
        let restore = AnchorRestore(anchor: anchor,
                                    oldContentHeight: oldContentHeight)
        if applyInFlight {
            // 【CI修50】在途 apply：锚定寄存，落地后入位（防旧帧提前消费）。
            deferredExpansionAnchor = restore
        } else {
            pendingAnchorRestore = restore
        }
        expanding = false
        // 【重做批3 · 验证记录 R1】扩窗最终提交加滚动停止门（lody
        // historyScrollIsMoving 同款：滚动中快照不落地，防 didScroll→sync→
        // apply 重入链与滚动中重排跳位；量高已入库，静止后一次 sync 全量
        // 命中缓存零量高）。补发点 = didEndDragging(!decelerate) /
        // didEndDecelerating / didEndScrollingAnimation。
        if collectionView.isTracking || collectionView.isDecelerating {
            scrollEndExpansionPending = true
        } else {
            sync() // 扩窗后的新窗口快照（量高已入库——prepare 全缓存命中）
        }
    }

    /// 首可见气泡锚点（元条目跳过——历史头扩窗后可能消失）。
    private func captureTopAnchor() -> (id: String, viewportY: CGFloat)? {
        guard !currentItems.isEmpty else { return nil }
        let visible = collectionView.indexPathsForVisibleItems
            .sorted { $0.item < $1.item }
        for indexPath in visible {
            guard indexPath.item < currentItems.count else { continue }
            let id = currentItems[indexPath.item].id
            guard !isMetaID(id) else { continue }
            if let attrs = collectionView.collectionViewLayout
                .layoutAttributesForItem(at: indexPath) {
                return (id, attrs.frame.minY - collectionView.contentOffset.y)
            }
        }
        return nil
    }

    private func isMetaID(_ id: String) -> Bool {
        id == WOMessageListSupport.historyItemID
            || id == WOMessageListSupport.loadingItemID
            || id == WOMessageListSupport.beamItemID
            || id == WOMessageListSupport.failedItemID
    }

    private func restoreTopAnchor(_ restore: AnchorRestore) {
        if let anchor = restore.anchor,
           let index = currentItems.firstIndex(where: { $0.id == anchor.id }),
           let attrs = collectionView.collectionViewLayout
               .layoutAttributesForItem(at: IndexPath(item: index, section: 0)) {
            // lody restoreAnchor 语义：锚点视口位不漂移。此处为扩窗一次性
            // 校准直写（lody :337-344 同型直写）——「贴底唯一执行点」红线
            // 针对 layout pass 与 display link 的双重贴底驱动，锚定恢复是
            // 扩窗专用路径，不在其列（豁免依据=lody 实码同构）。
            // 【流体诊断】锚定恢复执行探针（低频 note 必落盘；纯记录）。
            WOFluidDiag.note(String(format: "ANCHOR-RESTORE id=%@ off=%.1f -> %.1f",
                                    anchor.id, collectionView.contentOffset.y,
                                    attrs.frame.minY - anchor.viewportY))
            let targetY = attrs.frame.minY - anchor.viewportY
            // 【rail T04 #12】300pt 保险丝随旧 trySwitch 收尾路径退役——唯一
            // true 来源已死；扩窗路径（不钳制）语义不变：上方插入内容的大
            // 位移是正常语义。
            collectionView.contentOffset.y = targetY
        } else {
            // 锚点被换出（如视口内只剩历史头）：按内容高度差兜底平移。
            // 【流体诊断】锚定兜底探针（低频 note 必落盘；纯记录）。
            WOFluidDiag.note(String(format: "ANCHOR-FALLBACK dh=%.1f",
                                    collectionView.contentSize.height
                                        - restore.oldContentHeight))
            collectionView.contentOffset.y +=
                collectionView.contentSize.height - restore.oldContentHeight
        }
    }

    // MARK: 跟随/滚动收口（批 2 件 1 重构：贴底唯一执行点 = display link）

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 【rail T04】旧宽度巡检/归位/双排版/逐帧补偿四块随流体重排机器退役
        //（R8-#6/#7/#8）——rail 期布局由 messageLayout 混合帧 + railTick
        // offset 直写承担（确定性插值，无逐帧试探）。
        // 【修复3-c】推迟的首帧定位每帧重试（几何就绪即消耗；本 pass 布局
        // 刚跑过 → 不强制 layoutIfNeeded）。
        tryInitialPositioning(forceLayout: false)
        // 【CI修49】stale 重测切片调度（rail/precompute 在途时 guard 早退）。
        drainStaleSweep()
        if let restore = pendingAnchorRestore {
            pendingAnchorRestore = nil
            restoreTopAnchor(restore)
            return
        }
        // 键盘弹出等诱发的 layout pass：不直接写 offset（单一驱动点红线），
        // 只唤醒 display link（距底 >0.5 且跟随态）——收敛由 tick 完成。
        // （rail 期天然不参与：motionLink 被 rail 分支独占。）
        // 【重做批6-R2 · 稳定期例外 2026-10-08】打开稳定期内直写钉底（用户
        // 拍板"打开会话直线呈现"=零可见运动）。
        if followsBottom, motionLink == nil, let cv = collectionView,
           cv.window != nil, abs(cv.contentOffset.y - bottomOffset) > 0.5 {
            if CACurrentMediaTime() < initialStabilizingUntil {
                cv.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: false)
            } else {
                startMotion()
            }
        }
        // 【修复3-e】稳定期结束兜底校准（一次性；用户已拖拽不动作）。
        settleSnapIfDue()
        updateBottomButton()
        // 【rail T05 P1】空闲预热调度（0.6s 去抖；streaming/rail 让位）。
        schedulePrewarm()
    }

    /// 贴底落点（lody bottomOffset :250-254 同型；adjustedContentInset 口径
    /// ——批 2 件 3 动态 inset 自动参与）。
    private var bottomOffset: Double {
        guard let cv = collectionView else { return 0 }
        return WOMessageListSupport.bottomOffset(
            contentHeight: Double(cv.contentSize.height),
            viewportHeight: Double(cv.bounds.height),
            topInset: Double(cv.adjustedContentInset.top),
            bottomInset: Double(cv.adjustedContentInset.bottom))
    }

    /// lody scrollToBottom :261-268 同型：拖拽/惯性中不抢；reduceMotion 或
    /// 未挂窗直接落位；距底 >0.5 才启动逐帧收敛。
    /// 【重做批6-R2 · 稳定期直写 2026-10-08】用户拍板"打开会话直线呈现"：
    /// 打开稳定期（首贴底起 2s）内贴底一律瞬写钉底（无收敛动画=零可见运
    /// 动）——稳定期残余修正（图片加载/兜底超时段落）经本函数与 layout
    /// pass 旁路时不可见。收敛动画只属于流式跟随与用户操作后的场景。
    private func scrollToBottom() {
        guard let cv = collectionView, !cv.isDragging, !cv.isDecelerating else { return }
        let bottom = bottomOffset
        if cv.window == nil || UIAccessibility.isReduceMotionEnabled {
            cv.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        } else if CACurrentMediaTime() < initialStabilizingUntil {
            cv.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        } else if abs(cv.contentOffset.y - bottom) > 0.5 {
            startMotion()
        }
    }

    /// lody startMotion :270-276 同型（.main + .common——滚动/追踪模式均响应）。
    private func startMotion() {
        guard motionLink == nil, collectionView?.window != nil else { return }
        let link = CADisplayLink(target: WOScrollMotionTarget(self),
                                 selector: #selector(WOScrollMotionTarget.tick(_:)))
        motionTime = CACurrentMediaTime()
        motionLink = link
        link.add(to: .main, forMode: .common)
    }

    private func stopMotion() {
        motionLink?.invalidate()
        motionLink = nil
    }

    /// lody advanceMotion :278-326 的万我贴底段：时间收敛向 bottomOffset
    ///（response 0.10 + 亚像素 minimumStep）；拖拽/惯性中不驱动（tracking
    /// 判定）；自停条件 = 非跟随或已收敛到半像素内。
    @objc func advanceMotion(_ link: CADisplayLink) {
        guard let cv = collectionView, cv.window != nil else {
            // 【rail R9-10】离场期 rail 强制收口（不写 offset）+ link 停摆。
            if widthRail != nil { finishWidthRail(writeOffset: false) }
            stopMotion()
            return
        }
        // 【rail R3】rail 分支独占该帧（rail tick 与贴底收敛/生长插值同属
        // "几何运动单源"，一条 link 一套 invalidate 生命周期——rail 在途时
        // 收敛/生长逻辑不参与；rail tick 自身在 p≥1 时 invalidate 自停，
        // startMotion 既有 guard（motionLink==nil）天然防重入）。
        if widthRail != nil {
            railTick(link, collectionView: cv)
            return
        }
        let elapsed = min(1.0 / 30, max(0, link.targetTimestamp - motionTime))
        motionTime = link.targetTimestamp
        // 【重做批6 · 同出生长 tick】先插值（过期清理）→ invalidate → 贴底
        // 收敛同 tick（单运动源：生长与贴底同一 display link 同一帧，几何
        // 连续无叠加冲突）。生长完成行自动落回池值（growthDisplayHeight nil）。
        // 【2026-10-09 披露收尾】披露收起动画到期的行：若视口恰好落回贴底
        // （内容收缩被 UIKit clamp 回贴底），恢复跟随——后续流式钉底语义
        // 不断（liveStreaming 判定依赖 followsBottom）。
        var expiredDisclosureCollapse = false
        if !growthAnims.isEmpty {
            let now = CACurrentMediaTime()
            growthAnims = growthAnims.filter { _, anim in
                if now < anim.start + anim.duration { return true }
                if anim.kind == .disclosure, anim.to < anim.from {
                    expiredDisclosureCollapse = true
                }
                return false
            }
            messageLayout.invalidateLayout()
        }
        // 【2026-10-09 披露单时钟】披露动画在途 → 暂停贴底收敛：收敛的
        // setContentOffset 是唯一能拖走表头的运动（布局自上而下累计不动
        // origin），与"表头钉死"语义冲突；同出生长（.entrance）不受影响。
        // 【流体重排】fluid 期同样暂停（钉底由 viewDidLayoutSubviews 逐帧
        // 直写承担，收敛链 0.10s 追移动目标会滞后打架）。
        let disclosureActive = growthAnims.values.contains { $0.kind == .disclosure }
        let bottom = bottomOffset
        let tracking = followsBottom && !cv.isDragging && !cv.isDecelerating
            && !disclosureActive
        if tracking {
            let scale = cv.traitCollection.displayScale > 0
                ? Double(cv.traitCollection.displayScale) : 3.0
            let y = UIAccessibility.isReduceMotionEnabled
                ? CGFloat(bottom)
                : CGFloat(WOMessageListSupport.advanceHeight(
                    current: cv.contentOffset.y, toward: bottom,
                    elapsed: elapsed, response: 0.10,
                    minimumStep: 1.0 / scale))
            cv.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
        updateBottomButton()
        if expiredDisclosureCollapse,
           abs(cv.contentOffset.y - bottom) <= 1 {
            followsBottom = true
            updateBottomButton()
        }
        // lody 自停条件 :322-325 + 生长队列未清空不停车（同出动画几何驱动
        // 需要 link 存活；生长完成后回归贴底收敛自停判定）。
        if growthAnims.isEmpty, !tracking || abs(cv.contentOffset.y - bottom) <= 0.5 {
            link.invalidate()
            motionLink = nil
        }
    }

    /// display link 弱引用靶（lody ChatMotionTarget 同型——CADisplayLink
    /// target 强引用会造成 core 泄漏，必须经弱靶中转）。
    @MainActor
    private final class WOScrollMotionTarget: NSObject {
        weak var core: WOMessageListCore?
        init(_ core: WOMessageListCore) { self.core = core }
        @objc func tick(_ link: CADisplayLink) {
            guard let core else { link.invalidate(); return }
            core.advanceMotion(link)
        }
    }

    /// 生命周期铁律收口（representable dismantle 调）。
    func shutdown() {
        stopMotion()
        growthAnims = [:] // 【重做批6】拆解清生长队列
        // 【rail R9-10】拆解清 rail 状态（防跨会话残留；gen 作废在途切片）。
        widthRail = nil
        railPrecompute = nil
        railPrecomputeGen += 1
        activeHintWidth = 0
        railSettleCounting = false
        if messageLayout?.isRailActive == true { messageLayout?.endRail() }
        // 【rail T05】预热作废。
        prewarmGen += 1
        prewarmWorkItem?.cancel()
        prewarmWorkItem = nil
        expansionGeneration += 1 // 在途量高切片作废
        // 【重做批3 · R1】滚动停止门待办一并清（QA P2-1：dismantle 后 didEnd
        // 系列仍可能触发，防在已拆解 core 上空跑 sync）。
        scrollEndExpansionPending = false
        // 【CI修49】stale 重测切片作废。
        remeasureGen += 1
        remeasureQueue.removeAll()
        remeasureActive = false
    }

    deinit {
        // @MainActor 存储属性在 deinit 的直接存储访问（minimal 并发下合法）。
        motionLink?.invalidate()
        // 【批4 真机修复】block-based observer 显式移除。
        if let markdownParsedObserver {
            NotificationCenter.default.removeObserver(markdownParsedObserver)
        }
    }

    // MARK: 批 2 件 3 让位（lody updateBottomInset :10-27 万我形态）

    /// composer 动态增量 → contentInset.bottom（与滚动位置解耦——只调 inset
    /// 不补偿 offset；scrollIndicator 同步；变更才写）。静态 sectionInset
    /// bottom 189（批 1 QA 判值）保留——两者分立：189=内容收尾几何（旧链
    /// spacer 语义），本 inset=composer 座位超基准（137）的动态部分；键盘
    /// 维持 SwiftUI 避让（视口缩短），不双补。
    private func updateBottomInset(_ allowance: CGFloat) {
        guard let cv = collectionView, appliedBottomInset != allowance else { return }
        appliedBottomInset = allowance
        cv.contentInset.bottom = allowance
        cv.verticalScrollIndicatorInsets.bottom = allowance
        // 让位变化 → 贴底落点变 → 跟随态下唤醒收敛（不直接写 offset）。
        if followsBottom {
            scrollToBottom()
        }
    }

    // MARK: 批 2 件 2 回底按钮（UIKit 内层=lody overlay 同构）

    /// 右下悬浮回底钮：距底 > resumeDistance(80) 且非跟随态现形（lody
    /// updateBottomButton :256-259 判定同型）；点击 = 恢复跟随 + 贴底。
    /// 【CI修49 视觉改造（用户规格）】：白底+阴影（旧 blur 灰底太弱）、
    /// 54pt（1.5×36）、左移 48（≈两个字间距）、高度抬到 dock 上方
    /// （dockBaseline 137+20；键盘避让=SwiftUI 缩视口自动跟随）。
    private func installBackToBottomButton(on container: UIView) {
        let disc = UIView()
        disc.translatesAutoresizingMaskIntoConstraints = false
        disc.backgroundColor = .systemBackground
        disc.layer.cornerRadius = 27
        disc.layer.shadowColor = UIColor.black.cgColor
        disc.layer.shadowOpacity = 0.16
        disc.layer.shadowRadius = 10
        disc.layer.shadowOffset = CGSize(width: 0, height: 4)
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "arrow.down",
                                withConfiguration: UIImage.SymbolConfiguration(
                                    pointSize: 20, weight: .medium)),
                        for: .normal)
        button.tintColor = .label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "回到最新消息"
        button.addTarget(self, action: #selector(backToBottomTapped), for: .touchUpInside)
        disc.addSubview(button)
        container.addSubview(disc)
        NSLayoutConstraint.activate([
            disc.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -48),
            disc.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor,
                                         constant: -(WOMessageListSupport.dockBaselineHeight + 20)),
            disc.widthAnchor.constraint(equalToConstant: 54),
            disc.heightAnchor.constraint(equalToConstant: 54),
            button.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
        ])
        disc.alpha = 0
        disc.isHidden = true
        backToBottomShown = false
        backToBottomButton = button
        backToBottomContainer = disc
    }

    @objc private func backToBottomTapped() {
        followsBottom = true
        scrollToBottom()
        updateBottomButton()
    }

    /// lody updateBottomButton 判定（:256-259 同型）：非跟随 && 距底 >
    /// resumeDistance(80) → 现形（0.2s 淡入）。
    /// 【批2-QA D1 修】显式状态机：visible 与 backToBottomShown 翻转才动
    /// 动画（消除未现形时滚动 tick 空跑 animate）；hide 路径独立判定——
    /// 完成回调用**当下状态位**（非闭包捕获的 visible）决定 isHidden，防
    /// hide 动画中途被重新 show 的竞态藏掉重现场。全环推演见回报。
    private func updateBottomButton() {
        guard let container = backToBottomContainer, let cv = collectionView else { return }
        let visible = !followsBottom
            && bottomOffset - Double(cv.contentOffset.y)
                > WOMessageListSupport.resumeDistance
        guard visible != backToBottomShown else { return }
        backToBottomShown = visible
        if visible {
            container.isHidden = false
            UIView.animate(withDuration: 0.2, animations: {
                container.alpha = 1
            })
        } else {
            UIView.animate(withDuration: 0.2, animations: {
                container.alpha = 0
            }, completion: { [weak self] _ in
                guard let self, !self.backToBottomShown else { return }
                container.isHidden = true
            })
        }
    }

    // MARK: 批 2 件 4 离屏冻结（lody updateDeferredStreams 万我形态）

    /// 评估 live 行（live-r-N/live-t-N）与视口迟滞带的关系：滚出 ±80（未冻）
    /// → 冻结（sync 跳过 reconfigure，行高随版本冻结）；回带（±160 迟滞）→
    /// 解冻集（sync 一次性追平到最新内容并重测高度）。只冻显示不冻推进——
    /// VM typeCursor/finishSettling 语义零耦合（红线）。
    /// lody 差异：万我不需要 stream.finish/准备队列——推进面在 VM 缓冲，
    /// 显示面只丢帧不丢内容。
    private func updateFrozenStreams(excluding: Set<String> = []) -> Set<String> {
        var unfrozen: Set<String> = []
        guard let cv = collectionView, cv.window != nil, !currentItems.isEmpty else {
            return unfrozen
        }
        let viewport = cv.bounds.inset(by: UIEdgeInsets(
            top: cv.adjustedContentInset.top, left: 0,
            bottom: cv.adjustedContentInset.bottom, right: 0))
        for (index, item) in currentItems.enumerated() {
            guard item.id.hasPrefix("live-"), case .bubble = item.kind else { continue }
            // 【批2-QA D2 修】外层评估（scrollViewDidScroll）已解冻的行本轮
            // 跳过再评估——保护 160 迟滞带一次性生效（嵌套评估打穿 = 抖动）。
            guard !excluding.contains(item.id) else { continue }
            let alreadyFrozen = frozenLiveIDs.contains(item.id)
            // 迟滞带（lody :200：未冻 80 / 已冻 160——防边界 churn）。
            let margin = WOMessageListSupport.freezeMargin(alreadyFrozen: alreadyFrozen)
            guard let attrs = cv.collectionViewLayout.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0)) else { continue }
            let offscreen = WOMessageListSupport.isOffscreen(
                frame: attrs.frame, viewport: viewport, margin: margin)
            // lody :208 同条件：跟随中恒不冻（live 行恒在视口内）。
            if !followsBottom, offscreen {
                frozenLiveIDs.insert(item.id)
            } else if frozenLiveIDs.remove(item.id) != nil {
                unfrozen.insert(item.id)
            }
        }
        // 已出数据集的冻结行清理（落盘帧 live 行消失）。
        let ids = Set(currentItems.map(\.id))
        frozenLiveIDs = frozenLiveIDs.filter { ids.contains($0) }
        return unfrozen
    }

    // MARK: 手势

    @objc private func handleBackgroundTap() {
        onBackgroundTap?()
    }
}

// MARK: - UIScrollViewDelegate（丝线 / 拖拽断开状态机 / 预取 / 冻结驱动）

/// 【批4 真机诊断】布局快照文件日志（Documents/list-diag.log，文件 App
/// 可见可分享；256KB 截半守护——WOEntryDiag 同款形态）+ UI 通道（lastDump
/// 静态持有，侧栏「列表诊断」sheet 直接展示——文件 App 取证不可靠时的
/// 主通道，用户截图/一键复制即可回传）。
enum WOLayoutDiag {
    static let logger = AppLogger(category: "LayoutDiag")
    private static let queue = DispatchQueue(label: "com.wanwo.layout-diag")
    /// 最近一次 dump 全文（主线程写——dumpLayoutSnapshot 调用域；侧栏
    /// sheet 打开时读取，无需刷新驱动）。
    static private(set) var lastDump: String?

    static func write(_ text: String) {
        lastDump = text
        logger.info("layout dump \(String(text.prefix(120)))")
        let line = "\(ISO8601DateFormatter().string(from: Date())) | \(text)\n"
        queue.async {
            let url = FileManager.default.urls(for: .documentDirectory,
                                               in: .userDomainMask)[0]
                .appendingPathComponent("list-diag.log")
            let fm = FileManager.default
            guard let data = line.data(using: .utf8) else { return }
            if fm.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEnd()) ?? 0
                if size > 256 * 1024 {
                    try? handle.truncate(atOffset: size / 2)
                    _ = try? handle.seek(toOffset: size / 2)
                }
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

extension WOMessageListCore: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 顶栏丝线（原探针链等效：scrollTop > 4）。
        onHeadScrolled?(scrollView.contentOffset.y > 4)
        // 批 2 件 2：回底按钮现形判定 + 冻结回带评估（无内容变化的滚动帧）。
        updateBottomButton()
        // 【批4 真机诊断】拖拽/惯性中的动态快照（限频 1.5s）——静止帧 dump
        // 全对但用户体感"拖拽中偏移"，补齐动态盲区取证。
        if scrollView.isTracking || scrollView.isDecelerating {
            dumpLayoutSnapshot(reason: "dragging")
        }
        if !frozenLiveIDs.isEmpty || phase == .streaming {
            let pendingUnfreeze = updateFrozenStreams()
            if !pendingUnfreeze.isEmpty {
                // 滚动驱动的追平（33Hz 无内容变化帧也能回带）——解冻集透传，
                // sync 内部评估排除（D2：不打穿迟滞带）。
                sync(forceUnfreeze: pendingUnfreeze)
            }
        }
        // 顶部预取扩窗。
        maybeExpandHistory()
    }

    /// 【批2-QA D5 修】状态栏滚顶断开跟随（lody scrollViewShouldScrollToTop
    /// :160-165 同义）——窄路径（状态栏点按）但"绝不 yank"必须覆盖：滚顶是
    /// 用户主动去历史区，跟随中 display link 若在跑会把滚顶拽回底部。
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        guard scrollView === collectionView else { return true }
        followsBottom = false
        updateBottomButton()
        return true
    }

    /// lody pauseTracking :179-185 同语义：手指一碰即断（绝不 yank）。
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        followsBottom = false
        // 【rail R9-6】rail 期用户拖拽 = 接管滚动位置：跳终态落地（stable=
        // 目标、结算窗）但不写 offset——用户刚滚到的位置不被 yank；后续
        // 修正走结算窗直写。
        cancelWidthRail(userTakeover: true)
        updateBottomButton()
    }

    /// lody scrollViewDidEndDragging(:231-235)/DidEndDecelerating(:237-241)
    /// 同语义：松手/惯性停 → 距底 ≤1pt 才恢复跟随（回底恢复唯一判定点）。
    /// 【重做批3 · R1】滚动静止 = 扩窗提交补发点（scrollEndExpansionPending）。
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        flushScrollEndExpansion()
        resumeTrackingAtBottom()
        // 【批4 真机诊断】滚动静止布局快照（空白洞/偏移取证）。
        dumpLayoutSnapshot(reason: "scroll-end")
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        flushScrollEndExpansion()
        resumeTrackingAtBottom()
        dumpLayoutSnapshot(reason: "scroll-end")
    }

    /// 惯性被触摸截断（didEndDecelerating 不来的路径）也要补发。
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        flushScrollEndExpansion()
    }

    /// 【重做批3 · R1】扩窗提交补发（滚动静止一次 sync 全量命中缓存）。
    private func flushScrollEndExpansion() {
        guard scrollEndExpansionPending else { return }
        scrollEndExpansionPending = false
        sync()
    }

    /// lody resumeTrackingAtBottom :243-248 同型。
    private func resumeTrackingAtBottom() {
        guard WOMessageListSupport.shouldResumeFollowing(
            bottomOffset: bottomOffset, offsetY: collectionView.contentOffset.y)
        else { return }
        followsBottom = true
        scrollToBottom()
        updateBottomButton()
    }
}

// MARK: - UIGestureRecognizerDelegate（与 SwiftUI 内部手势同时识别）

extension WOMessageListCore: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - WOMessageListLayoutDelegate（高度问池）

extension WOMessageListCore: WOMessageListLayoutDelegate {
    func listLayout(_ layout: WOMessageListLayout,
                    heightForItemAt indexPath: IndexPath,
                    width: CGFloat) -> CGFloat {
        guard indexPath.item < currentItems.count else { return 44 }
        let item = currentItems[indexPath.item]
        // 【重做批6 · 同出生长覆盖】生长动画中的行显示插值中间值（从 0 长到
        // 池真值——物理顶开旧行+内容淡入=参考件同出）。
        if let growing = growthDisplayHeight(id: item.id) { return growing }
        // 【rail T04 #9】旧 fluid 分支（同宽池直读/回传真值/宽度比近似/
        // 纯量高兜底）随流体重排机器退役——rail 期本函数不可达
        //（prepare 早退零 delegate 询问）。常规三级缓存路径不变。
        // 三级缓存：签名/宽度未变 → 高度直读；变 → 池视图重测（量高与显示
        // 同一内容装配缝——identity 锚 .id(item.id)；CI修48：装配统一走
        // makeNodeContent，量高路径 reportsHeight=false 不挂上报桥）。
        return pool.height(id: item.id, width: width,
                           signature: "v\(contentVersions[item.id] ?? 0)",
                           makeContent: { [weak self] in
                               guard let self else { return AnyView(Color.clear) }
                               // QA P1-1：量高路径不挂上报桥（离屏 host 无上报面）。
                               return self.makeNodeContent(item, reportsHeight: false)
                           })
    }
}
