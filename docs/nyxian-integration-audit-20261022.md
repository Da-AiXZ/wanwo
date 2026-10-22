# 万我 × Nyxian 集成考古报告（2026-10-22 全量复验）

> 方法：三方逐文件 md5 比对（万我 vendored 2002 文件 / 官方 0.10.3 / 官方 main 快照）+ git 全史考据 + gpl-compliance 登记核对 + GitHub 上游锚定验证。零记忆依赖，全部结论有本轮实证。

## 一、万我血统总图（三层上游）

```
万我（WanWo）
├─ 骨架层   QingShan@f462262（M0 重建，Vendor/ish iSH 内核 1717 文件字节一致，Platform/ 同源）
├─ App 层   OpenMinis 原件逐文件 vendored（M0 v2.2，9cb104d）+ 自研 M1-M3（dsh 语义移植：会话/agent loop/审批/权限/UI）
└─ Nyxian 集成（N0-N10，两波双基线）
   ├─ 第一波 N0/N3b/N4（编译+IDE 层）= emexlab/Nyxian main@0587c302（2026-10-01）
   └─ 第二波 N7a/N8（运行时层）      = emexlab/Nyxian tag 0.10.3 = c5ee6398（2026-05-23）
```

- 仓史 699 提交：M0（9-07 骨架）→ M1 会话 → M2 agent loop → M3 审批/权限 → N0（10-16 Nyxian 落位）→ … → e63218a/c7dd068（实战轮修复）。
- N0 提交原文（c643baf）：「Nyxian main@0587c30 字节级落位 133 文件+品牌串机械替换（org.emexlabs/com.cr4zy→com.wanwo，登记 docs/gpl-compliance.md）」。
- N7a（edc1faa）：「LiveContainer 49 文件+OpenSSL.xcframework（**0.10.3 自带**）落 vendored」。
- N8a/b（ccfd3d7）：「vendored **0.10.3 运行面**（216 文件→217）+主 App/appex 双 target 编译面镜像」。

## 二、版本地图（按目录归属）

| 万我落点 | 上游版本 | 引入环 | 实证 |
|---|---|---|---|
| `Vendor/nyxian/CoreCompiler/`（36 文件） | main@0587c30（`Frameworks/CoreCompiler/`） | N0 | EQ_MAIN 28 + SAME_BOTH 8 |
| `Vendor/nyxian/MobileDevelopmentKit/`（47 文件） | main@0587c30（`Frameworks/MobileDevelopmentKit/`） | N0 | EQ_MAIN 37 |
| `Vendor/nyxian/LindChain/IDEFoundation/`（23） | main@0587c30 | N0（N3b 改名 IDE/→LindChain/） | EQ_MAIN 12 + SPLIT 5 |
| `Vendor/nyxian/LindChain/IDEBuilder/`（9） | main@0587c30 | N0 | EQ_MAIN 6 + SPLIT 3 |
| `Vendor/nyxian/LindChain/IDEConsole/IDELanguageServer/`（6） | main@0587c30 | N0 | EQ_MAIN 5 |
| `Vendor/nyxian/LindChain/Utils/`（12+） | main@0587c30 | N0（relax.h=N3b 复制；entitlement.c=N4 万我实现；NXOSVersion.swift=万我提取新建） | EQ_MAIN 7 |
| `Vendor/nyxian/Shared/{include,lib,swift}.zip`（资产） | main@0587c30 源码树 Shared/ | N3b | 登记在案 |
| `Vendor/nyxian/Shared/SDK.zip` | `nyxian.app/bootstrap/iPhoneOS26.5.sdk.zip`（0.10.3 实证 URL；**iPhoneOS26.5.sdk**） | N3b | E 系列实证 |
| `Vendor/nyxian/LindChain/LiveContainer/`+OpenSSL.xcframework（49+） | **0.10.3**（c5ee639） | N7a | EQ_0103 19 + SAME_BOTH 34 |
| `Vendor/nyxian/LindChain/ProcEnvironment/`（132+） | **0.10.3** | N8a/b | EQ_0103 132 |
| `Vendor/nyxian/LindChain/WindowServer/`（12） | **0.10.3** | N8a/b | EQ_0103 12 |
| `Vendor/nyxian/Shared/LaunchServices/`（plists） | **0.10.3** | N8a/b | DIFF_0103_ONLY 2（品牌折算） |
| `Vendor/nyxian/LindChain/{Private,litehook,Debugger,Project}` 等 | **0.10.3** | N8a/b | EQ_0103 11 |
| Templates.bundle | 两版一致（SAME_BOTH 6） | N4/N5 | md5 相同 |

**基线定量**（v3 diff 统计）：2002 文件中 SAME_BOTH 1688 + EQ_0103 178 + EQ_MAIN 107 = **1973（98.6%）官方字节原样**；万我修改 26；万我新建 3；无未登记漂移。

## 三、万我修改面 26 文件（全部登记在案）

