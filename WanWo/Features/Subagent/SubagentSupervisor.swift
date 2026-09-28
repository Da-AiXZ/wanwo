//
//  SubagentSupervisor.swift
//  WanWo
//
//  【M7.3 件 H · F050】Supervisor = 治理 + 持久化 + 恢复层（主理人已定架构
//  判定④：骑在批1 SubagentRuntime 上，不建平行运行时）。本文件承载：
//    - 治理常量（SubagentGovernance——codex core/src/config/mod.rs 常量 1:1）。
//    - 四份裁定书（LRU 驻留 / role 文件系统 / fork 上下文清洗核对表 /
//      执行槽收编——均为代码注释形态的"判定书"，供 QA 复核，不新增机制）。
//  治理状态（总数 CAS / path 注册表 / 恢复登记表）与运行时编排（恢复重挂 /
//  close_agent / 边表持久化挂点）实现在 SubagentRuntime actor 内
//  "Supervisor 治理层（M7.3）" MARK 段——actor 存储属性不可落于 extension，
//  且与 activations 同 actor 串行化才能保证注册表与激活表一致。
//

import Foundation

/// codex V2 编排治理常量（core/src/config/mod.rs:233-241 1:1；出处行号随行）。
enum SubagentGovernance {
    /// DEFAULT_MULTI_AGENT_V2_MAX_CONCURRENT_THREADS_PER_SESSION = 4
    ///（mod.rs:233）。codex `AgentRegistry.reserve_spawn_slot` 以该值-1 作为
    /// 子线程总数上限（派单裁定：子上限 3 = 缺省 4 - 1，registry.rs:337-353
    /// try_increment_spawned CAS 循环语义）。
    static let totalChildrenLimit = 3

    /// DEFAULT_MULTI_AGENT_V2_MIN_WAIT_TIMEOUT_MS = 10_000（mod.rs:234）。
    static let minWaitTimeoutMs: Int64 = 10_000
    /// DEFAULT_MULTI_AGENT_V2_MAX_WAIT_TIMEOUT_MS = 3600 * 1000（mod.rs:235；
    /// HARD_MAX_MULTI_AGENT_V2_TIMEOUT_MS = 该值，mod.rs:239-241）。
    static let maxWaitTimeoutMs: Int64 = 3_600_000
    /// DEFAULT_MULTI_AGENT_V2_DEFAULT_WAIT_TIMEOUT_MS = 30_000（mod.rs:236；
    /// multi_agents_common.rs:31 DEFAULT_WAIT_TIMEOUT_MS 同值）。
    static let defaultWaitTimeoutMs: Int64 = 30_000
}

// MARK: - 裁定书①：LRU 驻留平台不适用（主理人判定②，QA 复核登记）
//
// codex residency.rs（V2Residency：VecDeque LRU + pending_slots + 惰性 unload
// :81-216）为 CLI 大线程数省内存设计：驻留线程栈驻内存，超容量时按 LRU 挑选
// unloadable（终局+无 active turn+无 pending mailbox，residency.rs:233-239）
// 线程 shutdown 并保存 evicted_environments（residency.rs:147-153）以备
// ensure_v2_agent_loaded 重挂（spawn.rs:298-584）。
//
// 万我不移植：子会话栈全内存常驻（AgentLoop actor + 事件快照），且治理层
// 总数上限（3）+ 执行槽（4）已兜底规模；iOS 单进程无 CLI 百线程压力面。
// 恢复面以持久层（threadSpawnEdges Open 边 + 子日志 lineage/descriptor）替代
// evicted_environments——恢复语义由 SubagentRuntime.recoverOpenChildren 承载
// （惰性重挂，见裁定书注释 SubagentRuntime.swift M7.3 段）。

// MARK: - 裁定书②：role 文件系统不适用（主理人判定③，QA 复核登记）
//
// codex role.rs（AgentRoleConfig：config_file TOML 层叠 + 只减不增特性面
// :91-118 + nickname_candidates :49-61）与 assets/agent/builtins/*.toml
// （explorer/worker 内置角色）在万我无对应面：万我没有 codex 的 role 文件
// 加载器（parse_agent_role_file_contents）与特性开关层。
// "只减不增"纪律由批1 已落机制承载：SubagentDelegation.contextText
// （child-agent.ts:171-175 逐字——委派范围固定、approval never）+
// 子会话沙箱继承（subagentSandboxOverride，QA-3 P1-5）+ 无 per-child 工具面
// 扩展。nickname 池（registry.rs:264-302 + agent_names.txt）随 role 面整体
// 不移植——万我 path 段名由 label 消毒派生（SubagentRuntime.assignChildPath），
// 无随机昵称词汇表。

