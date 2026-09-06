# 万我 (WanWo)

跑在 iPad 上的本地 AI Agent —— Swift 原生 Agent 内核 + iSH(ARM64) Linux 沙箱执行底座。

- 架构：Swift 原生 agent loop（复用 dsh 架构语义）× ish-arm64 Linux 沙箱 × Codex 式记忆系统
- 状态：M0 流水线验证阶段（CI 产出未签名 IPA）

## 构建与安装

1. GitHub Actions 自动构建（push 到 main 触发），在 Actions 页面下载 `WanWo-ipa` artifact
2. 解压得到 `.ipa`，用巨魔 TrollStore 侧载到 iPad（也可用 [Sideloadly](https://sideloadly.io) / AltStore / 爱思助手）
3. iPadOS 16.6+，iPad 优先（横屏）

## 里程碑

| 阶段 | 内容 | 状态 |
|---|---|---|
| M0.1 | CI 流水线 + 空壳 IPA | ✅ |
| M0.2 | iSH 三静态库接入，显示 Alpine `uname -a` | 🚧 |
| M1+ | 见 `docs/design/10-design.md`（万我系统设计 v2.1） | |

## License

GPL-3.0（因静态链接 [ish-arm64](https://github.com/OpenMinis/ish-arm64)）。详见 LICENSE。
