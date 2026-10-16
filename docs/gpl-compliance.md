# GPL / AGPL 合规登记（万我 · Vendor/nyxian）

> 依据 13 号设计 §1.3/§六.1：整目录 vendored、保留 AGPL 头与原注释、对 vendored 的一切修改在此登记（文件+原因+diff 摘要）。
> 万我项目许可证：**AGPL-3.0-or-later**（d1f6a57，2026-10-05 用户拍板）。

## 一、版本锚定（本文件即为事实源）

| 资产 | 锚定 | 证据 |
|---|---|---|
| Nyxian 源码（main 侧编译链） | **emexlab/Nyxian @ `0587c302a089219b68983c20be9265c6051e07e5`** | 官方 10-01 绿跑 run 36919965048 的精确 head SHA；本次以官方 codeload tarball 按 SHA 取源（`_n0_src/nyxian.tar.gz`，72,601,438 bytes） |
| LLVM-On-iOS 子模块（工具链） | `5c2e215`（swift 6.4.0） | 工具链 Release `toolchain-0587c30-20261016`（run 38873142024，SUCCESS，官方配方原样复刻） |
| 工具链产物 | LLVM.xcframework + CoreCompilerSupportLibs(13 dylib) + SwiftToolchain.zip，1,412,422,533 bytes | 复刻仓 Release tag `toolchain-0587c30-20261016`；CI 下载消费，不进 git |
| 运行侧（0.10.3，N7–N8 待落位） | Nyxian-0.10.3（本地快照） | 落位时补记精确锚 |

## 二、N0 vendored 清单（2026-10-16 落位，共 133 源文件 + 1 LICENSE）

| 万我落点 | 来源（main@0587c30） | 文件数 |
|---|---|---|
| `Vendor/nyxian/CoreCompiler/` | `Frameworks/CoreCompiler/**` | 36 |
| `Vendor/nyxian/MobileDevelopmentKit/` | `Frameworks/MobileDevelopmentKit/**` | 47 |
| `Vendor/nyxian/IDE/IDEFoundation/` | `Nyxian/LindChain/IDEFoundation/` | 23 |
| `Vendor/nyxian/IDE/IDEBuilder/` | `Nyxian/LindChain/IDEBuilder/` | 9 |
| `Vendor/nyxian/IDE/IDEConsole/` | `Nyxian/LindChain/IDEConsole/` | 4 |
| `Vendor/nyxian/IDE/IDELanguageServer/` | `Nyxian/LindChain/IDELanguageServer/` | 2 |
| `Vendor/nyxian/IDE/Utils/` | `Nyxian/LindChain/Utils/` | 12 |
| `Vendor/nyxian/LICENSES/Nyxian-AGPL-3.0.txt` | 上游 LICENSE 原文 | 1 |

字节级纪律：`.gitattributes` 增 `Vendor/nyxian/** -text`（官方 blob 131/133 为 CRLF 存储，禁行尾归一保字节原样——probe 仓教训）。
布局差异登记：`CoreCompilerSupportLibs/`（CI 产物位，不进 git）置 `Vendor/nyxian/` 包根而非 `CoreCompiler/` 内——避免污染 XcodeGen sources 扫描（probe 仓同款实证布局）。

## 三、修改登记（N0 品牌串机械替换，零逻辑改动）

替换映射（sed 全词，2026-10-16）：

| 原文（Nyxian） | 新值（万我） | 命中 |
|---|---|---|
| `org.emexlabs.nyxian.` | `com.wanwo.build.` | NXBuilder.swift:230/248（entitlement 键） |
| `org.emexlabs.` | `com.wanwo.` | NXBootstrap.m（rootca 文件名×4）/ NXRemoteCompiler.m:90（daemon 服务名）/ NXPhaseEngine.m:38/46/57（NSError domain） |
| `com.cr4zy.nyxian.` | `com.wanwo.` | NXBuilder.swift NSError domain ×10+ |
| `this/This version of Nyxian` | `this/This version of WanWo` | NXBuilder.swift:108（用户可见诊断文案 ×2） |

受影响文件：`IDE/IDEBuilder/NXBuilder.swift`、`IDE/IDEBuilder/NXPhaseEngine.m`、`IDE/IDEFoundation/NXBootstrap.m`、`IDE/IDEFoundation/NXRemoteCompiler.m`（4 文件）。

保留待改（N3b，SDK 内嵌决策）：`NXBootstrap.m:307/309/337/339` 的 `https://nyxian.app/bootstrap/…` 下载 URL 原样保留——N3b 改为从 app bundle 解压（SDK zip 内嵌 ipa，用户拍板 2026-10-16），届时登记。

保留不改（vendored 纪律）：代码符号前缀（NX*/LDE*/CC*/MDK*）、源码内注释与事故复盘、注释中的 Nyxian 字样。

## 四、已知怪味（不修——用户拍板 2026-10-16"无影响不修"）

main@0587c30 实测原样保留、且官方 CI 全绿背书：

1. `CCDriver.cpp:157` `_CFRuntimeCreateInstance` 多分配 `+sizeof(CFRuntimeBase)`（≈8B，无危害）
2. `Tools/CCSDK.cpp:95` `CFURLGetString`（file:// 形式）查 SDK 路径——官方绿跑实证可用
3. `Tools/Linker/CCLinker.cpp:92` `if(result == nullptr)` 恒假判断（死代码）

## 五、待落位（后续环）

- N1：CI 下载工具链 Release → 解压 `Vendor/nyxian/CoreCompilerSupportLibs/` → CC/MDK 真编译冒烟
- N4/N5：IDE 层接线（traitChanges 8 处适配在 N4）
- N7–N8：0.10.3 运行侧落位（LiveContainer/ProcEnvironment/litehook/Private/WindowServer/Downloader）
- N3b：Shared/{Templates,Themes,ObjCFix,highlights.scm} + 三 zip 载荷 + SDK 内嵌改造