// MARK: - 裁定书③：fork 上下文清洗核对表（派单落点⑤：天然满足的不造轮子）
//
// codex spawn.rs fork 清洗清单逐条 → 万我映射（逐条给出批1 已落机制出处；
// 每条结论均为"天然满足"，不新增清洗机制）：
//
//  1. keep_forked_rollout_item（spawn.rs:63-103：fork 只保留 system/developer/
//     user 消息 + FinalAnswer assistant + call_id 缺省的 FunctionCallOutput；
//     Reasoning/FunctionCall/Compaction/TokenUsage 等全弃）：
//     → 万我 fork 种子 = ForkInProcessProvider.completedTurnPrefix
//       （SubagentRuntime.swift:138-144，最后一条 turnEnd 含前切片）；子栈写侧
//       批量 append 原样 shape 复用 + ignorable 随行（AppEnvironment
//       makeSubagentChildStack"种子批量写"段）——非 model-visible 行
//       （assistantChunk 等）以 ignorable 旗标承载，不进派生历史（同一
//       "子不继承父中间步"语义，投影层裁决不同：codex 丢弃 / 万我保留但
//       ignorable——dsh 对拍已登记，批1 QA 通过）。
//  2. retain_forked_developer_message（spawn.rs:105-126：developer 消息剔除
//     MultiAgentRole/ModeInstructions 与 CurrentTimeReminder 帧）：
//     → 万我 developer/instruction 帧不存在于会话日志（PromptAssembler 段
//       每次组装时现做，落盘日志只有 user/assistant/tool 载荷）。
//       【QA-4 补正】落盘 user 载荷内含 userMessage 通道注入块
//       （runtime-context / AGENTS.md / @file 引用——AgentLoop.swift:1014/
//       1033/844/1089 QA 实证），fork 种子切片原样继承这些块 = 对齐 codex
//       keep-user 口径（spawn.rs:63-103 只剔 developer 帧、user 帧全保留），
//       属预期继承面，非 developer 残留。
//  3. 父 developer instructions 替换（spawn.rs:946-968：子注入
//     subagent_developer_instructions 替换父片段）：
//     → 万我子栈 = 全新 makeAgentStack（AppEnvironment makeSubagentChildStack
//       "全栈复用"段）——system prompt/段位/纪律段（subagent:delegation 段、
//       subagentDepth 段）由子栈自身组装，父的运行时注入片段从不进子上下文。
//  4. Compacted 清洗（spawn.rs:996-1019：replacement_history 复刮 +
//     latest_token_usage_record/guardian_history 置空）：
//     → 万我会话日志无 compacted checkpoint 载体（压缩产物不落盘为独立
//       RolloutItem）+ guardian history 无对应物（codex 安全审查证据链，
//       万我 approval 面为实时请求制）——无清洗对象。
//  5. usage hints 剔除（spawn.rs:884-899 + WorldState "multi_agent_usage_hint"
//     :1014-1018）：
//     → 万我无 usage hints 注入面（批1 工具提示段 tool:fork 由子栈缺失——
//       提示段注册在父 assembler，子 assembler 全新）。
//  6. TokenUsageRecord 不继承（spawn.rs:99-100）：
//     → 万我 token 累计为会话内投影，fork 种子只含事件载荷，无 usage 状态
//       跨会话携带路径。
//
//  核对结论：清单六条全部由"子栈=全新 makeAgentStack + 种子=纯事件切片 +
//  ignorable 投影纪律"天然满足；无新增清洗机制（派单裁定同款口径）。

// MARK: - 裁定书④：执行槽收编（派单落点④"与批1 startGate(4) 的关系=收编统一"）
//
// codex 双闸分离：AgentExecutionLimiter（execution.rs:13-89，turn 级——
// ensure_execution_capacity 非阻塞容量判定 + AgentExecutionGuard RAII 占用）
// 与 AgentRegistry.total_count（registry.rs，spawn 级 CAS 总数）。批1 的
// SubagentStartGate(limit: 4) 是**唯一信号量**（materialization 级获取/释放）。
// 收编方案（M7.3 落地形态）：
//   · 唯一信号量 = 保留 SubagentStartGate（limit 4 = mod.rs:233 缺省并发），
//     治理层不再造第二把闸；max_threads OnceLock 初始化语义
//     （execution.rs:73-75 get_or_init）= 万我装配期定档 limit，等价。
//   · ensure_execution_capacity 非阻塞容量判定（execution.rs:44-60，
//     active<max 才放行、否则 AgentLimitReached）→ 万我映射为
//     SubagentStartGate 的 acquire（等待挂起形态——万我子启动从 fail-fast
//     改排队等待，语义更强不更弱，登记）+ startContinuable 前置容量判定。
//   · AgentExecutionGuard RAII（Drop 递减）= gate.acquire/release defer 对
//     （SubagentRuntime start/startContinuable 既有形态）。
//
// 【QA-4 P2-③ 补正——闸覆盖窗口如实登记】startGate 的 release 走 defer，
// 在 materializer 返回（函数收尾）即放闸：continuable 子物化完成后**不占
// 执行槽**（驻留形态，运行期由消息泵/任务并发约束，不由本闸约束）；
// one-shot 整个运行期占闸（调用方持有至 turn 终局）。故万我治理强度与
// codex 并不逐位对齐，如实登记：
//   · 总数闸 = continuable 驻留树上限 3（registry.rs:337-353 等价；
//     one-shot/ephemeral 不计入）；
//   · 物化级闸 = startGate(4)——只约束"同时在物化"的段，上限 4；
//   · one-shot 运行期占闸。
//   叠加峰值 = 驻留 3 + 闸 4 = 同会话最多 7 个子线程并存，**宽于** codex
//   有效强度（codex turn 级 limiter 使运行中子至多 4 且总数 CAS 全形态
//   计 3）。取宽为主理人判定④"骑在批1 闸上不另造机制"的接受偏差；
//   若后续需收紧，缝在 startContinuable 物化窗口外增驻留子运行位计数，
//   不在本件范围。
