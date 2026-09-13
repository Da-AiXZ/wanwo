//
//  IshResourceGovernor.swift
//  WanWo
//
//  【M5-A 批 G1 · 资源护栏 Swift 门面】出处（逐锚点对拍，file:line 亲验）：
//    - Vendor/ish/kernel/mm.h:90-134（[T-ish-footprint-brake] 喂送语义：
//      limit=phys_footprint+available / avail=os_proc_available_memory /
//      critical=OS 关键压力事件；>2s 停喂 fail-closed → BRAKE（:110-111））
//    - Vendor/ish/kernel/mmap.c:52-93（ish_set_memory_status 状态机与
//      ish_mem_commit_ok stale 语义）
//    - Platform/ISHKernel.h:163-183（begin/endBackgroundCPUGovernor 注释
//      原文："Call on didEnterBackground. Idempotent." / "Call on foreground
//      return. Idempotent."；4 Hz 采样入 60s 滑窗）
//    - 节拍 250ms：08 报告 :257「接资源治理回调：ish_set_memory_status（250ms
//      喂 footprint）」+ CLI 先例 Vendor/ish/main.c:345-364（250ms 喂送线程）
//    - 定时器形态：DispatchSourceTimer —— Platform/ISHKernel.m:1604/1809-1819
//      GOV_CADENCE_NS 同款模式（UTILITY 队列 + leeway）
//    - 注入缝先例：HookRunner.swift:62 HookCommandExecuting（生产包装 ObjC
//      桥 / 测试桩注入）
//  分层判定（呈报要点③）：测量与内核 C 调用留在 ObjC（测量件
//  minis_current_phys_footprint / fork guard 压力源均为 ISHKernel.m 文件级
//  静态，:189/:149，Swift 不复刻、不跨层摸静态）；节拍定时器与前后台接线
//  放 Swift（生命周期属 App 域——ObjC 侧 begin/end 只做幂等启停、不持有
//  任何通知监听，OpenMinis 原件同样把通知面留给宿主）。
//

import Foundation

// MARK: - 注入缝（HookCommandExecuting 同模式）

/// ObjC 内核面的注入缝：生产 = ISHKernel.shared（方法由 ISHKernel.h 的
/// Scheduler/MemoryGovernor 两个 category 提供）；测试 = 记录桩。
protocol ISHResourceKernelControlling: AnyObject {
    /// ISHKernel.h:179 —— didEnterBackground 时开闭环 governor（幂等）。
    func beginBackgroundCPUGovernor()
    /// ISHKernel.h:183 —— 前台返回时停 governor 并清节流（幂等）。
    func endBackgroundCPUGovernor()
    /// ISHKernel.h MemoryGovernor category —— 单次内存状态喂送。
    func feedMemoryStatus()
    /// governor zone（0 GREEN / 1 YELLOW / 2 RED；非后台时段恒 0）。
    var backgroundCPUGovernorZone: Int32 { get }
    /// governor 定时器是否在跑（begin 未配对 end）。
    var isBackgroundCPUGovernorRunning: Bool { get }
    /// footprint 准入模式是否已激活（首次喂送后为真；mm.h:127-128）。
    var isMemoryFootprintModeActive: Bool { get }
    /// fork guard 累计 stall 计数（自 boot 单调递增）。
    var forkGuardStallCount: UInt64 { get }
}

extension ISHKernel: ISHResourceKernelControlling {}

// MARK: - 快照（G2 真机压测的观测载体）

/// 资源护栏状态快照（只读诊断面）。
struct IshResourceGovernorSnapshot: Equatable {
    /// CPU governor zone（0 GREEN / 1 YELLOW / 2 RED）。
    let governorZone: Int32
    /// 后台 CPU governor 定时器是否在跑。
    let isGovernorRunning: Bool
    /// 内核已进入 footprint 准入模式（首次喂送后为真）。
    let isFootprintModeActive: Bool
    /// fork guard 累计 stall 计数。
    let forkGuardStallCount: UInt64
    /// 本门面喂送定时器是否在跑。
    let isFeedTimerRunning: Bool
    /// 喂送次数（门面侧计数）。
    let feedCount: Int
    /// 最近一次喂送时刻（nil = 尚未喂过）。
    let lastFeedDate: Date?
}

// MARK: - 门面

/// 资源护栏 Swift 门面（App 级单例，AppEnvironment 装配）：
/// ① 前后台切换 → begin/endBackgroundCPUGovernor 接线（由 WanWoApp 既有
///    scenePhase onChange 转发——沿用 WanWoApp.swift:21 同款模式，不新建
///    NotificationCenter 监听机制）；
/// ② 250ms 内存喂送定时器 → ish_set_memory_status（内核 footprint 准入）；
/// ③ 状态快照暴露（governor zone / fork guard stalls / footprint mode）。
///
/// 喂送定时器 App 生命周期常驻（前台后台都喂）论证：内核 stale 规则
/// （mm.h:110-111）把「>2s 未喂」判为死采样器 fail-closed 进 BRAKE——喂送
/// 停了就是主动制造假刹车；喂送本身极廉价（两次宿主测量调用/250ms，与
/// ObjC governor 的 10Hz 采样同级），CLI 先例（main.c:358-365）同样是常驻
/// 线程。App 退后台被 iOS 挂起时 dispatch timer 天然停摆，内核侧 stale
/// fail-closed 是保守方向（无 guest 在跑，无副作用）；唤醒后 250ms 内恢复。
final class IshResourceGovernor: @unchecked Sendable {

