# 万我 (WanWo)

跑在 iPad 上的本地 AI Agent —— Swift 原生 Agent 内核 + iSH(ARM64) Linux 沙箱执行底座。

- 架构：Swift 原生 agent loop（复用 dsh 架构语义）× ish-arm64 Linux 沙箱 × Codex 式记忆系统
- 状态：M5 实现完成，真机验收迭代中（CI 产出未签名 IPA）

## 构建与安装

1. GitHub Actions 自动构建（push 到 main 触发），在 Actions 页面下载 `WanWo-ipa` artifact
2. 解压得到 `.ipa`，用巨魔 TrollStore 侧载到 iPad（也可用 [Sideloadly](https://sideloadly.io) / AltStore / 爱思助手）
3. iPadOS 16.6+，iPad 优先（横屏）

## 里程碑

| 阶段 | 内容 | 状态 |
|---|---|---|
| M0 | CI 流水线 + iSH 三静态库接入（Alpine 沙箱可执行命令） | ✅ |
| M1 | Agent 内核 + 对话流 + 工具执行面 | ✅ |
| M2 | Shell 执行 + bashism 检测 + 会话持久化（JSONL + GRDB 投影） | ✅ |
| M3 | LLM 对接 + 提示词组装 + 单测体系 | ✅ |
| M4 | MCP 全链 + 工具延迟加载 + Agent Skills + Hooks + 项目分组 | ✅ |
| M5 | 资源护栏 + 后台作业 + PTC(run_code) + 沙箱缝 + 远程沙箱接口 + 网络策略 | ✅ 实现完成，真机验收中 |
| M6+ | offload / 浏览器 / 外挂载 | 未开始 |

## 设计文档

系统设计（10-design）、功能清单（07-feature-list）等文档在项目工作区 `analysis/` 目录（不入仓库）。

## License

GPL-3.0（因静态链接 [ish-arm64](https://github.com/OpenMinis/ish-arm64)）。详见 LICENSE。
