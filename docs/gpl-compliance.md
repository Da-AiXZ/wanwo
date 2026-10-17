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

保留不改（vendored 纪律）：代码符号前缀（NX*/LDE*/CC*/MDK*）、源码内注释与事故复盘、注释中的 Nyxian 字样。

## 三 b、N3b 环修改登记（2026-10-17，NXBootstrap 16 化——全部 diff 逐处列出）

分发方式改**内嵌**（用户拍板 2026-10-16 ③）：SDK 与 Shared 三 zip 随 app 分发，首启解压零网络。资产来源与体量（实测）：

| 资产 | 来源 | 体量 |
|---|---|---|
| `Shared/include.zip` | 官方 main@0587c30 源码树 `Shared/`（与 0.10.3 字节一致） | 1,209,276 B |
| `Shared/lib.zip` | 同上 | 64,571 B |
| `Shared/swift.zip` | 同上 | 17,747,159 B |
| `Shared/SDK.zip` | `https://nyxian.app/bootstrap/iPhoneOS26.5.sdk.zip`（0.10.3 实证 URL；main 版 NXBootstrap 下载的 27.0 SDK 不采用——混合基线拍板 26.5，官方 CI 编译同款 iphoneos26.5） | 33,880,102 B |

`LindChain/IDEFoundation/NXBootstrap.m` 修改点（原文件 448 行）：

| # | 位置 | 改动 |
|---|---|---|
| 1 | import 区 | 移除 `fdownload.h`/`keychain.h`/`Nyxian-Swift.h`（内嵌方案+守卫后无引用）；`relax.h` 改 `<LindChain/Utils/relax.h>`；`UI/XCodeButton.h` 改万我 `XCButtonCompat.h`；附适配说明注释 |
| 2 | rootURL | `Documents` → `Documents/wanwo-build`（13 号设计 §三拍板；子目录收拢） |
| 3 | sdkURL | `iPhoneOS27.0.sdk` → `iPhoneOS26.5.sdk`（混合基线） |
| 4 | v28 段 | `#if defined(WANWO_BOOTSTRAP_TRUST) && WANWO_BOOTSTRAP_TRUST` 守卫（默认关）——RootCAs/rootca 下载/ksurface_keychain_update 属 N7 trust 链；版本号 28 不落盘，v29 条件照常成立 |
| 5 | v29 段 | `fdownload(27.0 SDK)` → 解压 bundle 内 `SDK.zip`；符号链接列表 26.2/26.4.1/26.4 → 26.5（对齐 0.10.3 实证形态，实体本身即 26.5 故移除该项） |
| 6 | v10/v23/v29 | bundle 资源路径 `Shared/xxx.zip` → 平铺 `xxx.zip`（D2 先例：folder 展开冲突；四 zip 文件名唯一单文件资源） |

`LindChain/IDEFoundation/NXAlertDiagnosticPresenter.m`：`NXWindowServer.shared.rootViewController`（WindowServer 层 N9 落位）→ 万我 `WANWOKeyRootViewController()`（connectedScenes keyWindow rootVC，iOS 16 兼容，语义等价）。

新增（万我侧，非官方代码）：`WanWo/Features/BuildExt/XCButtonCompat.h/.m`——官方 XCButton 类方法接口同签名实现（NSNotificationCenter 广播 `com.wanwo.bootstrap.progress/icon`，无监听者时安全 no-op）；`LindChain/Utils/relax.h`——官方 `ProcEnvironment/Surface/libkern/relax.h` **字节级复制**（该层未落位，NXBootstrap 引用；文件内容零改动）。

目录对齐：`Vendor/nyxian/IDE/` 重命名 `Vendor/nyxian/LindChain/`（N0 落位时的目录名与官方 import 语义不一致——对齐后 `<LindChain/...>` 全部原生解析，vendored import 一字不改）。

## 四、已知怪味（不修——用户拍板 2026-10-16"无影响不修"）

main@0587c30 实测原样保留、且官方 CI 全绿背书：

1. `CCDriver.cpp:157` `_CFRuntimeCreateInstance` 多分配 `+sizeof(CFRuntimeBase)`（≈8B，无危害）
2. `Tools/CCSDK.cpp:95` `CFURLGetString`（file:// 形式）查 SDK 路径——官方绿跑实证可用
3. `Tools/Linker/CCLinker.cpp:92` `if(result == nullptr)` 恒假判断（死代码）

## 五、待落位（后续环）