    /// 喂送节拍：08 报告 :257（250ms 喂 footprint）+ main.c:362 同节拍先例。
    static let defaultFeedInterval: TimeInterval = 0.25

    private static let logger = AppLogger(category: "resource-governor")

    /// 内核面（生产 ISHKernel.shared / 测试桩）。
    private let kernel: ISHResourceKernelControlling
    /// 喂送节拍（秒）。
    private let feedInterval: TimeInterval
    /// 定时器队列（UTILITY——与 ObjC governor g_gov_queue 同 QoS 档，
    /// ISHKernel.m:1789-1791）。
    private let queue: DispatchQueue

    private let lock = NSLock()
    private var feedTimer: DispatchSourceTimer?
    private var feedCountValue = 0
    private var lastFeedDateValue: Date?

    /// - Parameters:
    ///   - kernel: 内核面注入缝（默认生产单例）。
    ///   - feedInterval: 喂送节拍（测试注入短节拍观测启停）。
    ///   - queue: 定时器队列（测试可换同步形态；默认 UTILITY 串行）。
    init(kernel: ISHResourceKernelControlling = ISHKernel.shared,
         feedInterval: TimeInterval = IshResourceGovernor.defaultFeedInterval,
         queue: DispatchQueue = DispatchQueue(
            label: "com.wanwo.ish.resource-governor", qos: .utility)) {
        self.kernel = kernel
        self.feedInterval = feedInterval
        self.queue = queue
    }

    // MARK: 生命周期

    /// App 装配期调用一次（幂等）：启动喂送定时器。首喂早于 guest boot
    /// 是期望行为——CLI 先例 main.c:367-370 明言「Prime the feed BEFORE the
    /// guest boots」（首次分配发生在 init exec 期，晚于任何 250ms tick）。
    func start() {
        lock.lock()
        guard feedTimer == nil else {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + feedInterval,
                       repeating: feedInterval,
                       leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.feedOnce() }
        timer.resume()
        feedTimer = timer
        lock.unlock()
        Self.logger.info("resource governor: feed timer started (interval \(String(format: "%.3f", self.feedInterval))s)")
    }

    /// 停止喂送定时器（App teardown 面；正常形态常驻不停——内核 stale
    /// 规则使停喂=失效关闸）。
    func stop() {
        lock.lock()
        let timer = feedTimer
        feedTimer = nil
        lock.unlock()
        timer?.cancel()
        Self.logger.info("resource governor: feed timer stopped")
    }

    /// 进后台（scenePhase .background 转发）：开启后台 CPU governor。
    /// ISHKernel.h:178「Call on didEnterBackground. Idempotent.」——幂等由
    /// ObjC 侧保证（ISHKernel.m:1788 begin 早退），转发不设防重复计数。
    func handleDidEnterBackground() {
        Self.logger.info("resource governor: scene → background — begin CPU governor")
        kernel.beginBackgroundCPUGovernor()
    }

    /// 回前台（scenePhase .active 转发）：停 governor 并清节流。
    /// ISHKernel.h:181-183「Stop the governor and clear any applied throttle.
    /// Call on foreground return. Idempotent.」SwiftUI scenePhase 无独立
    /// willEnterForeground 态，.active 即前台返回语义（.inactive 是半透明
    /// 遮挡等瞬时态，不动 governor）。
    func handleWillEnterForeground() {
        Self.logger.info("resource governor: scene → active — end CPU governor")
        kernel.endBackgroundCPUGovernor()
    }

    // MARK: 喂送

    /// 单次喂送（定时器驱动；测试/诊断可直接调）。三值聚合与内核 C 调用
    /// 在 ObjC 侧 feedMemoryStatus（Platform/ISHKernel.m MemoryGovernor
    /// category）完成——Swift 侧只做计数遥测。
    func feedOnce() {
        kernel.feedMemoryStatus()
        lock.lock()
        feedCountValue += 1
        lastFeedDateValue = Date()
        lock.unlock()
    }

    // MARK: 状态暴露

    var isFeedTimerRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return feedTimer != nil
    }

    /// 只读快照（G2 压测观测：zone / stalls / footprint mode / 喂送遥测）。
    var snapshot: IshResourceGovernorSnapshot {
        lock.lock()
        let count = feedCountValue
        let last = lastFeedDateValue
        lock.unlock()
        return IshResourceGovernorSnapshot(
            governorZone: kernel.backgroundCPUGovernorZone,
            isGovernorRunning: kernel.isBackgroundCPUGovernorRunning,
            isFootprintModeActive: kernel.isMemoryFootprintModeActive,
            forkGuardStallCount: kernel.forkGuardStallCount,
            isFeedTimerRunning: isFeedTimerRunning,
            feedCount: count,
            lastFeedDate: last)
    }
}
