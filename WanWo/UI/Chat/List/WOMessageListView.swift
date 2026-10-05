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

// MARK: - Representable（WOChatView 宿主面）

struct WOMessageListView: UIViewControllerRepresentable {
    /// 列表数据宿主（窗口状态读写缝）。
    let viewModel: ChatViewModel
    /// 单一渲染数据源（WOChatView body 求值 displayNodes 传入——33Hz live
    /// 变化驱动 SwiftUI 重求值 → updateUIView → core.sync）。
    let nodes: [ConversationProjector.DisplayNode]
    let phase: ChatViewModel.Phase
    let sessionId: String
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
                         onImagePreview: onImagePreview)
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

    override func prepare() {
        super.prepare()
        guard let collectionView, collectionView.numberOfSections > 0 else {
            itemFrames = []
            contentHeight = sectionInset.top + sectionInset.bottom
            return
        }
        let width = collectionView.bounds.width - sectionInset.left - sectionInset.right
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
        // 宽度变化（旋转/分栏/键盘挤压）才整体失效；高度变化不动。
        collectionView.map { $0.bounds.size.width != newBounds.size.width } ?? false
    }
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
        phase: .loading, justEndedStreaming: false, settledBubbleIDs: [],
        sessionId: "", attachmentStore: nil, ledger: WOEntryLedger(),
        onImagePreview: { _ in })

    // MARK: 件 1 同步簿记

    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!
    private var messageLayout: WOMessageListLayout!
    private var collectionView: UICollectionView!
    /// 最近一次 sync 的条目（Equatable 比对 + 锚定索引）。
    private var currentItems: [WOMListNode] = []
    /// id → 最近入库条目（变更检测；33Hz no-op 守卫的比对基线）。
    private var syncedNodes: [String: WOMListNode] = [:]
    /// id → 内容版本（内容变 → bump → 池高度签名失效 → 重测）。
    private var contentVersions: [String: Int] = [:]
    private var lastPhase: ChatViewModel.Phase?

    // MARK: 件 2/批 2 簿记

    private var historyLoading = false
    private var expanding = false
    /// 扩窗代际令牌（会话切换/视图拆解使在途切片作废）。
    private var expansionGeneration = 0

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

    // MARK: 生命周期

    override func loadView() {
        let layout = WOMessageListLayout()
        messageLayout = layout
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
    }

    // MARK: 输入入口（representable updateUIViewController →）

    func applyUpdate(viewModel: ChatViewModel,
                     nodes: [ConversationProjector.DisplayNode],
                     phase: ChatViewModel.Phase,
                     sessionId: String,
                     bottomAllowance: CGFloat,
                     onBackgroundTap: @escaping () -> Void,
                     onHeadScrolled: @escaping (Bool) -> Void,
                     onImagePreview: @escaping (ImageAttachmentRef) -> Void) {
        loadViewIfNeeded() // updateUIView 早于视图挂载的防御（dataSource 就位）
        bindIfNeeded(viewModel)
        self.nodes = nodes
        self.phase = phase
        self.sessionId = sessionId
        self.onBackgroundTap = onBackgroundTap
        self.onHeadScrolled = onHeadScrolled
        self.onImagePreview = onImagePreview
        // 批 2 件 3：composer 动态让位（lody updateBottomInset 语义——变更
        // 才写、与滚动位置解耦）。
        updateBottomInset(bottomAllowance)
        sync()
    }

    /// 会话切换（viewModel 身份变）→ 全量重置（池/账本/簿记/快照）。
    private func bindIfNeeded(_ newViewModel: ChatViewModel) {
        guard viewModel !== newViewModel else { return }
        viewModel = newViewModel
        // 生命周期铁律（会话切换路径）：display link 停 + 在途量高切片作废。
        stopMotion()
        expansionGeneration += 1
        pool.retain([])
        ledger.reset()
        syncedNodes = [:]
        contentVersions = [:]
        currentItems = []
        lastPhase = nil
        historyLoading = false
        expanding = false
        followsBottom = true
        pendingAnchorRestore = nil
        frozenLiveIDs = []
        // 批 2 件 2：按钮状态位复位（会话切换不残留隐藏中断态）。
        backToBottomShown = false
        if let container = backToBottomContainer {
            container.isHidden = true
            container.alpha = 0
        }
        if dataSource != nil {
            var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
            snapshot.appendSections([.main])
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    // MARK: 件 1 同步（updateUIView 33Hz 热路径）

    private func sync(forceUnfreeze: Set<String> = []) {
        guard let viewModel, dataSource != nil else { return }
        seedLedgerIfNeeded(viewModel)
        // 批 2 件 4：离屏冻结评估先行（跟随中恒不冻；回带解冻集在变更检测
        // 中强制追平）。滚动驱动的回带（无内容变化帧）另经 scrollViewDid
        // Scroll 调本评估——【批2-QA D2 修】解冻集经 forceUnfreeze 透传并在
        // 内部评估中排除：解冻后立即按 80 带再评估会把刚解冻行（d>80）秒回
        // 冻，打穿 160 迟滞带（抖动根源）；透传行本帧跳过再评估，下一滚动帧
        // 才按 80 带参与。
        let unfrozen = updateFrozenStreams(excluding: forceUnfreeze)
            .union(forceUnfreeze)
        let (slice, _) = WOMessageListSupport.windowedSlice(
            nodes: nodes, start: viewModel.historyWindowStart)
        let items = WOMessageListSupport.flatten(
            nodes: slice, phase: phase,
            hasEarlierHistory: viewModel.hasEarlierHistory,
            historyLoading: historyLoading)
        context = makeContext()

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
        applySnapshot(snapshot, changedCount: changed.count)
        // 行移出数据集 → 池/高度随行清理。扩窗量高进行中跳过——被测节点
        // 尚未入库，不可清（提交后 sync 自然覆盖）。
        if !expanding {
            pool.retain(itemIDs)
        }
    }

    /// apply 收口（探针 + 贴底触发：批 2 件 1——apply 完成后内容可能增长，
    /// followsBottom 时经 scrollToBottom 唤醒/维持 display link 收敛贴底）。
    private func applySnapshot(_ snapshot: NSDiffableDataSourceSnapshot<Section, String>,
                               changedCount: Int) {
        let startTime = CACurrentMediaTime()
        let itemCount = snapshot.itemIdentifiers.count
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            WOChatProbe.shared.record(
                durationMs: (CACurrentMediaTime() - startTime) * 1000,
                itemCount: itemCount,
                reconfigureCount: changedCount,
                poolCount: self.pool.poolCount)
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

    /// 入场账本补种（原 seedEntry + onChange(phase) 补种语义逐帧对齐）：
    /// ①首个非 loading 相位帧 seedAll（历史/恢复静默呈现）；②相位变化落到
    /// 非 .streaming → 回合尾新增节点即时呈现不播动画。
    /// 只在相位变化帧补种（非每帧）——idle 期新入场节点（乐观 u-pending）
    /// 不被误种，mInR 动画保持。
    private func seedLedgerIfNeeded(_ viewModel: ChatViewModel) {
        guard phase != lastPhase else { return }
        if !ledger.seeded, phase != .loading {
            ledger.seedAll(viewModel.bubbles.map(\.id))
            ledger.markSeeded()
        }
        if phase != .streaming {
            ledger.seedAll(viewModel.bubbles.map(\.id))
        }
        lastPhase = phase
    }

    private func makeContext() -> WONodeContext {
        WONodeContext(
            phase: phase,
            justEndedStreaming: viewModel?.justEndedStreaming ?? false,
            settledBubbleIDs: viewModel?.settledBubbleIDs ?? [],
            sessionId: sessionId,
            attachmentStore: viewModel?.attachmentStore,
            ledger: ledger,
            onImagePreview: { [weak self] ref in self?.onImagePreview?(ref) })
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
    /// 非跟随态先抓视口锚（复用扩窗锚定机制——高度修正引发的 frame 重排
    /// 不漂移用户视线）；【QA P2-2】expanding 中让位（不覆写扩窗锚）；
    /// 跟随态贴底收敛自会追新。
    func nodeHeightChanged(id: String, height: CGFloat) {
        guard let cv = collectionView, cv.window != nil else { return }
        let signature = contentVersions[id].map { "v\($0)" }
        guard pool.updateHeight(id: id, width: contentWidth(), height: height,
                                signature: signature) else { return }
        if !followsBottom, !expanding {
            pendingAnchorRestore = AnchorRestore(
                anchor: captureTopAnchor(),
                oldContentHeight: cv.contentSize.height)
        }
        messageLayout.invalidateLayout()
        if followsBottom {
            scrollToBottom()
        }
    }

    // MARK: 件 2 高度问池（layout delegate）

    private func contentWidth() -> CGFloat {
        collectionView.bounds.width - messageLayout.sectionInset.left
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
        pendingAnchorRestore = AnchorRestore(anchor: anchor,
                                             oldContentHeight: oldContentHeight)
        expanding = false
        sync() // 扩窗后的新窗口快照（量高已入库——prepare 全缓存命中）
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
            collectionView.contentOffset.y = attrs.frame.minY - anchor.viewportY
        } else {
            // 锚点被换出（如视口内只剩历史头）：按内容高度差兜底平移。
            collectionView.contentOffset.y +=
                collectionView.contentSize.height - restore.oldContentHeight
        }
    }

    // MARK: 跟随/滚动收口（批 2 件 1 重构：贴底唯一执行点 = display link）

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let restore = pendingAnchorRestore {
            pendingAnchorRestore = nil
            restoreTopAnchor(restore)
            return
        }
        // 键盘弹出等诱发的 layout pass：不直接写 offset（单一驱动点红线），
        // 只唤醒 display link（距底 >0.5 且跟随态）——收敛由 tick 完成。
        if followsBottom, motionLink == nil, let cv = collectionView,
           cv.window != nil, abs(cv.contentOffset.y - bottomOffset) > 0.5 {
            startMotion()
        }
        updateBottomButton()
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
    private func scrollToBottom() {
        guard let cv = collectionView, !cv.isDragging, !cv.isDecelerating else { return }
        let bottom = bottomOffset
        if cv.window == nil || UIAccessibility.isReduceMotionEnabled {
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
            stopMotion()
            return
        }
        let elapsed = min(1.0 / 30, max(0, link.targetTimestamp - motionTime))
        motionTime = link.targetTimestamp
        let bottom = bottomOffset
        let tracking = followsBottom && !cv.isDragging && !cv.isDecelerating
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
        // lody 自停条件 :322-325（万我无行高插值队列，条件简化为跟随/收敛位）。
        if !tracking || abs(cv.contentOffset.y - bottom) <= 0.5 {
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
        expansionGeneration += 1 // 在途量高切片作废
    }

    deinit {
        // @MainActor 存储属性在 deinit 的直接存储访问（minimal 并发下合法）。
        motionLink?.invalidate()
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
    private func installBackToBottomButton(on container: UIView) {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 18
        blur.clipsToBounds = true
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "arrow.down"),
                        for: .normal)
        button.tintColor = .secondaryLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "回到最新消息"
        button.addTarget(self, action: #selector(backToBottomTapped), for: .touchUpInside)
        blur.contentView.addSubview(button)
        container.addSubview(blur)
        NSLayoutConstraint.activate([
            blur.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            blur.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            blur.widthAnchor.constraint(equalToConstant: 36),
            blur.heightAnchor.constraint(equalToConstant: 36),
            button.centerXAnchor.constraint(equalTo: blur.contentView.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: blur.contentView.centerYAnchor),
        ])
        blur.alpha = 0
        blur.isHidden = true
        backToBottomShown = false
        backToBottomButton = button
        backToBottomContainer = blur
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

extension WOMessageListCore: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 顶栏丝线（原探针链等效：scrollTop > 4）。
        onHeadScrolled?(scrollView.contentOffset.y > 4)
        // 批 2 件 2：回底按钮现形判定 + 冻结回带评估（无内容变化的滚动帧）。
        updateBottomButton()
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
        updateBottomButton()
    }

    /// lody scrollViewDidEndDragging(:231-235)/DidEndDecelerating(:237-241)
    /// 同语义：松手/惯性停 → 距底 ≤1pt 才恢复跟随（回底恢复唯一判定点）。
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        resumeTrackingAtBottom()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        resumeTrackingAtBottom()
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