- ~~N1：CI 下载工具链 Release~~（✅ 2026-10-16 完成：cc-mdk-smoke.yml，run 38936607250 绿）
- ~~N3b：三 zip 载荷 + SDK 内嵌改造~~（✅ 2026-10-17 完成，见 §三 b）
- N4/N5：IDE 层接线（traitChanges 8 处适配在 N4；Shared/{Templates,Themes,ObjCFix,LaunchServices} 目录型资源届时处理）
- N7–N8：0.10.3 运行侧落位（LiveContainer/ProcEnvironment/litehook/Private/WindowServer/Downloader）+ trust 链回归（v28 段随 WANWO_BOOTSTRAP_TRUST 开启）

## 三 c、N4/N5 环修改登记（2026-10-17，IDEFoundation 项目模型 + IDEBuilder 构建编排接入）

适配前置盘点（全部 grep 实证）：设计文档"8 处 registerForTraitChanges"实际全部位于官方 UI 层（未落位，N9+），N4/N5 范围内 0 处——**该适配项不存在**（文档勘误）。Nyxian-Swift.h 桥符号实际仅 2 处真用（NXProject.m→NXOSVersion、NXRemoteCompiler.m→NXApplicationState）。

| # | 文件 | 改动 |
|---|---|---|
| 1 | `IDEFoundation/NXProject.h` | 删 `<LindChain/ProcEnvironment/Surface/trust/entitlement.h>` import（对 trust 层符号零使用实证） |
| 2 | `IDEFoundation/NXProject.m` | `Nyxian-Swift.h` → `WanWo-Swift.h`（消费 Swift @objc 类 NXOSVersion，L237-238） |
| 3 | `IDEFoundation/NXRemoteCompiler.m` | **万我空壳实现**整体替换：原实现为 compilerd 守护进程远程编译客户端（PELaunchServiceManager/PEProcessObserver/Nyxian-Swift，未落位层）。万我拍板 ⑤ compilerd 默认关 → isAvailable=NO/newRemoteCompiler=nil/实例方法全 NO/nil/空；NXBuilder 回退本地 MDKDependencyScanner（init 逻辑原样）。`.h` 原样未动 |
| 4 | `IDEBuilder/NXPhaseRunner.m` | `<UI/XCodeButton.h>` → `XCButtonCompat.h`（N3b 已建壳） |
| 5 | `IDEBuilder/NXBuilder.swift` | 三段宏守卫：`.run` 分支整支 `#if WANWO_BUILD_RUN`（trust_nxt2_sign×5/ksurface_fs_install_kext_at_path/vnode_refresh_with_path/PERestartSelf/LCUtils×3/LDEApplicationWorkspace×2/LCMapMachO/LCUnmapMachO/checkSigningSetup——全阶段 2 符号，#else 抛"Run 链未启用"）；`.export` 的 kext 分支+拒签段同守卫（app/utility 打包保留=N5 验收路径）；`buildProjectWithArgumentUI`（UI 层辅助全函数）`#if WANWO_BUILD_UI` |
| 6 | `LindChain/Utils/NXOSVersion.swift` | **新建**——自官方 UI 层 iOSVersionPickerView.swift **字节级提取** fileprivate NXSDK 变量 + @objc NXOSVersion 类（纯数据类：MDKSDK/MDKOSVersion/NXBootstrap 依赖全已落位、零 UI 符号；被 NXProject.m/NXBuilder.swift 消费故须脱离 UI 层）。原文件残留 IOSVersionPickerViewController（UI）不提取 |
| 7 | `XCButtonCompat.h/.m`（万我侧） | 补 NXBuilder 消费的 4 方法：startSpinning/startSpinningWithArcFraction:duration:/stopSpinning/switchImageSyncWithSystemName 两形态/updateProgressIncrement:（Swift 名 incrementProgress(withValue:) 别名）——NSNotificationCenter 广播同前 |

**接入清单（19 文件）**：IDEFoundation 10 实现（NXProject/NXPlist/NXType/NXDocument/NXDocumentManager/NXCodeTemplate/NXUser/NXUtils/NXRemoteCompiler 空壳/Project+Debug.swift+已入 NXBootstrap/NXAlertDiagnosticPresenter）+ IDEBuilder 6（NXBuilder.swift/NXBuilder+MDKDriver/NXBuilder+MDKPhaseRunner/NXPhaseEngine.m/NXPhaseRunner.m/LDEFilesFinder.m）+ Utils 3（Zip.m 已入/Swizzle.c→NXPlist.m 消费/NXOSVersion.swift）。**排除**：IconUtils.m（零消费者+ISIcon/bootstrapd 私有类依赖）、CFTools.c/LDEDebouncer.m（零消费者）、NXConsoleView/IDELanguageServer（N6+ 环）。