**基线=main 的修改（8）**：NXBuilder.swift（N0 品牌+N4 宏守卫）、NXPhaseEngine.m（N0+N4）、NXBootstrap.m（N3b 六处 16 化）、NXRemoteCompiler.m（N4 空壳替换）、NXProject.h/m（N4 import+批 B X 变量表）、Project+Debug.swift、NXCodeTemplate.m（修 A schemeKind）、MDKThreadPool.m（批 1 修 J 64MB 栈）、CCLinker.cpp（N6 retCode UB 兜底）、entitlement.c（N4 万我常量实现）。

**基线=0.10.3 的修改（13）**：LCBootstrap.m（N9 patch+批 B 修 T fprintf）、Dyld.m（修 C 诊断）、ZSign {openssl.cpp,zsigner.h/m,bundle.cpp}（N7c 三轮：身份覆写开关）、PE{Extension,Process,ProcessManager}.m、pectl.h、NXWindowSessionTerminal.m（N8 品牌折算+适配）、LaunchServices 两 plist（N8 品牌折算）。

**万我新建（3）**：LICENSES/Nyxian-AGPL-3.0.txt（许可证副本）、LindChain/Utils/NXOSVersion.swift（自官方 UI 层 iOSVersionPickerView.swift 字节级提取）、Shared/SDK.zip（资产）。

## 四、锚定登记状态（本轮补齐）

| 资产 | 锚 | 状态 |
|---|---|---|
| IDE/编译层 | main@`0587c302a089219b68983c20be9265c6051e07e5`（2026-10-01） | 原登记完整；本轮复验 probe 快照 127/131+4 品牌替换 ✓ |
| 运行层 | tag `0.10.3` = `c5ee6398b998f1fc0d42523c1a420efe2179a3b7`（2026-05-23） | **本轮补记**（原「落位时补记精确锚」缺口）；1981/1991 blob 验证 ✓ |
| 工具链 | 复刻仓 Release `toolchain-0587c30-20261016`（LLVM-On-iOS@5c2e215, swift 6.4.0），1,412,422,533 B | 原登记完整 |
| SDK | iPhoneOS26.5.sdk（nyxian.app/bootstrap，33,880,102 B） | 原登记完整 |

登记文件：`docs/gpl-compliance.md`（853 行，N0→N10 各环逐 diff）；考古中间产物：`docs/_audit_vendored_map.md`（逐文件归属）、`docs/_audit_baseline.md`（18 文件基线精判）。

## 五、已知移植面差异（集成适配的全部已知点）

1. **目录布局重组**：IDE/→LindChain/（N3b，对齐官方 import 语义）、LiveContainer 拍平至 LindChain/ 直下（官方 0.10.3 在 ProcEnvironment/LiveContainer/——万我布局自 0.10.3 原样）、PE 系列万我多一层 Process/ 子目录。
2. **品牌串机械替换**（N0 四文件+键映射 org.emexlabs.nyxian.*→com.wanwo.build.*）。
3. **混合基线接缝**：NXBuilder.swift .run 分支 main 符号（trust_nxt2_sign/ksurface）宏守卫 + 0.10.3 库接口（ZSigner/LCUtils）——N7a 接缝表。
4. **NXBootstrap 16 化**（N3b 六处）+ SDK 27.0→26.5 内嵌。
5. **NXRemoteCompiler 空壳**（N4，compilerd 关）→ 本地 MDKDependencyScanner 回退（=E 系列定罪的自动链接路径）。
6. **E 系列定罪**：`NXLinkFrameworksAutomatically`（main 版原生功能）× 老 OS（16.6.1 无 Symbols.framework）=纯 ObjC 工程 dlopen 必死；-fmodules 无辜；万我运行链无罪。

## 六、接下来怎么搞（建议序，全部待拍板）

| 序 | 事项 | 性质 |
|---|---|---|
| 1 | **B 收尾**：32 步护栏移除半成品（AgentLoop.swift 已改 2 处，AppEnvironment/SubagentDriver 2 处待改） | 已拍板未完工 |
| 2 | **F-D**：工具提示加注「纯 ObjC 工程 Symbols dlopen 失败→关自动链接+手写 -framework 三件套」 | P1-10 立即可用缓解 |
| 3 | **F-A 考古**：CCDependencyScanner（CoreCompiler 黑盒二进制）扫描行为定性→决定自动链接收窄方案（vendored 改动需登记） | 根因修复前置 |
| 4 | C1 冷缓存文案条件化 / D1 run_log 副本只截本次 / D3 bash 描述加缓存滞后注记 | 上轮遗留待选 |
| 5 | 隐患 O1（出厂 gate no-op→utility plist 实携 YES）、P2-13 actool/ibtool、token 瞬态根因 | 挂账在册 |
| 6 | 上游跟踪：emexlab/Nyxian main 最新 0.11.4（Scriptura Beta, 0c61cfb）——未来是否升级基线另行评估 | 长期 |
