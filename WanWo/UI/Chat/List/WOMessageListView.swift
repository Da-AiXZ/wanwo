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
    private var lastStableWidth: CGFloat = 0

    // MARK: 件 2/批 2 簿记

    private var historyLoading = false
    private var expanding = false
    /// 扩窗代际令牌（会话切换/视图拆解使在途切片作废）。
    private var expansionGeneration = 0
    /// 【重做批3 · R1】扩窗完成落在滚动中 → 静止后补提交（finishHistoryExpansion
    /// 置位；didEnd 系列消费）。
    private var scrollEndExpansionPending = false

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
        lines.append(String(format: "offset=%.0f contentH=%.0f viewport=%.0f adjT=%.0f adjB=%.0f follows=%d items=%d width=%.0f",
                            cv.contentOffset.y, cv.contentSize.height, cv.bounds.height,
                            cv.adjustedContentInset.top, cv.adjustedContentInset.bottom,
                            followsBottom ? 1 : 0, currentItems.count,
                            cv.bounds.width - messageLayout.sectionInset.left
                                - messageLayout.sectionInset.right))
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
        syncedNodes = [:]
        contentVersions = [:]
        currentItems = []
        lastPhase = nil
        historyLoading = false
        expanding = false
        followsBottom = true
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
        // 【批4 真机诊断】大跳变落行（|Δ|>150pt）——空白/偏移残余问题的
        // 真机定位探针（修复后理论无此量级跳变；出现即证据）。
        if let previous = pool.cachedHeight(id: id, width: contentWidth()),
           abs(previous - height) > 150 {
            heightJumpLog.error("wo-height-jump id=\(id, privacy: .public) old=\(previous, format: .fixed(precision: 0)) new=\(height, format: .fixed(precision: 0))")
        }
        let signature = contentVersions[id].map { "v\($0)" }
        guard pool.updateHeight(id: id, width: contentWidth(), height: height,
                                signature: signature) else { return }
        // 【重做批3 · 验证记录 R3】行高变化恒免动画提交——旧 0.45s
        // UIViewPropertyAnimator 与贴底 display link 双轨并存=真机"上下抽搐"
        // 根因（lody 单运动源对照实锤）；批 5 行高插值队列（display link 单
        // tick 先行高后贴底）接棒运动职责。
        commitHeightChange(id: id, height: height, collectionView: cv)
    }

    /// 高度提交公共体【QA P1-2 拆分】：锚定 + invalidate + 贴底。回传路径与
    /// 切片重测路径共用。
    private func commitHeightChange(id: String, height: CGFloat,
                                    collectionView cv: UICollectionView) {
        if !followsBottom, !expanding {
            pendingAnchorRestore = AnchorRestore(
                anchor: captureTopAnchor(),
                oldContentHeight: cv.contentSize.height)
        }
        messageLayout.invalidateLayout()
        // 【批4 诊断实证修】异步补标一次（幂等）：SwiftUI 的 onPreference
        // Change 常嵌在 hosting 布局链（= collectionView layout pass 内）
        // ——pass 内 invalidate 存在被 UIKit 忽略的面（list-diag.log 实锤
        // frame=23/pool=47 脱钩，后续行整体错位 24pt=真机"上偏"）。若首个
        // invalidate 已生效，此处为无变化的空标记；循环终止=池值稳定
        // （updateHeight 0.5pt 死区）。
        DispatchQueue.main.async { [weak self] in
            self?.messageLayout.invalidateLayout()
        }
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
        // 【CI修50】列宽动画中不 drain（只收集）：右栏开合 0.42s 内每帧
        // prepare 都在收集 stale，宽度稳定后的第一个 layout pass 一次清账
        // ——把切片重测工作量挪出动画帧（真机反馈"还是有些卡卡的"）。
        // 高度在动画期间由 stale 顶替机制先顶着（旧高不改，布局连续）。
        // 60ms 复查自愈：万一宽度只变一帧没有后续 pass，也能在半帧后清账。
        let width = collectionView.bounds.width
        if width != lastStableWidth {
            lastStableWidth = width
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self, self.collectionView?.window != nil else { return }
                self.drainStaleSweep()
            }
            return
        }
        let batch = pool.drainStaleSweep()
        guard !batch.isEmpty else { return }
        remeasureQueue.append(contentsOf: batch)
        guard !remeasureActive else { return }
        remeasureActive = true
        runRemeasureSlice(generation: remeasureGen, index: 0)
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
        // 【CI修49】stale 重测切片调度（prepare 期间收集的宽度变化行——
        // 空队列时零成本）。
        drainStaleSweep()
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
