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

## 三 d、N5 试验环补登记（2026-10-17，真机 createProject nil 定案）

**勘误**：§三 c 曾判"NXCodeTemplate 属 N6 UI 环可绕开"——**错**。真机实证（N5 试验首跑 createProject 返回 nil）：`NXProject.createProjectAtURL` 内部调用 `NXCodeTemplateMakeProjectStructure`（NXProject.m:359）——**官方工厂与模板系统一体**，无 Templates 资源则脚手架源文件阶段失败。

| # | 改动 |
|---|---|
| 1 | `Vendor/nyxian/Shared/Templates.bundle/`（新建）——官方 `Shared/Templates/` **全量 17 文件字节级落位**（Application/ObjC/UIKit 7+Application/Swift/SwiftUI 2+Application/Swift/UIKit 3+Utility/C 1+Utility/C++ 1+Kext/C 1+目录结构），bundle 形态保结构（Main.c×2 异目录共存无平铺冲突） |
| 2 | `project.yml` 主 target 资源 +1（Templates.bundle 单条目，RootfsPatch.bundle 先例） |
| 3 | `IDEFoundation/NXCodeTemplate.m:37` 读路径 `bundleURL/Shared/Templates` → `bundleURL/Templates.bundle/Templates`（唯一路径拼装点，语义等价） |

试验源码（N5CompileTrial.swift）改用官方模板链（删除自写源文件段）——createProject→模板→buildProject 全官方路径。

## 三 e、N6 收尾三小件（2026-10-17，真机事件流审读产出）

| # | 件 | 改动 |
|---|---|---|
| ① | browser 截图→fs 桶间桥 | `BrowserUseTool` 截图持久化段追加：复制进会话工作区桶 `browser/`，返回文本加 workspace_image_path 行（read_image 直读；修复真机实证的 read_image file not found——browser 桶物理隔离 sessionPersistentDir，fs 解析分支够不到） |
| ② | project 工具 guest 路径提示 | `BuildTools` registerAll/两工具注入 sessionCwd（ShellTool 同款装配），project_create/build_ipa 输出追加 guest bash path 行（修复 AI bash 盲试 6 次找工程） |
| ③ | 自修复场景实测 | 留真机验证：对话让 AI 故意引入编译错误（如写错类型名）→ build_ipa → AI 按诊断修复 → 重建 |

## 三 f、N6 大规模实测修正（2026-10-17，用户 55278 事件流审读产出）

用户侧 AI 对构建功能做 27 次编译压测（12 次失败→12/12 自修复成功、29/29 审批、127 工具调用）。产出修正：

| # | 发现 | 修正 |
|---|---|---|
| 1 | 中文工程名"计算器"：编译 success 但 **ld64.lld 链接失败**（非 ASCII 路径/模块名） | project_create name 校验收紧 ASCII（错误信息附中文名替代路径：建工程后改 Project.plist NXDisplayName） |
| 2 | build 事件 name 丢成 "Unknown"（displayName 展开失败时 BuildResult.projectName 兜底值污染事件） | 事件 name 改用调用入参（确定值） |
| 3 | 诊断摘要 "[MDKDiagnosticLevel(rawValue: 3)]" 不可读 | severity rawValue→显示名映射（error/warning/remark/note） |

**登记不修**（事件流实证的官方边界/无害项）：①`wanwo-build//Cache` 双斜杠（官方拼接形态，路径有效）②0.0s 无诊断失败（NXBuilder init 失败路径无诊断——BuildPanelView 场景补）③`external macro` 失败（@Preview 设备端编译限制——官方边界）。

## 三 g、N6 压测报告 14 条建议处置对照（2026-10-17）

**本轮快修（6）**：①诊断带 file:line:col（DebugItem.sourceLocation 数据在位，摘要输出补齐）②诊断路径相对化（绝对沙盒路径→wanwo-build/ 相对，正则净化）③截断显式（前 50 条+总数提示，压测 G 实证的静默截断）④零诊断失败显式指路（压测 K1 最贵失败类型——plist 损坏/init 失败给检查指引）⑤stop_build 去内部术语（压测 J）⑥build_ipa 输出补 ipa 大小（压测 11 产物暴露）。

**批 2（BuildPanelView 承载）**：级别中文化+配色图标（建议 2 剩余半）/fix-it 折叠（3）/拆阶段耗时+编译文件数（10）/产物摘要面（11 剩余半）。

**登记后续**：~~#Preview 冒烟预检提示（6）~~/~~-O 开关工具参数化（12——AI 实测 -O 可用 1.9→6.7s）~~（两者已随 §三 j 落地）/错误收集上限与批量模式深度改造（5——已提至 50）/并发构建独立输出目录（9——单会话 exclusive 车道已天然串行，跨会话 App 级单飞行门在位）/AppIcon 占位脚手架（13）。

**官方语义不修**：NXDisplayName 与输出路径强耦合（建议 8 主体——vendored NXOutputPath 模板；正确姿势已实证=CFBundleDisplayName 独立设置）。

## 三 j、批 2 第一批（AgentTool 域五件，2026-10-18）

右栏重做（批 2a-1）整体回滚后（14725bc），批 2 中与右栏外壳无关的构建域项先行落地。vendored 官方件零修改——全部在万我层（BuildExt）实现：

| # | 项 | 实现 |
|---|---|---|
| 1 | project_delete（D5 缓解） | 审批级新工具：删 BuildProjects/<name>/ 整目录+Cache/<uuid> 编译缓存；名称校验同 resolveProject（fail closed）+构建在途禁删（isBuilding 门）；刻意不走 NXProject 实例（僵尸工程 init 返回 nil 也能删） |
| 2 | project_reset | 审批级新工具：delete + createOrReuseProject 同名重铺脚手架（一次审批完成两步） |
| 3 | -O 参数化（建议 12） | build_ipa 新增 optimize 布尔参数（默认 false）：持久写入工程 plist NXSwiftFlags 追加/移除 "-O"+reload 生效（官方默认数组无优化等级=swiftc -Onone；AI 实测 -O 1.9→6.7s 换运行性能）；参数即真值语义（false 显式移除）；无变化不写盘 |
| 4 | 宏预检（建议 6） | build_ipa 构建前扫描 .swift 源文件（字面匹配 #Preview/@Observable/@Model——external macro 官方边界 §三 f 实证必败），命中即拦下必然失败的构建（code MACRO_PRECHECK+替代方案指引），省一次审批+数分钟 CPU；注释/字符串误报可接受（提示语注明字面匹配） |
| 5 | D2 出厂模板修正 | createOrReuseProject 新建工程后覆写 Config/Project.plist NXOutputPath → $(CACHEROOT)/Payload/$(NXExecutable).app/$(NXExecutable)（幂等：仅官方默认形态才覆写，AI 自定义不动；best effort 失败不阻塞创建）；plist 写回与官方工厂同构（NSPropertyListSerialization XMLFormat，NXProject.m:336 同款） |
| 6 | D7 模板提示 | project_create/project_reset 成功输出附宏不可用提示（#Preview/@Observable/@Model → ObservableObject/@Published） |

**配套行为优化**：build_ipa 工程定位提前到审批前（工程不存在/名字错不再让用户白批一次）。

**批 2 剩余（挂起待 BuildPanelView=2a-2 随右栏重启）**：级别中文化+配色图标/fix-it 折叠/拆阶段耗时+编译文件数/产物摘要面（原"BuildPanelView 承载"四件——展示层宿主视图未建）；批量模式深度改造/AppIcon 占位脚手架/并发构建独立输出目录（低优先）。

## 三 k、批 2 第一批装机审计与两修（2026-10-18 晚）

**审计方法与结论**：事件流 27379 行分层全量（5 user/17 组审批/81 call+result/11 build 事件/120 reasoning/264 trace）+报告逐条对质+源码对质。**批 2 第一批 7 项测试全 PASS 收官**；17 组审批全发生全放行（用户确认手点）；D1 文件 App 可见性实证。

**两修（84dac84 后补丁）**：

| # | 项 | 根因与修法 |
|---|---|---|
| 1 | 宏预检 files 相对化失效 | 双侧路径形态失配（/var/mobile 符号链接 vs /private/var/mobile 真实）致 hasPrefix 失配→绝对路径直出。修：rootPath 与枚举路径双侧 resolvingSymlinksInPath 对齐真实路径。拦截功能本就正常，纯输出质量。 |
| 2 | DeriveFold harness 断层（AI 收不到工具文本） | build_ipa 先落 extension/build 事件（modelVisible→折叠成 user 消息）后落 tool/result，DeriveFold 步骤 4「普通消息关闭未决对」把 result 判孤立剔除→步骤 5 合成 "tool execution was interrupted before completion" 占位——AI 永远收不到 BUILD OK/optimize 状态/workspace ipa 文本，只能靠 extension-event 兜底（装机审计实锤：34 处 interrupted 全在 AI 侧 reasoning/报告，事件流 tool/result 完整且 81/81 一一对应）。修：折叠时未决调用（openCalls 非空）期间的 extension 消息推迟缓存，收齐 results 后按序 flush——保持 provider-valid（assistant→tools→user）顺序；步骤 4/5 防御保留。**dsh 语义源对照**：repair.ts 的 interruptedTurnClosers 为崩溃恢复专用（逐 turn 重置+仅尾部合成），且 dsh 无 extensionEvent 机制——本修属万我扩展自适应，非语义偏离。 |

**升级登记（原 §三 h 末尾"build_ipa 经 run_code 通道的 interrupted"）**：该现象非 run_code 通道特有——所有先落 modelVisible 事件再落 result 的工具调用（本版即 build_ipa 全部 11 次）都触发占位合成；宏预检（失败路径不写事件）与 project_create/reset/delete（不写 build 事件）不受影响——与本次根因分析完全吻合。本修后工具文本直达 AI。

**审计新发现登记（低优先/待拍板）**：①BuildArtifacts 文件名用 displayName（中文名→"测试.ipa"，与 ipaURL 名不同源；对文件 App 直观，用户拍板保持现状）②诊断 file 键含 uuid 尾段（[1385895/Broken.swift:4:24]）=官方 debug.json 键形态既有 ③D6 精细画像：guest readdir 陈旧但完整路径 lookup 实时，AI 已自适应，危害降级 ④预检失败不写 debug.json（AI 建议+code 字段透出——低优先）⑤**D6 已修两段**：prompt 级（ShellTool description 明示，955b280）+**元数据补注册根治（用户拍板实施）**——BuildService.registerProjectTreeInFakefs（create/reset 建目录树枚举补注册）+BuildIPATool BuildArtifacts/ipa 复制后注册（复用 ensureFakefsMetadata 钩子，零 vendored 改动）⑥**lld 污染事前拦截（用户拍板实施）**：诊断含 duplicate symbol → 进程级污染标志 → 后续 build_ipa 事前失败+重启指引（LLD_CONTAMINATED）——把随机闪退转明确失败。

## 三 l、深水区研究终审（2026-10-18 晚，analysis/lld-uaf-d6-research-20261018.md + issue 草稿 analysis/lld-upstream-issue-draft.md）

- **lld UAF 根因（上游源码级实锤，swift-6.4.0-RELEASE 与 llvm main 同构）**：`lld/MachO/SymbolTable.cpp` 的 `dupSymDiags`（D134794 引入）文件级静态 **无 clear**（对照 undefs 有 clear=疏漏）；元素 `const Symbol *sym` 指向 per-link SymbolTable arena——同进程第二次链接 arena 释放后 Writer::run **无条件重放**残留诊断 → `toString(*悬空 sym)` UAF。src1/src2 是 std::string 值拷贝（StringRef 悬空论否证）。lld CLI 单进程单链接不触发→上游无感知。**万我侧拦截已落地（⑥）+上游 issue 已提交：llvm-project#233265（2026-10-19 00:3x，用户授权经 gh 账号 Da-AiXZ 提交，https://github.com/llvm/llvm-project/issues/233265）**。
- **D6 根因（本地源码实锤）**：万我 guest rootfs=iSH fakefs 混合模式——目录元数据在 **meta.db paths 表**（fake-db.c，`ensureFakefsMetadata` 直写该表；RootfsInstaller.swift:366 自证注释「Register in fakefs meta.db so iSH kernel can see the file」），文件内容在真实 FS。host 直写不注册→guest readdir 不可见（lookup 实时兼容）。**元数据补注册已落地（⑤）**。

## 三 h、N6 三小件验证 + AI 深度压测报告处置（2026-10-17，第三份事件流 70007 事件）

**三小件生效实证**：guest bash path 22 次、诊断三件（file:line:col/级别名/相对化）全对（`[error] [ContentView.swift:8:9]`）、自修复闭环（BuildSmoke/Demo 失败→修→成功）。**AI 走 run_code（JSCore PTC）通道派发**——39/39 审批、35 次编译全通，等效验证双呈现模式。

**AI 自写报告（23 项矩阵+D1-D9 缺陷）处置**：
| # | 缺陷 | 处置 |
|---|---|---|
| D3 | success 误显"零诊断失败"指路文案（我的 D3 文案 bug） | 已修：零诊断文案分 success/failure 两态 |
| D8 | 同位置重复诊断 2-3 条 | 已修：file:line:col:message 去重 |
| D9 | build_ipa("") 空/异常名触发 0.0s 垃圾构建 | 已修：resolveProject 防空名/分隔符退化（nameDir==根 fail closed） |
| D1 | ipa 产物 guest/工作区不可见（构建成功只能信返回值） | 已修：成功后 ipa 复制进会话桶 BuildArtifacts/<name>.ipa + workspace 路径输出 |
| D5 缓解 | 僵尸工程 0.0s 不可恢复 | ✅ 批 2 已修：project_delete/project_reset 工具（审批级+构建在途禁删；不依赖 NXProject 可解析——僵尸工程可删）；删除范围=nameDir 全部+Cache/<uuid> |
| D2 | 显示名空格/中文→.app 目录与 macho 不一致（官方 NXOutputPath 模板） | ✅ 批 2 已修：createOrReuseProject 新建即覆写 NXOutputPath → $(CACHEROOT)/Payload/$(NXExecutable).app/$(NXExecutable)（幂等：AI 自定义值不动；NXDisplayName 仍独立服务 CFBundleDisplayName） |
| D4 | build_log 单行退化 | 已在修⑤⑥覆盖（file:line:col+级别名） |
| D6 | guest ls 与 host 写入视图不一致 | M4-E 挂载语义既有——登记（AI 已自适应改用 fs 工具） |
| D7 | 宏插件缺失（@Observable/@Model） | ✅ 批 2 已修（提示面）：project_create/project_reset 输出附宏不可用提示 + build_ipa 宏预检（见 §三 j） |

**build_ipa 经 run_code 通道的"interrupted"**：长阻塞超 harness 时限被打断，AI 自适应从 extension-event 读结果——事件通道兜底有效，登记（阶段 2 可考虑异步任务形态）。

## 三 i、闪退定罪与兜底加固（2026-10-18，真机 .ips+事件流 87002 行+源码四级定罪）

**闪退现场（10-17 23:38:07.6，iPad13,4 iOS 16.6.1）**：同一进程内「duplicate symbol: main 链接失败 → 删探针文件 → 立即重建」的第二次链接中，`lld::macho::reportPendingDuplicateSymbols()`（writeResult 路径）构造错误字符串时 UAF（memmove 踩已释放 MALLOC_LARGE 块边界）→ SIGSEGV → 全 App 闪退。跨进程重建正常（restart 后 Demo BUILD OK 0.7s 无诊断）；官方 `syncFolderStructureToCache`（NXProject.m:412）stale .o 清理有效、源文件列表每次现扫（NXPhaseEngine.m:32）——排除 stale .o 假说，定性为 **lld 库形态进程内二连跑状态残留**（精确残留点在 llvm-project lld 内核，登记深挖）。LLVM 两层 CrashRecoveryContext::RunSafely 全程旁路的机制=CoreCompiler `llvm_init()`（constructor）Enable() 注册的全局 handler 被 iSH `install_jit_crash_handler()`（boot 时）覆盖；非 iSH 线程分支 SIG_DFL+re-raise 直接死。「回合被中断」事件=InterruptedTurnClosers resume 修复合成（设计内）。

**vendored 改动（2 处，行为补全非语义变更）**：
| 文件 | 改动 | 理由 |
|---|---|---|
| `Vendor/nyxian/CoreCompiler/Tools/Linker/CCLinker.cpp` | ①`int retCode;`→`int retCode = 1;`（初始化）②`CRC.RunSafely(...)` 接返回值，false 时追加诊断行 `[CoreCompiler] linker internal crash recovered (CrashRecoveryContext); rebuild may need a clean state` 并置 retCode=1 | 官方原样在「崩溃被兜底」路径上读未初始化 retCode（UB，可能误报成功）且无恢复分支——兜底加固生效后该路径成为活路径，必须行为正确 |
| `Platform/ISHKernel.m`（万我自有层，非 vendored） | `install_jit_crash_handler()` 保存被覆盖的旧 handler（sigaction 第三参）；`jit_crash_handler` 非 iSH 线程分支由「SIG_DFL+re-raise」改为「恢复旧 handler+return 交回」 | 交回后：崩溃在 RunSafely 内→LLVM longjmp 兜底转诊断（进程存活）；其他上下文→LLVM 官方 Disable()+raise() 回 SIG_DFL，结果与旧路径等价、无死循环（swift-6.4.0-RELEASE CrashRecoveryContext.cpp 逐行实证） |

**iSH guest 侧两分支（JIT 恢复/guest 线程泊车）零改动**；SIGABRT 本就未由 iSH 拦截，行为不变。

**登记后续**：lld `reportPendingDuplicateSymbols` UAF 精确残留点（llvm-project swift-6.4.0-RELEASE lld/MachO 内核，候选=ErrorHandler 全局 static/context 悬挂指针）——上游级深挖；受控复现（A1 duplicate main→删→重建）作为兜底加固的真机验收，预期「不再闪退+AI 收到 recovered 诊断」。

## N7a、签名链落位第一段（2026-10-19，方案 analysis/n7-signing-chain-plan.md，用户拍板三项：交付语义=BuildArtifacts/密码 Keychain/adhoc 证书可用）

**来源与裁剪**：LiveContainer 49 文件 + OpenSSL.xcframework 整体自 0.10.3（`_nyxian_probe/0.10.3/Nyxian-0.10.3/Nyxian/LindChain/`）。**编译面裁剪**：仅 ZSign 纯净子集 15 文件（zsigner.m + zsign.mm/Utils.mm + 5 .cpp + common/7 .cpp——include 闭包仅 openssl+标准库）；LC 层 .m（LCBootstrap/LCUtils/LCMachOUtils/utils）依赖闭包大（Private/litehook/ProcEnvironment/applicationmgmtd，host 直查源码实锤）落目录不编译（N8/N9 按需扩大）；Tweaks 9 文件（guest appex 专属）同。

**接缝结论（三方对照实锤）**：①万我 NXBuilder.swift .run 分支与 0.10.3 Core/Builder.swift:295-325 逐行同构，唯 `trust_nxt2_sign` 是 main 专属（ksurface 微内核体系，0.10.3 全树零命中——main 版 ProcEnvironment +40,400 行重构引入）②**替代=ZSigner.adhocSignMachOAtPath:bundleId:entitlementData:（0.10.3 Builder.swift:437 utility 分支上游先例，纯 ZSign 无内核依赖）**③checkSigningSetup（main UI/CodeSigCheck.swift）0.10.3 无对应物，万我自实现④LDEApplicationWorkspace=0.10.3 guest daemon（applicationmgmtd），N9 范畴不落位⑤kext 分支符号（ksurface_fs_install_kext_at_path 等）依赖越狱形态，维持 WANWO_BUILD_RUN 守卫。

**结构适配（diff 登记）**：
| # | 项 | 说明 |
|---|---|---|
| 1 | OpenSSLHeaders/openssl/ 重排头目录（新建，140 头） | xcframework Headers **平铺**（实测无 openssl/ 子目录、无符号链接）——`<openssl/xxx.h>` 尖括号引用无法从 Headers 根解析；重排副本供 ZSign 编译（HSEARCH 第 7 根）。【N7 重考古修正 2026-10-19】压缩前「官方从未编译 ZSign」结论**错误**：0.10.3 用 Xcode 16 文件系统同步组（Nyxian/ 全树默认编入 emexDE 主 App，例外清单仅排除 18 文件——ZSign 全部+LCUtils.m+LCMachOUtils.m 均在官方主 App 编入面；grep 文件名验证法对同步组形态天然失效）。官方头解析机制=FRAMEWORK_SEARCH_PATHS+macOS 大小写不敏感 FS（`<openssl/ssl.h>` 命中 OpenSSL.framework/Headers）；万我重排副本等效且 CI 验证绿，保留 |
| 2 | LCUtils 证书读取未适配 | 0.10.3 原实现读 NSUserDefaults（LCCertificateData/Password）——N7b 证书 UI 时按万我存储（Keychain）适配该函数或走 ZSigner 直调绕过 |
| 3 | OpenSSL embed | 官方 pbxproj 同形态（CodeSignOnCopy+embed Frameworks）；XcodeGen embed 坑同款——ios.yml 手动 cp+计数门（含 Products 未产出时从 xcframework ios-arm64 切片直取兜底） |

**N7b/c 待施**：证书 UI（设置页 section+Keychain+validateCertificate）→ .run 分支接缝改写（trust_nxt2_sign→ZSigner.adhocSignMachO + checkSigningSetup→万我 SigningSetup + installApplication 维持守卫抛 N9 指引 + WANWO_BUILD_RUN/WANWO_INSTALL 双门）。

### N7a 重考古修正与收官（2026-10-19，run 39157577438 SUCCESS 10m21s）

**四处压缩前错误结论修正**（方案定稿版 analysis/n7-signing-chain-plan.md §〇）：
1. 「官方从未编译 ZSign」→ 同步组全量编入（见上表 #1 修正）
2. 「trust_nxt2_sign 替代=adhocSignMachO」→ trust_nxt2_sign（main signing.c:257）与 macho_after_sign（0.10.3 trust.c:212）**同族**：均为标准签名后追加 ksurface entitlement token（EC 私钥签 blob，NXTR/NXT2 tag）——服务 Nyxian 自家运行时进程信任，**非标准签名**。N7 无 ksurface 消费方→跳过；**NXSignMachOWithNyxianEntitlements 官方默认 true**（NXProject.m:82）→ N7c 须出厂 gate false（export 分支开 WANWO_BUILD_RUN 也会撞 vendored trust_nxt2_sign 调用）；N8/N9 落位 PEProcessManager/LiveProcess 时再启用
3. 「OpenSSL 头解析无官方先例」→ 官方机制=FRAMEWORK_SEARCH_PATHS+大小写不敏感 FS+同步组 xcframework 自动链接/Embed
4. 「ZSign 首编通过（Smoke 绿）」→ 绿的是 CC-MDK Smoke（不含主 App）；iOS Build 实际红，经四连修复绿

**N7a CI 四连修轨迹**：①182fa87 YAML 双冒号非法 ②4391923 HSEARCH+ZSign/common（fs.cpp 引号 include 不跨目录）③bb684e3 HSEARCH+ZSign/ 根（"Utils.hpp"/"common/xxx.h" 跨目录形态；15 文件 include 全量清点 45 条后仅此一缺）④4ccad43 OpenSSL 链接直连——XcodeGen xcframework deps 条目不生成 -framework 旗标（Ld 统计实证），删无效 deps+OTHER_LDFLAGS 并入 -framework OpenSSL+FRAMEWORK_SEARCH_PATHS 指 ios-arm64 切片（ld 不直接吃 xcframework）。

**N7a 最终形态（CI 全绿）**：LiveContainer 49 文件+OpenSSL.xcframework 落 vendored；ZSign 纯净子集 15 文件编译；HSEARCH 10 根；LDFLAGS+FSEARCH 直连 OpenSSL；ios.yml embed 双保险（cp+xcframework 直取+test -f 硬门）。

**N7c 修正版接缝要点**：vendored NXBuilder.swift .run 分支维持 WANWO_BUILD_RUN 宏关闭（main 版符号面 vs 0.10.3 vendored 库接口差异——LCUtils.signMachOWithoutPatchAtURL 仅 main 有、validateCertificate 两版签名不同、LCMapMachO 为 main 形态）；万我 BuildService 层按 0.10.3 Builder.install(.RunningApp) 语义重实现签名编排（BuildResult.bundleURL→ZSigner.signWithAppPath，**不 patch**——LCPatchExecSlice="Literally convert an executable to dylib"属 LC 容器化运行核心，归 N9 与 litehook.c 一起）；证书 UI 官方只导 p12+密码（prov=宿主 embedded.mobileprovision）→万我 unsigned 分发需导入式 profile（LiveContainer 上游三件套形态）+Keychain 存密码。

## N7b、证书管理三件（2026-10-19，方案 §二 N7b-1/2/3，用户拍板：签名 bundle 交付 BuildArtifacts/密码 Keychain/用户有 adhoc p12+profile）

**性质**：万我层新写（零 vendored 改动）——语义移植自 0.10.3 官方证书 UI（CertificateController/CertificateImporter）与 main 版 checkSigningSetup（UI/CodeSigCheck.swift），SwiftUI 呈现。

| # | 万我落点（新文件） | 来源 | 裁剪/适配 diff |
|---|---|---|---|
| 1 | `WanWo/Features/BuildExt/CertificateStore.swift` | 官方 CertificateImporter 存储语义（NSUserDefaults 三键 LCCertificateData/Password/UpdateDate） | ①载体升级：密码→Keychain（kSecClassGenericPassword，service `com.wanwo.signing` 与 credentials/mcp 同形隔离，复用 KeychainStore 既有 SecItem 形态——用户拍板）；p12/profile 二进制大件→沙盒 Application Support/WanWoSigning/ 文件（Keychain 适合小 secret，大件文件+沙盒保护是平台主流）②官方只导 p12+密码（prov 取宿主 embedded.mobileprovision）→万我 unsigned 分发无宿主有效 profile，改导入式三件套（LiveContainer 上游形态）③接口：save(p12:password:profile:)/loadCertificateData()/loadPassword()/loadProfileData()/isConfigured/importDate/clear |
| 2 | `WanWo/Views/Settings/CertificateSettingsView.swift` | 0.10.3 CertificateController（状态行+导入入口）+ CertificateImporter（导入表单） | ①UIKit 表单→SwiftUI List/Form（文案语义照抄："Certificate Valid Till"→"有效期至"、密码 hint "i.e 123456" 原样、导入失败红字=官方 NotifyUser(.error) 行内化）②状态行三态：未配置灰/有效绿（checkCert status==0+expirationDate）/失败红——官方 updateCertificateState 同构③导入 sheet 两段 fileImporter（p12+mobileprovision——比官方多一段描述文件选择器）+SecureField+提交；官方 Data(contentsOf:) 直读→补 security-scoped 作用域纪律④新增「清除证书」（官方无——万我三件可逆管理，confirmationDialog 二次确认） |
| 3 | `WanWo/Features/BuildExt/SigningSetupService.swift` | main 版 checkSigningSetup（UI/CodeSigCheck.swift:61，140 行三段） | ①extension 存在性/entitlement 两段（extensionExists+get-task-allow）**不做**——万我暂无 appex，服务 LC 容器化运行链归 N8/N9②validateCertificate 段改 ZSigner.checkCertWithProv:key:pass: 直调（ZSigner 主 App 编译面 N7a 落位；LCUtils.validateCertificate 底层同此调用，绕过其 NSUserDefaults 证书读取缝）；prov=用户导入的 mobileprovision 数据（非宿主 embedded）③async/await 桥接（withCheckedContinuation），产出 SigningCertificateStatus 读视图（N7c 签名编排 gate 共用） |
| 4 | `SettingsPanelView.swift` 枚举扩展 | — | SettingsPane 加 `.certificate` 案（title 签名证书/icon checkmark.seal/destination CertificateSettingsView）+contentBody 路由；WOSettingsModal.paneContent 穷尽 switch 同步；UIBatch3Tests 分区计数断言 8→9 合法演化（CI修17 判卷先例） |
| 5 | `WanWo/Bridge/WanWo-Bridging-Header.h` | — | 加 `#import <LindChain/LiveContainer/ZSign/zsigner.h>`（纯 ObjC 仅 Foundation，可桥；既有注释风格照抄） |

**ZSigner 桥接实际形态**：`checkCertWithProv:key:pass:completionHandler:` → Swift `ZSigner.checkCert(withProv:key:pass:completionHandler:)`（首参 merge 进方法名）；block `(int, NSDate*, NSString*)` → `(Int32, Date?, String?)`；返回 int 为同步前置失败码（丢弃，回调路径为权威判定；status==0=有效）。

**N7b 装机复测修（2026-10-19 14:5x，用户实测反馈「证书栏点击没反应/描述文件正常」）**：CertificateSettingsView 同视图双 `.fileImporter` 修饰符 SwiftUI presentation 抢占（仅最后声明者生效——描述文件能弹、p12 静默无反应），叠加 `UTType(tag:)` 动态解析 UTI 在文档选择器呈现的不可靠性。修=合并单一 fileImporter（allowedContentTypes=[.data] 全量）+ 按扩展名 routePickedFile 自动分流（p12/mobileprovision→对应段，其他→行内红字），typeForExtension 废弃删除。教训：SwiftUI 同视图多 presentation 修饰符必炸——单实例+分流是文件多类型选择的防弹形态。

### N7c、签名编排（2026-10-19 15:2x，方案 §二 N7c 修正版接缝表落地）

**范围**：build_ipa 加 `sign` 布尔参数——构建成功后 ZSign 签 bundle（用户导入证书三件）+ 重打包 ipa（可安装产物）。**不 patch**（LCPatchExecSlice="convert executable to dylib"属 LC 容器化运行核心，归 N9 与 litehook 一起）。

| # | 项 | 说明 |
|---|---|---|
| 1 | BuildResult.signNote 字段 | 签名编排独立注记（nil=未请求/成功=「签名完成」/失败=原因）——构建本体成功与签名结果分离，AI 可针对性重试；build 事件 payload 增 sign 键（AI 跨回合可读） |
| 2 | BuildService.signAndRepackage | 官方 0.10.3 Builder.install(.RunningApp) 签名段同构：semaphore 等待 ZSigner.signWithAppPath 回调（semaphore.wait 阻塞 MDK 线程=官方同款形态）→ zipDirectoryAtPath 重打包（桥接头 Zip.h 既有）；prov=用户导入 profile（导入式三件套语义） |
| 3 | BuildIPATool sign 参数 | sign=true 且 CertificateStore.isConfigured=false → 构建前快速失败 SIGN_NOT_CONFIGURED（不浪费数分钟 CPU）；审批文案条件化（「编译并签名」）；输出 sign 行 |
| 4 | 出厂 gate（NXSignMachOWithNyxianEntitlements=false） | 新建工程显式写 false（官方默认 true NXProject.m:82）——防 WANWO_BUILD_RUN 开宏当天 vendored .export/.run 分支撞未落位的 trust_nxt2_sign（ksurface token 体系归 N8/N9）；键缺失才写（幂等，AI 显式改 true 尊重之） |

**接缝状态**：N7a（引擎编译面）→ N7b（证书三件+校验 gate）→ N7c（编排接线）全通，剩 N7d=用户 adhoc 证书端到端（sign=true 构建→产物巨魔安装运行）。trust_nxt2_sign/macho_after_sign（ksurface token）与 installApplication/spawn 维持 N8/N9。

**N7c 装机复测修（2026-10-19 17:5x，用户轻松签实测「签名 ipa 装上后点开提示无法安装」+事件流 17518 行审计+源码对质三根因）**：
1. **embedded.mobileprovision 缺失**——vendored zsign.mm:65 硬编码 `bDontGenerateEmbeddedMobileProvision=YES`（0.10.3 官方行为：guest 包 profile 由其容器体系自带）→ 万我侧签名前补写 profile 进 bundle（零 vendored 改动）。
2. **bundle id 错配**——用户证书 profile 为固定 id（application-identifier=NL6UD7G49R.com.cert.account.t260930000125 非通配）vs 工程 Info.plist=com.wanwo.testapp → 签名前读 profile（CMS 包裹明文 plist 截取解析，零依赖）改写 Info.plist CFBundleIdentifier 对齐（共享证书标准做法=轻松签/爱思签同款；通配 profile 跳过；解析失败诚实注记）。交付产物身份=profile 身份。
3. **signFailedFiles 被吞**——zsign.mm:121 部分文件签名失败仍回调 YES → signAndRepackage 对 error 非空的 success 如实上报「部分文件签名失败（产物可能不可用）」。
4. 顺带清理 zsign_cache.json 残留（AI 实测进包垃圾）；「打包快照过期」假说被源码否证（Zip.m zipDirectoryAtPath 全量枚举无过滤无缓存——是 zsign 压根没写）；_CodeSignature/CodeResources 不落盘非致命（iOS 校验读主二进制 blob 内资源清单）。设备 AI 侧「沙箱无签名工具无法单独签名」判断正确（CertificateStore 在 host 沙盒，guest 不可见=设计）。

**N7c 装机复测修·第二轮（2026-10-19 18:4x，复测仍失败+事件流 19649 行再取证）**：signNote 暴露 `signFailedFiles="TestApp.app//private/var/containers/.../WanWo.app/WanWo"`（宿主可执行路径拼进签名对象）+「描述文件解析失败」。源码对质定罪：
1. **bundle.cpp:53-54 双覆写（vendored diff，本轮唯一 vendored 改动）**——0.10.3 把 Info.plist 的 CFBundleExecutable/CFBundleIdentifier 覆写为宿主 App 值（getExecutablePath/getBundleIdentifier——LiveContainer 容器化魔改：guest 签名身份=LC 宿主，zsign_cache.json 的 bundle_id=com.wanwo.juyang.TNHMJ2JNPJ 实锤）。后果：①签名 identifier=宿主 id 与包 Info.plist/entitlements 三方错乱 ②SignFolder 按 bundle_executable 定位主二进制→怪路径→Init 失败→signFailedFiles+跳过（:303-308）③上轮 Info.plist 对齐修复被覆写绕过。**修复=删除两行恢复 zsign 上游语义**（上游 feather/zsign 无此覆写）；与上轮 Info.plist 对齐修复组合后 identifier=entitlements=Info.plist=证书 profile id 三方一致。
2. **TestApp 主二进制的真实签名路径**：GetObjectsToSign 把它按普通 64-bit macho 收进 files 循环（:253-271）用 config["bundle_id"]（=覆写后宿主 id）签名——上轮 md5 变化=被错身份签名；删除覆写后 files 循环与 SignFolder 同源对齐。
3. **profile 解析失败根因**——mobileprovision=CMS(DER) 二进制容器，String(utf8) 整包解码失败 → bundleIdFromProfile 改 Data 字节级 range(of:) 搜索（二进制安全）。
4. **时序修正**——ConfigureFolderSign 内部先 RemoveFileV 删 embedded.mobileprovision 再按 zsign.mm:65 flag 跳过重写（签名前补写被内部删除）；zsign_cache.json 由 StartSign 完成时写出（bundle.cpp:711）→ 补写+清理全部移到 ZSign 之后、zip 之前。
5. 缓存机制澄清：zsign 读缓存在 `./.zsign_cache/`（CWD 相对——万我 CWD=/ 不可写→缓存天然失效→每次 force 全量签名，无增量问题）；`zsign_cache.json`（bundle 内）仅是写出物。CodeResources 不生成=官方刻意（:320 注释「LiveContainer don't need CodeResources」，iOS 校验读主二进制 blob，非致命）。

### N7 正式收官（2026-10-19 20:3x，用户实测：签名 ipa 轻松签直装成功——N7a/b/c/d 四段全闭环）

**最终形态**：`build_ipa(sign=true)` → bundle id 对齐证书 profile → zsign 内部嵌入 embedded.mobileprovision（InitSimple 补存 prov 后 ConfigureFolderSign 条件恢复）→ 完整 CodeResources 资源 seal（标准模式恢复 GenerateCodeResources）→ 签名 identifier/entitlements/Info.plist 三方一致 → 轻松签直装通过「完整性」校验。

**签名链 diff 总账（vendored 3 文件，全部条件化于 wanwo_zsign_host_identity 开关，N9 零返工）**：
| 文件 | diff | 语义 |
|---|---|---|
| bundle.cpp:53-54 | 身份覆写包进 `if (wanwo_zsign_host_identity())` | NO=标准（identifier=包对齐值）/ YES=LC 容器（=宿主，0.10.3 原行为） |
| bundle.cpp:319 | 恢复 GenerateCodeResources（`!开关` 时） | NO=完整资源 seal / YES=官方跳过（LC don't need） |
| openssl.cpp InitSimple | 补存 m_strProvData（`!开关` 时） | NO=zsign 内部写 profile / YES=不写（LC 容器体系管理） |
| zsigner.h/.m | 新增开关函数+setter | 默认 NO；N9 落位时 LC 运行链显式 YES |

**四轮修复链**：①第三轮=身份覆写开关化（用户质询 N9 影响成立——LC 容器模型需要覆写让 guest 签名身份=宿主，dlopen 过 AMFI）②第四轮=InitSimple 补存+CodeResources 恢复（用户对照实验定罪：同证书同包，全能签产物轻松签直装正常、zsign 产物「无法验证其完整性」——变量收敛到 zsign 产物；AI 取证实锤 CodeResources 空壳+profile 缺失）③复查=InitSimple 条件化补齐（LC 模式行为偏差）。

**验证矩阵**：N7a 真机冒烟（test 工程 37KB→50KB 签名版）✓ / N7b 证书导入+OCSP 校验（「证书有效」绿态）✓ / N7c sign 参数全链 ✓ / N7d 轻松签直装能跑 ✓。

**流程教训沉淀**：①pbxproj 考古必须先查 Xcode 16 文件系统同步组（grep 文件名验证法失效）②SwiftUI 同视图多 presentation 修饰符必炸（单实例+分流）③Smoke workflow 绿≠主 App 编译绿 ④vendored 魔改的三态语义必须条件化保 N9（用户质询驱动）⑤对照实验（同证书同包换签名工具）是定位签名问题最快路径。

## N8、运行侧底座落位（2026-10-19 晚，方案 analysis/n8-runtime-foundation-plan.md，用户四项拍板全过；N8a+N8b+pe_smoke 一批）

**来源与锚定**：Nyxian-0.10.3（本地快照 `_nyxian_probe/0.10.3/Nyxian-0.10.3/`，N7a 同源快照）。**编译面镜像依据（pbxproj 亲自复读，两处与任务书/方案预估不符，见"读到的偏差"）**：宿主=emexDE 例外集 798BBD33（Nyxian 树编入 −19 件=JBSupport 2 + LCBootstrap 1 + Tweaks 6（Dead10ccFix/Dyld/NSFileManager+GuestHooks/NSUserDefaults/SecItem/UIKit+GuestHooksInit——QA 审计勘误：原写 Tweaks 5 系算术误差）+ ProcEnvironment 根部 guest 10）+ LiveProcess 组例外集 79BF9840（追加 3 件宿主代理面）；appex=LiveProcess target 例外集 79BF983D（追加 6 件）+ Nyxian 组例外集 79BF9A97（**追加 38 件**，方案预估"约 40"）。

### 落位清单（计数 217 文件）

| 万我落点 | 来源（0.10.3） | 文件数 |
|---|---|---|
| `Vendor/nyxian/LindChain/ProcEnvironment/` | `Nyxian/LindChain/ProcEnvironment/` 整目录 | 154 |
| `Vendor/nyxian/LindChain/litehook/` | 同名整目录 | 4 |
| `Vendor/nyxian/LindChain/Private/` | 同名整目录（含 4 .tbd） | 11 |
| `Vendor/nyxian/LindChain/WindowServer/` | 同名整目录 | 16 |
| `Vendor/nyxian/LindChain/Debugger/{Utils.c,Utils.h,Logger.h}` | 同名（Utils.c=appex 编入面；Logger.h=N8 修⑤补——ServerSession.m:26 import 链必需，其 LogTextView 零符号消费、Logger.m 不落位） | 3 |
| `Vendor/nyxian/LindChain/Utils/Swizzle.m` + `Swizzle.h`(0.10.3 版覆写) | 同名 | 2 |
| `Vendor/nyxian/LindChain/Project/Project+NotificationServer.swift` | 同名（字节级提取，NXOSVersion 先例） | 1 |
| `Vendor/nyxian/Shared/LaunchServices/{containerd,installd}.plist` | 同名（品牌折算） | 2 |
| `WanWoLiveProcess/` | 0.10.3 `LiveProcess/` 整目录（含 Media.xcassets） | 24 |

字节级纪律：`.gitattributes` 增 `WanWoLiveProcess/** -text`（同 Vendor/nyxian 纪律）。

### 编译面（project.yml 逐文件列法）

- **宿主（WanWo target）+80 编译单元**：ProcEnvironment 63（全部 .m/.c −10 根部 guest 件；headers 一律不进 sources）+ litehook.c 1 + Private 2（UIKitPrivate.m/fileport.m）+ WindowServer 8 + WanWoLiveProcess 代理面 3（LDEApplicationObject/LDEApplicationWorkspace/PEContainer.m=官方 79BF9840）+ **LCUtils.m/LCMachOUtils.m 2（官方 emexDE 未排除=在编；MachOObject.m 的 `_OBJC_CLASS_$_LCUtils`/`_checkCodeSignature` 链接闭包必需——N7a"落目录不编译"随 N8 扩面收口）** + Project+NotificationServer.swift 1。
- **退役 1**：`Utils/Swizzle.c`（main 版）出宿主编译面——全仓 grep 零消费者实证；文件保留在树（CFTools.c 先例）。原因：appex Tweaks 消费 0.10.3 `swizzle_objc_method` API，与 main 版 `SwizzleObjCMethod` 同头路径不同契约——`Swizzle.h` 覆写为 0.10.3 版后 main 版 Swizzle.c 不再可编。
- **appex（WanWoLiveProcess target，type: app-extension）44 编译单元 + 1 资源**：官方 79BF983D 6 件 + 79BF9A97 38 件逐件换算（LiveContainer LC 层/Tweaks/ZSign Utils.mm/ProcEnvironment guest 子集/Utils 三件）；`Utils/CFTools.c`（万我树字节一致）与 `Utils/Zip.m`（万我 main 版替代 0.10.3 版——头契约超集一致、appex 编译单元零调用差异）复用既有落位；`Media.xcassets` resources。settings 同构官方 1287-1316（PRODUCT_BUNDLE_IDENTIFIER=com.wanwo.juyang.LiveProcess / -DCLIENT_ENV / HSEARCH 两根 / LD_RUNPATH 三项 / -Wl,-U,_OBJC_CLASS_$_FBSSceneParameters,-Wl,-U,_OBJC_CLASS_$_LSApplicationWorkspace,-larchive / SKIP_INSTALL / 16.0 / DEAD_CODE_STRIPPING=NO / GCC_OPTIMIZATION_LEVEL=s / INFOPLIST_FILE+GENERATE_INFOPLIST_FILE+CODE_SIGN_ENTITLEMENTS=LiveProcess.entitlements）。
- **主 target settings 合并（单 key 纪律）**：OTHER_CFLAGS 追加 `-DHOST_ENV`；HEADER_SEARCH_PATHS 追加第 8 根 `$(PROJECT_DIR)/WanWoLiveProcess`（`<LindChain/Services/...>` 宿主代理头）；FRAMEWORK_SEARCH_PATHS 追加 `$(PROJECT_DIR)/Vendor/nyxian/LindChain/Private/Frameworks`（官方 :1794-1798 同款——FB*/RBS* 私有类经 4 个 .tbd 解析）。dependencies 增 `- target: WanWoLiveProcess`（无 embed——ios.yml 手动 cp；注：project.yml 既有两个 target 级 dependencies 块 YAML 重复 key，pyyaml last-wins 实证生效块为第二块，依赖两处同写双保险）。
- **ios.yml**：Package 步骤 cp appex → `Payload/WanWo.app/PlugIns/`、cp 两 plist → `Payload/WanWo.app/Shared/LaunchServices/`（目录结构保真——PELaunchServiceRegistry 读 mainBundle/Shared/LaunchServices/）+ 计数门 test -d/-f×3 + unzip -l 三查。

### 品牌折算与 vendored diff 总账（逐处）

| # | 文件:行 | 前后 | 性质 |
|---|---|---|---|
| 1 | ProcEnvironment/Process/PEProcessManager.m:30 | `<emexDE-Swift.h>`→`<WanWo-Swift.h>` | 任务书列明 |
| 2 | ProcEnvironment/Process/PEExtension.m:37,76 | `LiveProcess.appex`→`WanWoLiveProcess.appex` ×2 | 任务书列明（1 文件 2 处） |
| 3 | ProcEnvironment/Process/PEProcess.m:99 | sceneID 前缀 `@"LiveProcess"`→`@"WanWoLiveProcess"` | 任务书列明 |
| 4 | WindowServer/Session/NXWindowSessionTerminal.m:26 | `<emexDE-Swift.h>`→`<WanWo-Swift.h>`（守卫内） | 任务书列明 |
| 5 | WanWoLiveProcess/.../LDEApplicationWorkspace.m:28 | `<emexDE-Swift.h>`→`<WanWo-Swift.h>` | 任务书列明 |
| 6 | WanWoLiveProcess/.../LDEApplicationWorkspace.m:71 | `connectToService:@"com.cr4zy.installd"`→`com.wanwo.installd` | **任务书未列，grep 自查铁律命中**——宿主代理连接串须与折算后 plist 对齐，否则 connect 失败 |
| 7 | WanWoLiveProcess/.../PEContainer.m:65 | `connectToService:@"com.cr4zy.containerd"`→`com.wanwo.containerd` | 同上（XPC 往返/probe 必需） |
| 8 | WanWoLiveProcess/.../PEContainerService.m:36 | `servcieIdentifier` 返回值→`com.wanwo.containerd` | 同上（daemon 身份+PECTL_LS_SET_ENDPOINT 注册键） |
| 9 | WanWoLiveProcess/.../LDEApplicationWorkspaceInternal.m:563 | `servcieIdentifier` 返回值→`com.wanwo.installd` | 同上 |
| 10 | WanWoLiveProcess/.../LDEApplicationWorkspaceInternal.m:104 | dispatch queue label→`com.wanwo.installd.workspace` | 同上（品牌串） |
| 11 | Shared/LaunchServices/containerd.plist:6 / installd.plist:6 | `com.cr4zy.containerd/installd`→`com.wanwo.*` | 任务书列明（PEIntegratedServiceClass 类名不动） |
| 12 | WanWoLiveProcess/Info.plist:11,14 | CFBundleURLName `com.kdt.livecontainer.extensionurlscheme`→`com.wanwo.juyang.liveprocess`；scheme `liveprocess`→`wanwo-liveprocess` | 任务书列明（NSExtension AR viewer/FALSEPREDICATE/XPCService 原样） |
| 13 | ProcEnvironment/Surface/sys/compat/pectl.h:29 | 注释示例串 `com.cr4zy.containerd`→`com.wanwo.containerd` | grep 自查铁律命中（注释，机械折算） |
| 14 | NXWindowSessionTerminal.m 全文件 | 整实现包进 `#if defined(WANWO_BUILD_UI) && WANWO_BUILD_UI`（头部换 `<Foundation/Foundation.h>`+守卫内 `WanWo-Swift.h`，文件尾加 #endif；其余逐行与官方一致） | **见"读到的偏差"#3** |

### UI 层 Swift 符号缺口三处置（任务书 diff 清单未覆盖，均走万我先例，主理人报备在案）

1. **NotificationServer**（PEProcessManager.m:144 消费）：官方 0.10.3 LindChain 层 `Project/Project+NotificationServer.swift` 字节级提取落位+宿主编入（NXOSVersion.swift 先例；纯 UIKit/Foundation 自包含）。零逻辑 diff。
2. **ApplicationManagementViewController**（LDEApplicationWorkspace.m:364/371 observer 回调）：万我侧新建 `WanWo/Features/BuildExt/ApplicationManagementCompat.swift`（@objc 同名类，+shared+两个 no-op 回调——XCButtonCompat 先例；协议回调不可缺，缺失=daemon 侧 ObjC 消息派发异常）。vendored 零额外 diff。
3. **TerminalViewObjC/TerminalView**（NXWindowSessionTerminal.m 整文件依赖 UI/UIInit/Terminal.swift→SwiftTerm SPM+currentTheme/gibDynamicColor）：整实现包进 WANWO_BUILD_UI 宏守卫（NXBuilder.swift buildProjectWithArgumentUI 先例 §三 c #5），宏不定义=空编译单元零符号泄漏；**N10 UI 批次接 SwiftTerm SPM 后开宏激活**（主理人批准处置③：守卫只包 .m 实现体、NXWindowSessionTerminal.h 声明面无守卫编译自洽——全树仅其自身 .m 引用；SwiftTerm SPM 引入属 N10 用户拍板项，本批禁止引入）。备选（SwiftTerm SPM 接入+多层 UI shim）未动工。

### 万我层新增（非官方代码）

| 件 | 说明 |
|---|---|
| `WanWo/Features/BuildExt/ApplicationManagementCompat.swift` | 见上 #2 |
| `WanWo/Features/BuildExt/PESmoke.swift` | pe_smoke 冒烟工具（形态 A）：status（只读：liveProcessIsAvailable+PEBootstrapRegistry endpoint 数+两 daemon pid/autorestart 直译）/probe（只读：PEContainer containerRoot+isReadableFileAtPath 两次 XPC 往返证明句柄传输）/recycle（驱动级审批：terminate→轮询 autorestart 新 pid→宿主存活报告）。AgentTool 注册走 BuildTools.registerAll（8→9 件），recycle 走 ctx.escalationApprover（build_ipa 同缝 fail closed） |
| `WanWo/Features/BuildExt/SigningSetupService.swift` N8 段 | 官方 main checkSigningSetup ①②段收口（N7b 预留 stub）：`extensionExists`（PlugIns/WanWoLiveProcess.appex fileExists——liveProcessIsAvailable 的等义实现而非同函数，QA 勘误：liveProcessIsAvailable 真实消费者=PESmoke）+`extensionAllowsDebug`/`profileAllowsDebug`（读导入 profile get-task-allow——万我语义适配：官方读 appex 内嵌 profile，万我 unsigned 分发权威 profile=用户导入三件套；解析复用 N7c 字节级 range(of:) 形态）+`runtimeSetupSummary` 组合读视图（不弹 alert——万我无 NXWindowServer rootVC 呈现缝） |
| `WanWo/Bridge/WanWo-Bridging-Header.h` | 追加 5 头：PEProcessManager/PEBootstrapRegistry/PELaunchServiceRegistry/PEExtension/PEContainer（链上全部纯 ObjC/C 可桥） |

### 读到的偏差（亲自读 pbxproj/源码与任务书或方案不符处）

1. **appex Nyxian 组追加件=38 件非"约 40"**（79BF9A97 实数，含 Debugger/Utils.c——万我树原无 Debugger 落位，本批补 2 文件）。
2. **任务书品牌 diff 清单漏 5 处 com.cr4zy.* 源码字面**（上表 #6-#10+pectl.h 注释）——全部为宿主↔daemon 服务标识配对面（connectToService/servcieIdentifier），不改则折算后 plist 与代码侧标识错配、XPC 连接必败；按"grep 自查落位树无 com.cr4zy 残留"铁律全折算并逐处登记。
3. **NXWindowSessionTerminal.m（WindowServer 16 件之一，拍板项 2 要求全编）整文件依赖 UI 层 Swift 符号链**（TerminalViewObjC→Terminal.swift→SwiftTerm SPM 包+currentTheme+gibDynamicColor），万我均未落位——按原样必编译失败。处置=整实现 WANWO_BUILD_UI 守卫（文件保留编译面、默认空 TU），主理人报备在案；备选=SwiftTerm SPM 接入（需用户拍板远程 SPM 依赖，未动工）。
4. **宿主链接闭包补件**：方案/任务书未列 LCUtils.m/LCMachOUtils.m——官方 emexDE 未排除=在编（N7a 时"LC 层落目录不编译"结论对宿主面而言不完整）；MachOObject.m（宿主编入面 Object 六件之一）硬引用 `_OBJC_CLASS_$_LCUtils`/`_checkCodeSignature`。已按官方镜像编入（依赖闭包 Private/litehook 本批齐备）。
5. **宿主不编 LiveContainer/utils.m**（官方 emexDE 编入=全树语义）：万我最小面内零消费者（surface.m 的 `_NSGetExecutablePath` 由 libSystem 提供；builtin_vm_protect/aarch64_emulate 等仅 appex 面 LCBootstrap/Tweaks/Dyld.m 消费——appex 已编）。面差异登记。
6. **project.yml 双 dependencies 块**：YAML 重复 key，pyyaml last-wins 实证生效块=第二块（此前 CC/MDK embed 条目从未生效——N2 修⑥"死配置"画像同源，构建顺序实际由 scheme 驱动）；本批依赖写两处双保险，存量不动。

### 已知风险（承方案 §三，增量）

- 私有类链接：宿主经 Private/Frameworks 四 tbd+官方同款 FSEARCH；appex 官方零 FSEARCH 仅 -Wl,-U 两私有类——镜像官方，若 Xcode 26.6 SDK 导出面差异→链接期 undefined，预案=按官方形态逐个补 -Wl,-U（先案不动）。
- ignition 递归重试无退避（官方形状）：daemon 起不来会自旋刷日志——pe_smoke status 可观测；万我侧加重试上限需 vendored diff，登记不动（观察优先）。
- ksurface_kinit constructor 时序：PEExtension.m start_environment 在宿主启动最早期跑（建 mach port+listener+拉两 daemon）——boot 面回归观察项。
- Media.xcassets 随 appex resources（TouchBarBezel colorset）——UI 集成 N10，暂无消费方。

### N8 CI 六连修轨迹（每轮消一类错，include/符号闭包全量清点法；2026-10-19 晚，run 39311485682 SUCCESS 13m27s + cc-mdk-smoke 39311485516 SUCCESS 双绿收官）

| # | run 实证 | 根因与修法 |
|---|---|---|
| ① | 39272921786 | appex `UIKitPrivate.h file not found`——官方 Xcode 16 同步组对 target 内全部头建 **headermap**（裸名 quoted include 可解析），逐文件列法无等价物；appex HSEARCH 补 `LindChain/{Private,LiveContainer}` 两根（include 闭包全量清点裸名 quoted include 仅 Tweaks 两处跨目录） |
| ② | 39275217653 | `CFOverwrite` undeclared——CFTools.h/.c 为 **main 版**（CFSwap API）与 0.10.3 版（CFOverwrite，LCBootstrap.m:93 必需）同路径不同契约；main 版全仓零消费者 → 换版 0.10.3（Swizzle 先例同构） |
| ③ | 39277671039 | Swift 导入面三类：PE*Registry.`shared()` 导入为 **Optional 非 IUO**（改 Optional binding）；审计区 `containerRoot` 非可选（运行时 nil 陷阱——probe 第一跳改显式 nullable 的 fdObjectForItem）；ApplicationManagement observer 回调参数改 `Any?`（selector 不变，消除 vendored 类型 Swift 导入依赖——PEProcessManager.h 条件 import 链未达 LDEApplicationObject） |
| ④ | 39281440880 | Swift 导入名收尾：`bootstrap.registry` 属性层 Optional+NSDictionary 桥读、`shouldAutorestart`（getter 名胜出）、`fdObjectForItem(atPath:)`（Swift 改名） |
| ⑤ | 39297725695 前一轮 | `Debugger/Logger.h file not found`（ServerSession.m:26 import 链——首读清点只读了 ServerSession.h 未读 .m 的疏漏）；LogTextView 零符号消费，Logger.h 落位 Logger.m 不落位；全量 `<LindChain/...>` 引用×双树存在性扫描确认无其余缺口 |
| ⑥ | 39297725695 | 宿主链接 `_OBJC_CLASS_$_FBProcess/RBSTarget` undefined——官方同步组把树内 **4 个 .tbd 自动收进 Frameworks 链接阶段**，逐文件列法缺链接输入；OTHER_LDFLAGS 追加 Private/Frameworks 四 tbd 全路径（CCSupportLibs dylib 先例） |
| ⑦ | 39304577904 | 宿主链接 `_swizzle_objc_method` undefined（attrstrnilfix.m 引 0.10.3 API）——宿主补编 0.10.3 Swizzle.m（宿主符号面全量清点仅此一文件；main 版 Swizzle.c 已退役无重复符号） |

**Xcode 16 同步组 vs 逐文件列法三差异（本轮实证，N9+ 施工纪律）**：①headermap 裸名解析（补 HSEARCH 根）②.tbd 自动进链接阶段（补全路径链接输入）③头文件全员在编（本纪律 headers 不进 sources——仅需按符号闭包补编对应 .m）。

### N8 装机复测修（2026-10-19 深夜；CI 绿真机装不上——installd 拒装 appex）

- **报错链（设备实测）**：installd 拒装 `WanWoLiveProcess.appex`，底层 `IXErrorDomain Code=17 "bundleVersion must be set in placeholder attributes for an app extension placeholder"`。
- **根因（直接解包 CI 产物 WanWo-98eed56.ipa 实证）**：宿主 plist 两版本键齐全（CFBundleVersion="3"/CFBundleShortVersionString="0.0.1"），appex `Payload/WanWo.app/PlugIns/WanWoLiveProcess.appex/Info.plist` **两键全缺**。官方 0.10.3 LiveProcess Debug/Release 两 build configuration 均有 `CURRENT_PROJECT_VERSION = $(BUILD_NUMBER)`（pbxproj 1283/1327）与 `MARKETING_VERSION = $(VERSION)`（1301/1345），经 Config.xcconfig（`VERSION=0.10.3`/`BUILD_NUMBER=20260523.26.DEBUG`）构建期合并进最终 plist；万我 appex target（project.yml `WanWoLiveProcess:` settings.base）漏抄两键 + GENERATE_INFOPLIST_FILE=YES 产物补齐不了 → 最终 plist 缺键。CI 免签构建 ValidateEmbeddedBinary 不覆盖此键 → CI 绿装不上。
- **修法**：project.yml appex settings.base 补 `CURRENT_PROJECT_VERSION: "3"` / `MARKETING_VERSION: "0.0.1"`——官方语义即 appex 版本随宿主版本体系注入（Config.xcconfig 同源），万我无 xcconfig 直取与宿主 info.properties 同值对齐（Apple 亦要求 appex CFBundleShortVersionString 与宿主一致）。
- **CI 防回归门**：ios.yml Package 步骤 appex cp 进 PlugIns 后用 `plutil -extract CFBundleVersion raw` / `CFBundleShortVersionString raw`（macOS runner 自带）取值 echo 并断言 "3"/"0.0.1"，任一缺失/异常 `exit 1`——教训显式立门：CI 查不出的键必须门。

#### N8 装机复测修·第二轮（2026-10-19 深夜续；上轮版本键修复设备确认生效后 installd 逐关推进到下一关）

- **第二轮报错（设备原文）**：`MissingBundleDisplayNameString`——appex `WanWoLiveProcess.appex`（ID `com.wanwo.juyang.TNHMJ2JNPJ.LiveProcess`）"does not have a CFBundleDisplayName key with a non-zero length string value in its Info.plist"。上轮补的两版本键已被设备确认生效（installd 越过 bundleVersion 关），本轮卡 displayName 关。
- **对质方法（铁证级）**：解包双成品 ipa 逐键对质——官方 `emexDE-0.10.3-ldid-signed.ipa` 内 `Payload/emexDE.app/PlugIns/LiveProcess.appex/Info.plist` vs 上轮产物 `WanWo-8d79e06.ipa` 内 `Payload/WanWo.app/PlugIns/WanWoLiveProcess.appex/Info.plist`。**键集合差异恰好两个、全为官方有我们没有**：
  1. `CFBundleDisplayName`（官方值=LiveProcess；官方经 `INFOPLIST_KEY_CFBundleDisplayName` 注入，0.10.3 pbxproj 1292/1336 行）——本次拒装直接原因。
  2. `UIMainStoryboardFile`（官方值=空字符串；pbxproj 1294/1338 行 `INFOPLIST_KEY_UIMainStoryboardFile=""`）——同批修净，防第三轮。
  其余同名键值差异（CFBundleExecutable/CFBundleName/CFBundleIdentifier/版本号）均为品牌折算与版本体系合法差异；万我无多出键。网络佐证：CFBundleDisplayName 缺失=Apple 安装校验族已知硬要求（App Store 同族 ITMS-90783、stackoverflow 56807112，修法=补非空值）。
- **修法①（project.yml）**：appex settings.base 补 `INFOPLIST_KEY_CFBundleDisplayName: WanWoLiveProcess`（官方同构品牌折算 LiveProcess→WanWoLiveProcess；与上轮版本键同族机制，`GENERATE_INFOPLIST_FILE: YES` merge 落键）。
- **修法②（源 plist 静态落键）**：`UIMainStoryboardFile=""` 无法走构建设置——Xcode 对构建设置空值不落产物（写不进成品），改在 `WanWoLiveProcess/Info.plist` 源文件静态加 `UIMainStoryboardFile` 键（空字符串；该 plist 为官方文件品牌折算版，本改动登记于本节）。目标=成品键集合与官方完全一致（除品牌/版本值），一次修净。
- **CI 门扩展**：ios.yml Package 步骤版本键门扩展为「appex 必需键族」断言，逐键 `plutil -extract` echo 实值 + 非空/值断言 + `exit 1`：CFBundleVersion="3"、CFBundleShortVersionString="0.0.1"、CFBundleDisplayName 非空且="WanWoLiveProcess"、UIMainStoryboardFile 存在且空串（`-extract` 空串成功返回空输出，显式区分"取到空串"与"键缺失"）、CFBundleName/CFBundleExecutable 存在非空、NSExtension 存在（字典键走 `xml1 -o /dev/null` 子树断言）。
- **QA 误判登记（如实记录）**：上轮 QA 曾判 CFBundleDisplayName 缺失"不阻断仅观感"——设备否决（installd 硬拒装）。教训：installd 对 appex plist 校验**逐关推进**，"下一关查什么"必须以官方成品逐键对质为准，禁推理豁免、禁抽样——逐键全量对质一次修净 + 门一次建全。

## N9、guest 承载全链（2026-10-20，方案 analysis/n9-guest-hosting-plan.md，四项拍板全落锤；N9a+N9b+N9c 一批，N9d 真机验收留待装机）

**来源与锚定**：Nyxian-0.10.3（N7/N8 同源快照）。官方编排对照：`.run` 签名段（Nyxian/LindChain/Core/Builder.swift:283-374）+ 安装链（LiveProcess/LindChain/Services/applicationmgmtd/LDEApplicationWorkspace.m installApplicationAtBundlePath——XPC 2s 超时官方硬编码 :117）+ 信任链（ProcEnvironment/Surface/trust.c:212-276 macho_after_sign）+ spawn/stdio（Builder.swift:321-349 + ProcEnvironment/Process/PEProcessManager.m:87-183 + PEProcess.m:269-284）+ LC 补片段（LiveContainer/LCUtils.m:57-100）。**本批零 vendored 改动**。

### 交叉核验（N9 开工前 LC 侧 vendored 树 vs 0.10.3 原件逐文件 diff，N8 落位纪律复核）

- **逐字节一致**：LiveContainer/{LCUtils.m,LCUtils.h,LCBootstrap.m,LCBootstrap.h,LCMachOUtils.m,LCMachOUtils.h,utils.m,utils.h} ×8 + Tweaks ×9 + ProcEnvironment/{Surface/trust.c,Surface/trust.h,Surface/entitlement.h,Surface/proc/fork.m,Object/FDMapObject.m,Object/FDMapObject.h,environment.h} ×7 + ZSign/zsigner.h（万我 N7c 开关版，diff 已登记 §N7c）。
- **diff 存在且全部为已登记品牌折算（§N8 总账 #1-#10 同源）**：WanWoLiveProcess 代理面 LDEApplicationWorkspace.m（WanWo-Swift.h + com.wanwo.installd）/LDEApplicationWorkspaceInternal.m（queue label + servcieIdentifier）/PEContainer.m（com.wanwo.containerd）/PEContainerService.m + ProcEnvironment/Process/{PEProcessManager.m（WanWo-Swift.h）,PEProcess.m（sceneID 前缀）}。**无未登记 diff，零新改动。**

### 万我层新件（非官方代码）

| 件 | 说明 |
|---|---|
| `WanWo/Features/BuildExt/GuestRunSupport.{h,m}` | ObjC 薄壳（C 回调 block 不便 Swift 直调）：①patchGuestExecutableAtPath = LCUtils.signAppBundleWithZSign 补片段等义（LCParseMachO+LCPatchExecSlice+LCPatchAppBundleFixupARM64eSlice，域名牌 com.nyxian.lcutils→com.wanwo.guestrun）；②appendEntitlementTokenToMachOAtPath = macho_after_sign 包装（trust.c:212-276——ksurface 自签 token 追加 EOF，幂等）；③entitlementBitsFromEntitlementsPlist = 官方 NXEntitlementsConfig.entitlement 位映射等义重建（0.10.3 NXProject.m:137-163 逐键对照；键双收 com.wanwo.build.* scaffold 键 + com.nyxian.pe.* 官方别名；get-task-allow 缺省 YES、其余 NO——官方 withDefaultValue 语义照抄）。头注释含官方语义出处行号 |
| `WanWo/Features/BuildExt/GuestRunService.swift` | run 承载编排：FDMapObject 管道编排（0/1/2+持活 100/101，官方 Builder.swift:322-346 逐行对照）→spawnProcess(withBundleIdentifier:withItems:withKernelSurfaceProcess:nil,doRestartIfRunning:true)→后台线程读 outPipe（行级 onShellLine 缝接工具卡——UI 侧 0.2s 节流，bash 工具同缝不再叠层）→exitingCallback 退出码（FBProcess.exitContext.underlyingContext.legacyCode wait4 原值解码：低 7 位=signal / (raw>>8)&0xFF=exit code，原值一并上报）→run_log 落盘 Cache/<uuid>/run_log.txt（时间戳+stdout/stderr 全量+退出码）。stopActiveRun=stop_build run 态转语义（PEProcess.terminate=SIGKILL）。RunEvents（guest_run kind）注册于此 |
| `WanWo/Features/BuildExt/BuildService.swift` 增段 | ①run 门 beginRun/endRun/isRunInFlight（与构建门同锁；beginBuild 对 run 在途拒绝——run 中禁新 build，方案 §三 7 拍板）；②prepareGuestRun（官方 .run 签名编排等义：补片→wanwo_setHostIdentityOverride(true) 显式开→ZSigner.sign→finally 复位 NO→macho_after_sign（entitlement=工程 Entitlements.plist 位图）→installApplicationAtBundlePath）。与 signAndRepackage 并列互不污染：不做 profile bundle id 对齐（容器模式磁盘 Info.plist 保持工程 id）/不重打包 ipa/标准交付路径零变化 |
| `WanWo/Features/BuildExt/BuildTools.swift` 增件 | BuildAndRunTool（第 10 件；审批 askOnce 同 build_ipa——escalation 缝复用；参数 name + timeout_ms 默认 5min 上限 16min，超时 terminate+部分输出上报——官方 .run 无等待语义，万我工具层收尾需要退出码的自适应扩展）；StopBuildTool run 态转语义；BuildEvents.register 装配点同步注册 guest_run kind（modelVisible，v2.4 报批流程） |
| `WanWo/Bridge/WanWo-Bridging-Header.h` | 追加 2 头（逐头列消费者，最小集原则）：`<LindChain/Services/applicationmgmtd/LDEApplicationWorkspace.h>`（BuildService prepareGuestRun 消费 installApplicationAtBundlePath）+ `"GuestRunSupport.h"`（BuildService/BuildAndRunTool 消费；其引入的 Surface/entitlement.h = PEEntitlement 位图类型进 Swift）。FDMapObject.h/PEProcess.h 经既有 PEProcessManager.h 传递链已在 Swift 可见——不重复引（LCBootstrap.h 宿主侧零消费不引） |
| `WanWo/Core/Context/Compaction/CondensationWorkingSet.swift` | N9c：Policy.attentionWindow 5→12（N8c 实测窗口窄致重复调用；用户拍板 A 方案；token 涨幅实测待真机观察。B 方案挂起项 S21 登记 analysis/suspension-ledger.md） |

### 开关与调用点清单（N7c 预埋三态开关的本环启用点）

| 开关/门 | 调用点 | 语义 |
|---|---|---|
| `wanwo_zsign_host_identity`（zsigner.m s_wanwo_host_identity） | BuildService.prepareGuestRun：签名前 `ZSigner.wanwo_setHostIdentityOverride(true)` → semaphore.wait 返回后复位 NO | YES=容器模式三消费点（bundle.cpp:68 身份覆写 / bundle.cpp:344 CodeResources 跳过 / openssl.cpp:729 prov 不写盘）；仅 run 路径内在位——标准交付（signAndRepackage）零变化 |
| `NXSignMachOWithNyxianEntitlements`（工程 gate，N7c 出厂 false） | 不动 | 万我不经 vendored NXBuilder 的 .run 分支（WANWO_BUILD_RUN 仍关不定义）——prepareGuestRun 显式直调 trust.h macho_after_sign，零冲突 |
| `WANWO_BUILD_RUN` | 维持不定义 | vendored NXBuilder .run 分支永不编译 |
| run 门（beginRun） | BuildAndRunTool.execute 全生命周期 defer endRun；beginBuild 同拒；stop_build run 态转终止 guest | run 中禁新 build；stop 后放行 |

### 读到的偏差（源码实读与任务书/方案不符处）

1. **`project.entitlementsConfig.entitlement` 在万我 vendored 树不存在**：官方 0.10.3 NXEntitlementsConfig 有 `@property PEEntitlement entitlement`（0.10.3 LindChain/Project/NXProject.h:52-54 + NXProject.m:137-163 实现）；万我 vendored NXProject.h/.m 该属性已随 §N4N5 适配删除（N4 实测空引用）。→ 位图映射在万我层等义重建（GuestRunSupport.entitlementBitsFromEntitlementsPlist，逐键对照官方实现；键名适配万我 scaffold 的 kNXT2→com.wanwo.build.* 常量体系——vendored NXProject.m:305-337 出厂 Entitlements.plist 实际写的是 com.wanwo.build.* 键，官方 com.nyxian.pe.* 键别名兼容收录）。
2. **官方 token 追加时序微差**：官方在签名回调内先 macho_after_sign 再 guard result（失败也追加，Builder.swift:304-313）；万我只在签名成功后追加——token 绑定签名后 cdhash，签名失败的产物 token 必无效（cdhash 失配→spawn 期 verify 失败），早失败早报告，语义等价。
3. **官方 .run spawn 后不等待**（Builder.swift:348 spawn 即返回）；万我 build_and_run 等待退出收尾（N9b 任务书要求退出码收尾）——加 timeout_ms 自适应（默认 5min/上限 16min，超时 terminate+如实上报），属万我工具层编排自由度（方案 §三 3 同族）。

### 已知风险与未验证项（真机 N9d 验收重点）

- 容器模式身份链四点一致性：签名 identifier（zsign 覆写=宿主 id）/磁盘 Info.plist（工程 id）/installd 注册 id（磁盘 id）/spawn 查找 id（工程 id）——官方 0.10.3 真机已验整链；installd doWeTrustThatBundle 对「签名 identifier≠Info.plist id」组合的接受度是 N9d 首验点（方案 §三 1）。
- installApplication 2s XPC 超时（官方硬编码）：大 guest 解压可能超时——hello-world 无虞，观察项。
- macho_after_sign 依赖 ksurface_kinit（N8 起随万我启动 constructor 在位）+ installd/containerd 双 daemon 活——prepareGuestRun 失败文案已引导 pe_smoke 排查。
- guest UI app 跑在 appex 内存限额内——hello-world 无虞。
- attentionWindow 12 的 token 涨幅——真机观察（S21 挂起项承载后续研究）。

### N9d · 诊断增强（2026-10-20，真机 4 连失败后的纯诊断轮——零 vendored 改动、零行为语义变更）

**动机**：N9d 真机验收 4 次尝试（TestApp×3 + 全新 N9Probe×1）确定性失败于 prepare 段 installApplication，原错误文案把全部子因混成一句（「installd 信任校验/解压/XPC 超时——2s 官方超时形态」）无法区分。已排除：编译（成功）、XPC 传输（probe 三往返 VERIFIED）、daemon（双活 pid 稳定）、磁盘（20.6G 空闲）、缓存污染（新工程同样失败）、证书链（build_ipa sign=true 成功——签名完成+bundle id 对齐非通配 profile）。剩余候选：①容器模式身份链错配（guest 签名 identifier=宿主 id——设备上宿主被 iLoader 重签 id 带 team 后缀；嵌入 entitlements 却来自用户购买 profile 的 app-id——两身份体系错配→内核校验拒）②容器态 zsign 主二进制路径解析静默失败（N7c 第二轮同族：identifier 覆写激活时 signFailedFiles 含怪路径、主二进制未签上、zsign 仍回 YES）③token 追加破坏签名 ④XPC 2s 超时。

**诊断点清单（按执行顺序，全部万我层；S1/S2 只记录不设门，失败即停沿用既有失败点）**：

| 步骤 | 采集点 | 候选判定 |
|---|---|---|
| a 补片 | 成功/失败（既有） | — |
| b 身份对齐 | 宿主实际 bundle id（Bundle.main.bundleIdentifier——设备上可能为重签后缀形态）vs profile 解析 app-id（BuildService.bundleIdFromProfile 现成）并列展示 | ①直接证据 |
| c 容器签名 | ZSigner 回调 success/error 如实透出（signFailedFiles 非空=静默失败直接证据——zsign.mm:121 非空仍回 YES）；回调后立刻 S1=checkCodeSignature(guest 可执行) | ②判定点 |
| d token 追加 | 成功/失败；追加后 S2=checkCodeSignature | ③判定点（S1 真 S2 假=token 破坏签名） |
| e installApplication | 万我层自有包装区分 installed/rejected/timeout/xpcError/noConnection/invalidInput | ④判定点（timeout）/①倾向（rejected+对照 b 段） |

**万我层新件/增段（非官方代码）**：

| 件 | 说明 |
|---|---|
| `WanWo/Features/BuildExt/GuestRunSupport.{h,m}` 增段 | ①`selfCheckCodeSignatureAtPath:` = 官方 checkCodeSignature（LCMachOUtils.m:392-433——F_ADDFILESIGS_RETURN+F_CHECK_LV）直接消费（LCMachOUtils.h:45 已声明，头已在 N9a 引入——无需 LDEApplicationWorkspaceInternal.m:30 形态前置 extern）；②`installApplicationAtPath:error:` + `WanWoGuestInstallResult` 枚举 = vendored LDEApplicationWorkspace.installApplicationAtBundlePath（WanWoLiveProcess :91-119）官方形态**等义重写**（PELaunchServiceRegistry connectToService + ArchiveObject objectForDirectoryAtPath + remoteObjectProxyWithErrorHandler + 2s semaphore 官方同值——万我层对公开 API 的消费非 vendored 改动）。与 vendored 版三点差异：连接不驻留（诊断包装每次新建）/observer 传 nil（不消费 applicationWasInstalled 回调，导出面给 NSObject 空协议）/返回枚举区分三态（vendored 版 2s 返回后统一 return result 无法区分 reply(NO) 与超时） |
| `WanWo/Features/BuildExt/BuildService.swift` 增段 | GuestRunPreparation 增 `detail` 字段（BuildResult 同款只增不改）；prepareGuestRun 按 a-e 顺序采集拼接 `prepare 细目：[a 补片 OK] [b 宿主id=… \| profile app-id=…] [c 容器签名 OK/err=… \| S1 自查=…] [d token OK \| S2 自查=…] [e install=…]`——每失败步骤附浅因，失败即停（与既有 prepare 失败语义一致）；失败 message=细目+失败点浅因 |
| `WanWo/Features/BuildExt/BuildTools.swift` 增段 | BuildAndRunTool：guest_run 事件 diagnostics 与成功输出带 prep.detail（prepare 失败路径经 prep.message 既有通道透传，零改动） |

**行为语义不变声明**：签名方式/身份对齐/标准签名路径/补片/token 追加调用序零变化；S1/S2 纯记录不设门；vendored 树本轮零 diff。

#### S1/S2 回退（CS_KILL 雷区）（2026-10-20）

**结论**：N9d 诊断轮新增的 S1/S2 签名自查（`selfCheckCodeSignatureAtPath`，commit 0503e31）在真机触发内核 CS_KILL 双闪退，prepareGuestRun 内两处调用点**全部移除**，流程回到：补片→容器签名→token→install。**其余诊断（b 宿主 id vs profile app-id 并列 / c 容器签名 signFailedFiles 如实透出 / e install 六态枚举包装）全部保留**——它们是定位原始 prepare 失败的关键。

**根因链（实锤）**：S1 的 `checkCodeSignature` 走 `F_ADDFILESIGS`（`F_ADDFILESIGS_RETURN`），让内核装载校验 guest 可执行的签名 → 同进程随后 `macho_after_sign`（token 追加）**修改该文件** → 后续 `cd_hash` mmap 触页 → 内核按已装载签名校验新页，判定 **Invalid Page** → CS 击杀**宿主进程自身**。即：同进程「F_ADDFILESIGS→改文件→mmap」是确定性死亡序列。

**证据（两份 .ips 完全一致）**：

- 故障栈：`cd_hash_of_executable_at_fd` ← `macho_after_sign_fd` ← `macho_after_sign` ← `+[GuestRunSupport appendEntitlementTokenAtPath:]` ← `prepareGuestRun`——死在 token 步（d 段），非 install 步；
- termination：`CODESIGNING`「Invalid Page」；出错地址=mapped file+87696，恰为 guest 二进制字节数（EOF——追加 token 后触到的新尾页）；
- 对照：上一轮（无 S1）同流程宿主全程存活；官方 0.10.3（无 S1）同样安全。2/2 复现于加入 S1 之后。

**雷区登记（禁再犯）**：

| 禁止形态 | 说明 |
|---|---|
| 对「F_ADDFILESIGS 后同进程还要修改的文件」调 checkCodeSignature | 内核签名装载不随文件修改失效——之后任何 mmap 触页即 Invalid Page 击杀本进程。token 追加（macho_after_sign）前后的自查均属此形态 |
| 方法保留处置 | `GuestRunSupport.selfCheckCodeSignatureAtPath` 方法体保留（头注释加粗警告），仅作语义封装；prepareGuestRun 调用点零残留。新调用点引入前必须复核目标文件后续是否还会被同进程修改 |

**本轮 diff 边界**：`BuildService.swift`（S1/S2 调用与细目片段移除、S1/S2 相关注释改为雷区注记、boolText 死代码清除）/ `GuestRunSupport.{h,m}`（方法头警告）/ 本文件本节。b/c/e 诊断、install 六态枚举包装、GuestRunService、BuildAndRunTool 零改动；vendored 树零 diff。

#### 运行路线 prov 语义修正 + 容器态主二进制路径拼接修复（2026-10-20，N9 真机 5 连失败后双轨制拍板轮）

**背景与拍板**：N9 build_and_run 真机 5 连失败（4 次通用失败+1 次 CS_KILL 已修），commit 0503e31 的 a-e 五步诊断细目拿到决定性证据：`[b 宿主id=com.wanwo.juyang.TNHMJ2JNPJ | profile app-id=com.cert.account.t260930000125]`（宿主被 iLoader 用 team=TNHMJ2JNPJ 证书重签，运行路线误用用户导入的购买 ad-hoc profile——两套身份体系错配）；`[c 容器签名 OK(err=…Payload/testapp.app//private/var/.../WanWo.app/WanWo)]`（signFailedFiles 非空且失败文件=主二进制，路径=「guest folder 相对路径+宿主绝对路径」拼接怪路径）；`[e install=rejected]`（installd 对未签主二进制必拒，非超时）。用户拍板**双轨制**：交付路线（用户证书+用户 profile，N7c/N7d 真机已证，零改动）与运行路线（万我本体嵌入 profile+容器覆写）并存。

**修 1 · 运行路线 prov 来源改官方同构（万我层，BuildService.prepareGuestRun）**：

- prov 从 `CertificateStore.loadProfileData()` 改为**宿主本体嵌入的 embedded.mobileprovision**——`[NSBundle.mainBundle URLForResource:@"embedded" withExtension:@"mobileprovision"]`，官方 LCUtils.m:95-96 `signAppBundleWithZSign` 原样语义（0.10.3 快照逐行对照）。缺失/不可读=独立失败态，明确报错「宿主本体未嵌入描述文件（重签工具未嵌入）——请用重签工具重装宿主」。
- guest 签名私钥维持 CertificateStore 的 p12+密码（官方同构：LCUtils.certificateData/certificatePassword 同为用户导入形态；用户 0.10.3 亲测背书——导入 ad-hoc p12 出私钥+宿主自带 profile 出身份→Run 正常，**私钥与 profile 可不同源**）。
- 细目 b 段改为：宿主 bundle id（Bundle.main.bundleIdentifier）vs **宿主 embedded profile 解析 app-id**（bundleIdFromProfile 复用）并列——两 id 同体系（一致=健康）。
- 交付路线（signAndRepackage/BuildIPATool sign 路径）零改动——用户导入 profile 仍服务交付；运行路线不再要求用户描述文件。

**修 2 · 容器态主二进制路径拼接修复（vendored 唯一 diff，bundle.cpp）**：

- **消费链定罪**（bundle.cpp 全文复读）：`GetSignFolderInfo` 容器分支原同时覆写 `CFBundleExecutable = getExecutablePath()`（zsigner.m:60 返回宿主可执行**绝对路径**）与 `CFBundleIdentifier = getBundleIdentifier()`；executable 覆写值经 `jvNode["bundle_executable"]` 流入两个消费点——SignNode 的 `strExePath = m_strAppFolder + "/" + strBundleExe`（主二进制签名路径→「guest folder+宿主绝对路径」怪路径→Init 失败进 signFailedFiles→folder 级主二进制签名（Info.plist SHA+CodeResources 绑定形态）整体跳过，仅剩 files 循环的裸 macho 签名（Info.plist 特殊槽缺失）→installd checkCodeSignature 必拒）与 GetChangedFiles 的 changed 列表（同族拼接）。zsign.mm:121 对 signFailedFiles 非空仍回 YES——静默失败。
- **修法选择（候选 a）**：容器分支**删除 executable 覆写、保留 identifier 覆写**（净代码 diff=删 2 行：`extern getExecutablePath` 声明 + `jvInfo["CFBundleExecutable"] = getExecutablePath();`）。理由：①`getExecutablePath()` 全 vendored 树仅此一个消费点（grep 实证），删除覆写即根治，无第二处需要单独修（候选 c 不必要）；②覆写返回宿主绝对路径，改相对形态（候选 b）无官方语义依据且需造路径加工——上游语义（folder 内真实可执行文件名）本就是正确的相对形态；③identifier 部分保留=用户拍板的容器身份体系不变（签名 identifier=宿主 id，与宿主 embedded profile 同体系）。修复后 bundle_executable=guest Info.plist 真实 CFBundleExecutable（相对名）→ SignNode/GetChangedFiles 两消费点同时归位，主二进制获得完整 folder 级签名（identifier=宿主 id+真实 Info.plist SHA），Info.plist SHA 回归真实文件值。
- **零波及声明**：bundle.cpp 同文件 CodeResources 条件化段（:344）与 openssl.cpp prov 条件化段（InitSimple `!开关` 才填 m_strProvData——容器模式仍不把 prov 写入 guest 包，官方 LC 容器行为）零改动；zsigner.m/getExecutablePath 定义保留零改动；标准交付模式（开关 NO）路径零改动。
- **diff 登记（vs 官方 0.10.3，bundle.cpp 容器态语义矩阵更新）**：

| 消费点 | 官方 0.10.3（无条件） | 标准交付（wanwo=NO） | 容器运行（wanwo=YES，本轮后） |
|---|---|---|---|
| CFBundleExecutable 覆写 | getExecutablePath()（宿主绝对路径） | 不覆写（上游语义） | **不覆写（本轮修复——路径恢复上游语义）** |
| CFBundleIdentifier 覆写 | getBundleIdentifier()（宿主 id） | 不覆写（万我对齐 profile 后的包值） | 覆写（宿主 id——身份保留） |
| GenerateCodeResources | 注释跳过（LC don't need） | 恢复生成（N7c 四轮） | 跳过（官方同） |
| InitSimple m_strProvData | 不填 | 补存（zsign 内写 profile） | 不填（容器体系管理） |

**万我层 diff 边界**：`BuildService.swift`（prepareGuestRun prov 来源+细目 b 段+文档注释；signAndRepackage 零改动）/ `BuildTools.swift`（:796 上轮遗留「S1/S2 自查结果跨回合可读」过时注释修正——纯注释）/ 本文件本节。vendored 仅 bundle.cpp 上表所列；pyyaml 不涉及；WANWO_BUILD_RUN 维持不定义。

**遗留观察项**：①BuildAndRunTool 证书前置门仍用 `CertificateStore.isConfigured`（三件齐全）——运行路线虽只需 p12+密码，但要求三件不阻断双轨制（用户按现状导入三件即可），后续按需放宽；②容器模式 prov 不写入 guest 包（官方 LC 行为）——若 installd 信任链要求 guest 包内嵌 profile，下一轮再评估（当前证据指向主二进制未签为 rejected 主因）。

#### installd 回环探针（2026-10-20，N9 调试轮——install=xpcError 层级钉死，纯诊断零行为变更）

**动机**：双轨制修复（commit 3736209）后 prepare 细目实测=「[a 补片 OK] [b 宿主id=com.wanwo.juyang.TNHMJ2JNPJ | 宿主 embedded profile app-id=com.wanwo.juyang.TNHMJ2JNPJ（身份链一致 ✓）] [c 容器签名 OK（signFailedFiles 消失 ✓ 主二进制已签上）] [d token OK] [e install=xpcError：Couldn't communicate with a helper application.]」——5 次尝试确定性复现（testapp×4+新工程 t2×1，跨宿主重启，elapsed 1.6-3.6s），installd daemon 进程全程存活（pid 稳定），containerd 的 XPC 三往返始终正常（fd 跨 XPC 传输 proven）。但 **installd 的 XPC 从未被单独验证过**——pe_smoke probe 只测 containerd，installApplication 是 installd 通道第一次真实使用，xpcError 的层级（连接层 vs 载荷层）待定。

**探针语义**：官方源已核——`LiveProcess/LindChain/Services/applicationmgmtd/LDEApplicationWorkspaceProxyProtocol.h:33` 有 `- (void)applicationInstalledWithBundleID:(NSString*)bundleID withReply:(void (^)(BOOL))reply;`——**纯 BOOL 回环、零自定义对象载荷**（对比 `installApplicationWithArchiveObject` 带 fd 载荷）。daemon 侧实现=`LDEApplicationWorkspaceInternal.m:317-324`（查 bundles 字典→reply(YES/NO)——查询不存在的 id 回 NO，零副作用）。单变量隔离：只换载荷形态（无 ArchiveObject/fd），连接形态不变（connectToService + 2s semaphore + remoteObjectProxyWithErrorHandler 同款），即可把 xpcError 钉到层。

**判定表**：

| 探针结果 | 判定 |
|---|---|
| reply 回来（预期 NO，probe id=com.wanwo.probe.nonexistent 不存在） | installd 回环 OK——**连接层健康，失败在 install 载荷层（ArchiveObject/fd/解码）** |
| XPC 错误回调 | installd 回环 XPC 错误——**连接层失效（与载荷无关）** |
| 2s 超时 | installd 回环超时（daemon 无响应——连接层/daemon 态问题） |

**万我层新件**：`GuestRunSupport.probeInstalldRoundTripWithError:`（ObjC 薄壳，连接形态照 installApplicationAtPath 同款但独立临时连接——不缓存不复用 prepareGuestRun 连接、observer 传 nil 连接不驻留语义同既有处理；返回报告行文本 + NSString* error 出参，不用 NSError** 避免与六态枚举语义混淆）。消费点：`PESmoke.swift` probe 输出在 containerd 三往返之后追加「=== installd 回环 ===」段。桥接头零改动（LDEApplicationWorkspaceProxyProtocol 经 WanWo-Bridging-Header.h:65 既有 LDEApplicationWorkspace.h 头链已进 Swift/ObjC 可见面）。

**行为语义不变声明**：prepareGuestRun/installApplication 零改动（探针独立连接、独立调用点）；vendored 树零 diff；纯诊断输出，不设门不拦截。

#### installd 装载状态判别探针（2026-10-20，N9 调试轮二分——载荷层 L1/L2 判别，纯诊断零行为变更）

**动机**：回环探针（commit 6a3da26）实证 installd 的 XPC 连接层健康（`applicationInstalledWithBundleID:@"com.wanwo.probe.nonexistent"` 纯 BOOL 回环 reply=NO 干净返回），install=xpcError 失败钉死在 install 的 ArchiveObject 载荷层——载荷层待二分：**L1**=ArchiveObject+fd 解码失败于 daemon（fileport_makefd 在 uid=1 的 installd 内行为异常→guest 从未被安装→修 fd 传输/解码层）；**L2**=install 实际成功、死在装后通知（daemon 广播 `applicationWasInstalled:(LDEApplicationObject*)` 给 observer=nil 连接 + 宿主无 ResecureDecoder 白名单（appex-only，main.m:265）→解码失败→连接失效→reply 丢失→host 侧 xpcError→修通知层）。判别法：用工程真实 bundle id（com.wanwo.testapp，历轮 build_and_run 目标工程）调 `applicationInstalledWithBundleID:withReply:` 查 daemon 侧 bundles 字典——YES=L2 实锤 / NO=L1 实锤；错误/超时/连接失败=连接层态，不参与判别。

**万我层新件**：`GuestRunSupport.probeInstalldTestAppRoundTripWithError:`（薄壳，连接形态与回环探针完全同款；实现共用 .m 内 static 查询函数 WanWoGuestProbeInstalldQuery——bundleId 参数化、文件内私有不入 Swift 导出面；判别目标 id 常量 `WanWoGuestProbeTestAppBundleID`）。消费点：`PESmoke.swift` probe 输出「=== installd 回环 ===」段内追加第二行查询结果（格式「installd 查询 com.wanwo.testapp → YES/NO/错误：<原文>/超时」）。行为语义不变：prepareGuestRun/installApplication 零改动；vendored 树零 diff；纯诊断输出，不设门不拦截。

#### 装后通知层修复（L2 实锤轮）（2026-10-20，判别探针 YES 定案 → install 回执修复，让 prepare 进 spawn）

**判别证据（commit 2f50b98 探针本机实测）**：`installd 查询 com.wanwo.testapp → YES`——guest 已在 daemon 侧 bundles 字典注册（LDEApplicationWorkspaceInternal.m:317-324 查询语义）。结合回环探针（6a3da26，连接层健康）+ e 段历轮 5+ 次 `install=xpcError「Couldn't communicate with a helper application.」`：**installApplicationWithPayloadPath: 在 daemon 侧每次都成功，失败在装后通知层**。

**根因链（L2 实锤，三段逐处源码实证）**：

1. daemon 对**每个新连接**设 `remoteObjectInterface=LDEApplicationWorkspaceProtocol`（ServiceKit/Service.m:66——observerProtocol 取自 LDEApplicationWorkspaceInternal `+observerProtocol`），不受宿主导出面影响；
2. daemon 在 `installApplicationWithPayloadPath:` **方法内、return YES 之前**向全部 client 广播 `applicationWasInstalled:(LDEApplicationObject*)`（LDEApplicationWorkspaceInternal.m:276-284）；且 `clientDidConnectWithConnection:` 对新连接重放已有 bundles 的同名广播（:575-587）；
3. 万我层连接（GuestRunSupport installApplicationAtPath + 两探针，commit 0503e31 起）`observer=nil` → connectToService 落成 `exportedObject=nil + exportedInterface=NSObject 空协议`（PELaunchServiceRegistry.m:77-78 无条件赋值）——广播选择器 `applicationWasInstalled:` 不在导出面 → NSXPCConnection 失效 → install 的 reply 回执丢失 → host 侧 remoteObjectProxyWithErrorHandler 触发 → xpcError。

**时序差异（为何回环探针 OK 而 install 死）**：install 的广播先于 reply 发出（方法内 :282 → return YES）→ 连接在 reply 到达前已被击穿；探针的纯 BOOL reply 无前置广播，先于 clientDidConnect 广播失效到达 → 侥幸干净返回。另探针连接建立时 bundles 已非空（testapp 历轮装过）→ clientDidConnect 广播当场可达——两探针同样悬在时序上。

**修法（仅万我层，零 vendored diff）**：

| 项 | 内容 |
|---|---|
| `GuestRunSupport.h/.m` 新增 `WanWoGuestInstallObserver` | ObjC 类，实现 `LDEApplicationWorkspaceProtocol` **全部方法**（协议 .h 全文核对：仅 `applicationWasInstalled:` / `applicationWithBundleIdentifierWasUninstalled:` 两方法）；语义对齐官方宿主侧 observer（0.10.3 LDEApplicationWorkspace.m:361-373）但去掉 UI 呈现层（万我没有应用管理 UI）——两方法 no-op + NSLog 调试行。进程级单例 `+sharedObserver` |
| `installApplicationAtPath` 连接 | `observer:nil/@protocol(NSObject)` → `observer:[WanWoGuestInstallObserver sharedObserver]/@protocol(LDEApplicationWorkspaceProtocol)`（官方宿主 LDEApplicationWorkspace.m:71 `observer:self` 同构） |
| 两探针连接（WanWoGuestProbeInstalldQuery） | 同上统一挂 observer——全部连 installd 的万我层连接导出面一致，不再依赖「reply 先于广播失效到达」时序 |
| 判别探针 YES 报告行 | 语义转常态健康指标（「guest 已在 daemon 侧注册」——L2 轮实锤形态的常态化；探针段按边界保留） |
| `BuildService.prepareGuestRun` | 成功 message 带「guest 已安装（bundle id=…，daemon 侧实际注册 id=磁盘 Info.plist id——容器模式不改写，spawn 段按此 id 查找）」——spawn 传参链（BuildTools.swift :785 `bundleID: prep.bundleID`）自洽；`.xpcError` 浅因文案更新（修复后残余 xpcError=意外态指向） |

**白名单 hook 不需要的判定依据（施工项 2 择路 b——只修导出面，不动 vendored）**：官方 0.10.3 全仓 `ResecureDecoder()` 调用点仅 LiveProcess appex `main.m:265`（grep 实证）——**官方宿主 App（Nyxian target）从未调用**，但其宿主侧 observer（LDEApplicationWorkspace，`observer:self` + `exportedInterface=LDEApplicationWorkspaceProtocol`，LDEApplicationWorkspace.m:71）正常接收 `applicationWasInstalled:(LDEApplicationObject*)` 广播（官方应用管理列表机制，0.10.3 用户实测可用）。即：协议方法签名内的自定义类（LDEApplicationObject 在 `applicationWasInstalled:` 参数位）经 NSXPCInterface 从导出协议方法签名**自动放行解码**——与上轮 FDObject 跨进程解码实证（FDObject 在 PEContainerProtocol 方法签名内自动放行，宿主进程无 hook）同机制。官方白名单不含 LDEApplicationObject 正因官方宿主走协议签名自动放行、无需兜底。故 `ResecureDecoder.m` 零改动、宿主编译面（project.yml）零改动。

**行为语义**：prepare 步骤序（补片→容器签名→token→install）与 e 段分态语义不变；install 成功后 prepare 正常返回 → build_and_run 链进 spawn 段；交付路线（signAndRepackage）、探针段（保留）、`WANWO_BUILD_RUN`（维持不定义）零变化。**vendored 树本轮零 diff**（上轮 bundle.cpp 一处之外无新增）。

**官方对照**：官方宿主 observer=`ApplicationManagementViewController` UI 路径（LDEApplicationWorkspace.m:361-373 dispatch_async 主队列转 UI 刷新）；万我 no-op 路径=同名协议同形实现、去 UI（万我无应用管理呈现层），连接生命周期（不驻留、每次新建）维持万我诊断包装既有语义。

#### 观测链补全（2026-10-20，N9 spawn 段真机首抵后的 AI 可读性收口——零 vendored）

**背景（N9 spawn 段真机实证）**：prepare 全链通过（install=installed）、guest 进程拉起存活 180s、超时 terminate signal=9（wait4 raw=9 捕获正确）、run_log.txt 落盘成功。**观测盲区**：testapp 为无 print 的 SwiftUI 应用——进程存活但零输出，无法区分「spawn 成功在跑主循环」vs「pre-main 挂起」；且 run_log 落在宿主 Cache 路径（`/private/var/mobile/.../Cache/<uuid>/run_log.txt`），guest bash 与 AI 的 fs 工具都读不到——**观测链缺口：AI 拿不到 guest 输出内容**（N9 完成定义要求「AI 依日志修 bug 重跑」，此缺口必须补）。

**施工项（仅万我工具层，零 vendored diff）**：

| 项 | 内容 |
|---|---|
| 结果内联输出尾段 | build_and_run 结果文本（成功/失败/超时三态）追加「——— guest 输出尾段（最后 ≤80 行）———」节——GuestRunService 输出缓冲（与 run_log 同源数据）取用窗口 40→80 行（缓冲上限 200 不变）；输出为空时显式写「（guest 零输出——若非预期，检查 guest 是否 print/是否 pre-main 挂起）」。超时 terminate 态尤其需要——它是 GUI 应用的常态终点；仅 run 实际发生（runLogPath 非空）才出尾段节，build/prepare 段失败不误报零输出 |
| run_log 副本落工作区 | run 结束后 BuildAndRunTool 将 run_log.txt 复制到工作区 `BuildArtifacts/run_log-<HHmmss>.txt`（AI fs 工具/read 直取）；复制失败静默降级（结果文本不带副本路径行，原 Cache 路径行保留）；结果文本带工作区副本路径（`run log (workspace copy, AI readable): …`）；工具 description 同步更新 |
| 超时语义细化 | guest 跑满 timeout 被 terminate 的结果 message 标注「guest 存活至超时（进程未自行退出）——GUI 应用属预期形态；CLI 应用应自行退出」——区分「拉起后存活」（GUI 应用常态终点）与「秒退」（非超时路径）两种形态，N9 验收判读关键 |

**边界**：prepareGuestRun / spawn 逻辑（PEProcessManager.spawnProcess 同参）/ 退出码捕获（exitingCallback + wait4 解码）零改动；交付路线（signAndRepackage）零改动；**vendored 树本轮零 diff**。官方对照面不变（0.10.3 Builder.swift:321-349 + PEProcess.m:269-284）——本节纯万我工具层编排自由度（结果文本组装与宿主侧落盘路径，官方无对应面）。

## N10、窗口托管与终端（2026-10-20 晚，方案 analysis/n10-window-terminal-plan.md，三项拍板全落锤；前任施工中断，本轮接手核验+补完+修复一批）

### SwiftTerm 引入（拍板项 1）与 Terminal.swift 落位

| 项 | 内容 |
|---|---|
| SwiftTerm 1.13.0 SPM | project.yml packages 段：`SwiftTerm` url=github.com/migueldeicaza/SwiftTerm（官方 0.10.3 Package.resolved 同版本同源，revision 8e7a1e1），`exactVersion: "1.13.0"` 锁版本防漂移；target dependencies 引用（TerminalViewObjC 底座） |
| Terminal.swift 落位 | `WanWo/Features/GuestWindow/Terminal.swift`（万我树内副本，**非 vendored 路径**——vendored 树零 diff）。官方 0.10.3 `Nyxian/UI/UIInit/Terminal.swift`（147 行）逐行比对复核：除下列三处适配外逐行一致。**适配 1**：`currentTheme`（官方 UIInit.swift 全局 LDETheme，属官方 UI 层——万我未落位）引用整段移除，直取 `??` 系统回退值（.secondarySystemBackground / gibDynamicColor(light: .label, dark:)）；**适配 2**：gibDynamicColor（官方 CodeEditor+Theme.swift:84-98）语义等义内联为文件私有副本（dynamicProvider 明暗双轨同源）；**适配 3**：handleThemeChange 保留原结构（uiColorChangeNotif 通知在万我不发生），内容改系统回退重涂 |

### WANWO_BUILD_UI 宏解锁面（与任务书三处守卫逐处核验结论）

| 守卫段 | 处置 | 依据 |
|---|---|---|
| vendored NXWindowSessionTerminal.m 全单元（:36-299） | **解锁**（GCC_PREPROCESSOR_DEFINITIONS 加 WANWO_BUILD_UI=1） | 解封后引用符号面逐核闭合：TerminalViewObjC/TerminalViewDelegateObjC 经 `#import <WanWo-Swift.h>` 从万我 Swift 面（GuestWindow/Terminal.swift）供入；ksurface tty/FDMapObject/PEProcessManager/LDEApplicationWorkspace 均在编译面（N8 落位+方法验证） |
| NXBuilder.swift:365-407（buildProjectWithArgumentUI） | **维持守卫**（Swift 面不定义宏——OTHER_SWIFT_FLAGS 刻意不加） | 段内引用 XCButton/UIDebugViewController/share/NXDocumentManager/UIViewController 导航栏 UI 全套——grep 实证 XCButton/UIDebugViewController/NXDocumentManager/share 仅存在于两守卫段自身，万我编译面无此类（任务书条款：引用缺失 UI 类→如实报告禁硬适配）。万我走工具化路径（BuildAndRunTool），不消费此段 |
| Project+Debug.swift:245-465 | **维持守卫**（同上） | 同理（官方 debug UI 段，引用官方 UI 层） |

即：**宏为单面定义**（仅 ObjC GCC_PREPROCESSOR_DEFINITIONS）——与任务书「双面定义」字面不同，实态为准并在此登记理由：Swift 面开宏即编译失败（缺失符号），单面定义是唯一可编译形态，语义与任务书意图（解锁①③、核验②如实报告）一致。

### vendored diff 总账（本轮逐行复核，与官方 0.10.3 diff 实证）

唯一 vendored 改动文件仍为 NXWindowSessionTerminal.m（N8 已登记，本轮**零新增 diff**）：

1. 行 26-37：官方 `#import <emexDE-Swift.h>` → 万我适配注释块 + `#import <Foundation/Foundation.h>`（守卫关闭态空编译单元保底）+ `#if defined(WANWO_BUILD_UI) && WANWO_BUILD_UI` + `#import <WanWo-Swift.h>`（emexDE→万我 Swift 桥接名适配，N8 惯例）；
2. 文件尾：`#endif /* WANWO_BUILD_UI */`。

其余 WindowServer 全家（NXWindowServer.m 995 行/NXWindow/NXWindowSession/NXWindowSessionApplication）逐字节官方原样（本轮 git status Vendor/ 零未提交改动实证）。

### 双 UIWindow 宿主设计（拍板项 2 方案 A）与自动开窗（拍板项 3）

- **GuestWindowBridge.h/.m（万我自有薄壳，非官方代码）**：官方工厂 `sharedWithWindowScene:`/`openWindowWithSession:` 的 Swift 导入名不可静态确定（导入器剪枝雷区纪律——GuestRunSupport.h 同款），跨语言调用收拢薄壳固定形态。`ensureActivated`（主线程幂等）：NXWindowServer 以 foregroundActive UIWindowScene 初始化为**同一 scene 的第二个 UIWindow**（与 SwiftUI 主窗口并存；官方单窗口桌面形态→万我双窗口，零 vendored）+ 首次 makeKeyAndVisible（官方 App 启动同款单次语义，防手势重复叠加）；`showGuestOverlay`/`hideGuestOverlay`（呈现/隐藏切换，hide 归还 key 给主窗口）；`openUtilityTerminalWithPath:processOut:noteOut:`（N10c 终端开窗）。
- **触摸穿透**：无 guest 窗口时 NXWindowLayerView hitTest 对自身返回 nil（NXWindowServer.m:31-37 官方原样）——主界面照常可点。
- **键窗语义**：makeKeyAndVisible 后 NXWindowServer 持 key（终端 becomeFirstResponder 需 key window 弹键盘）——双窗口 scene/keyWindow 形态为 N10d 真机验收重点。
- **app 路线自动开窗**：vendored PEProcess（零 diff）`scene:didCompleteUpdateWithContext:`（PEProcess.m:243-267）在 guest FBScene 到达时 dispatch_once 创建 NXWindowSessionApplication 并 openWindowWithSession——官方 Builder.swift:321-349 .run app 段同语义；FDMapObject 管道照旧+窗口会话叠加（**窗口与 N9 管道 stdio 并存**——run_log/退出码/尾段观测链零回归），进程退出自动关窗（PEProcess.m:286-294）。万我侧时序义务：`GuestWindowBridge ensureActivatedSync` 须先于 spawn 以真实 scene 激活（GuestRunService.spawn 前调用点）——若先经无 scene 懒创建则 openWindow 恒败。
- **懒创建死局防护（本轮接手修复——前任残缺点）**：NXWindowServer.m `+shared` 实现为 `return [self sharedWithWindowScene:nil]`（无 scene 懒创建）——**永不返回 nil**；前任 GuestWindowBridge.m 的 showGuestOverlay/hideGuestOverlay 用 `[NXWindowServer shared]`+`if (server == nil)` 防护，nil 检查永不触发，激活前调用即触发懒创建死局（dispatch_once 消耗→真实 scene 永远拿不回，openWindow 恒败——恰是头注释自警的形态）。修法：文件内 `static BOOL wanwoServerActivated` 标记（ensureActivated 成功路径置位），三处 shared 消费点（show/hide/openUtilityTerminal）先查标记，未激活不触碰单例；openUtilityTerminal 激活失败带注记早退。

### utility 终端路线（N10c——官方 Builder.swift:358-373 .run utility 段语义对齐）

| 项 | 内容 |
|---|---|
| BuildService.prepareUtilityRun | 四步签名编排（官方逐段）：①补片（LCUtils.signMachOAtURL 补片段等义——单 macho LCPatchExecSlice，无 bundle arm64e fixup）→②单 macho ZSign（prov=宿主 embedded profile+私钥=用户导入 p12+密码——万我双轨制同 app 路线；单 macho 无 bundle 身份覆写面）→③NXTR token（entitlementBits→PEEntitlement 位图，官方 macho_after_sign 同序）→④fastpathUtility（daemon 复制+签名，返回运行路径=PEExecutablePath）。S1/S2 签名自查不引入（N9 CS_KILL 雷区） |
| GuestRunSupport 新增两薄壳 | `patchGuestExecutableOnlyAtPath:error:`（官方 signMachOAtURL 补片段等义）+ `signUtilityMachOAtPath:prov:key:pass:error:`（签名段等义；ZSigner.signMachOAtPath 直调 Swift 导入名不可静态确定——选择器形状与已实证可导入的 patchGuestExecutableAtPath 同构） |
| BuildTools utility 分叉 | schemeKind≠.app 在编译成功后分叉（编译/审批/宏预检/lld 门共用）→ prepareUtilityRun → `GuestWindowBridge openUtilityTerminalWithPath`（vendored openWindow 内部：TTY 分配+termios+三路 SLAVEFD 映射+utilityHomePath+spawn+tty_attach_proc+TerminalViewObjC——官方原样消费）→ 成功即返回（run 门由 defer 放行——官方 .run utility 开窗即返回同语义）。N9 的「utility 报 N10 支持」占位移除 |
| stop_build 接线 | 活跃 utility 进程登记（GuestRunService.registerUtilityProcess/unregisterUtilityProcess/hasActiveRegisteredProcess）：stop_build 按登记 terminate（终端窗口随 exitingCallback 关闭——官方同款）；exitingCallback 包装=官方回调后注销登记。run 门不长期持有（官方开窗即返回形态） |
| 输出形态 | 终端窗口内 stdin/stdout 完整交互（TTY 直连终端视图，输出不回流工具卡——官方同款）；窗口关闭=进程 terminate |

### CI 门与观测

- ios.yml 新增 **N10 SwiftTerm SPM gate**：Package.resolved 存在性 + identity=swiftterm + version=1.13.0 三断言（防 SPM 网络抖动静默降级——resolve 失败时 xcodebuild 可能跳过依赖继续编）；build.log 含 SwiftTerm 编译引用 WARN 级检查。
- cc-mdk-smoke 触发面含 project.yml（本轮有改动→Smoke 会跑）；vendored 树零 diff。

### 已知风险与未验证项（真机 N10d 验收重点）

1. 双 UIWindow 的 scene/keyWindow 语义（键盘弹出/触摸穿透）——首验项；
2. guest FBScene 注册链在容器模式+窗口呈现组合首次真机验证；
3. SwiftTerm SPM 在 CI 的 GitHub 可达性（gate 已防静默降级；必要时再议 vendor 化——不推荐）；
4. 内存：guest UI+窗口呈现+终端同栈（appex 限额观察项）；
5. NXWindowServer 桌面交互全套（appSwitcher/手势/presentationState）在场不删，万我首版只接 openWindow/close/focus 主链。

### N10d · 首轮真机反馈三案修复（2026-10-20 晚，用户拍板 10-20 23:47：A1+A2 两件套 + C v2 运行会话解耦 + B 呈现修随批）

**背景（三案考古定罪，全部源码实证）**：
1. **案 A 浮窗吞整屏触摸**：官方 NXWindowLayerView.hitTest（NXWindowServer.m:31-37）只保护 `_windowLayer` 子视图层；NXWindowServer 本身是全屏 UIWindow（背景透明），UIView 级 hitTest 默认「点在 bounds 内+子视图无人认领→返回窗口自身」=吞整屏触摸。GuestWindowBridge.h 头注释原声称「触摸穿透主界面照常可点」不成立（本轮已修正）。残留机制：hideGuestOverlay 全树零调用点→guest 退出后 NXWindowServer 常驻 visible+key→审批卡被吞→第二轮审批 verdict=unavailable→回合中断。
2. **案 B 浮窗关闭钮=杀进程**：官方语义非 Bug（NXWindowSessionApplication.m:121-135 closeWindow 内 `[_process terminate]`，官方注释 "terminating process so it stops eating our cores x3"）；呈现错位在万我层——signal=9 被杀也标「guest 正常退出」。
3. **案 C 工具生命周期焊死 guest 进程**：官方 .run 全流程（NXBuilder.swift:294-358）install 完成即 completion 返回（全文零等待退出/零超时杀）；N9 层阻塞等待+timeout_ms 是万我自加编排，N10 浮窗化后 guest=模拟器式常驻交互面，阻塞壳成结构性矛盾。

#### A1：window 级 hitTest 透传（万我层运行时方法覆盖——零 vendored 源码 diff）

- **登记性质**：万我层对 vendored 类（NXWindowServer）的方法覆盖=运行时层适配（ObjC runtime `class_addMethod`），**vendored 源码零 diff**——本节为该覆盖的动机/形态/边界如实登记。
- **动机**：案 A 根因（window 自身吞触摸——官方单窗口形态无此问题，万我双 UIWindow 形态特有）。
- **形态（雷区核验）**：`hitTest:withEvent:` 是 UIView 的方法且 NXWindowServer 未重写——`method_exchangeImplementations(class_getInstanceMethod(...))` 会拿到继承链上 UIView 的 Method，交换污染所有 UIView（灾难性，禁用）。实际形态：GuestWindowBridge `+load`（进程内一次 dispatch_once，早于任何 NXWindowServer 实例消费）取 `originalImp = method_getImplementation(class_getInstanceMethod([NXWindowServer class], sel))`（此时为 UIView 实现）→ `class_addMethod` 在 NXWindowServer 本类挂万我 IMP（`imp_implementationWithBlock`）覆盖——万我 IMP 内部以函数指针形态调用 originalImp 后按 NXWindowLayerView 同款语义返回（`hit == self ? nil : hit`）。class_addMethod 返回 NO 时（理论不发生——方法不在本类）退回 `method_setImplementation` 覆盖形态（originalImp 已先取，语义等价 exchange）并 NSLog 报告。
- **边界核验**：全屏态 maximize（NXWindowServer.m:842-873 把 NXWindow.view 直挂 self）——super 命中 NXWindow.view（非 self）照常认领，不受影响；长按手势仅 iPhone 且 iOS<26 挂载（:304-329），iPad 主路径无手势影响；appSwitcher/tile 等子视图命中链全部经 super 原实现，零行为变化。

#### A2：生命周期收尾（窗口清空时隐藏+归还键窗）

| 项 | 内容 |
|---|---|
| hideGuestOverlayIfNoWindowsAfterDelay: | GuestWindowBridge 新增：主队列延迟判定 `NXWindowServer.shared.windows.count == 0` 时调既有 hideGuestOverlay（hidden=YES+归还 key）。delay 参数承接官方进程退出关窗的异步链竞态：processDidExit 内 dispatch_async(main) 关窗（PEProcess.m:286-294），退出回调同步段后窗口可能仍在关闭途中——调用方传 1.0s 余量，主队列 FIFO 保证判定排在官方 closeWindow dispatch 之后 |
| app 路线收尾点 | RunSession 收尾段（GuestRunService.finalizeRunSession——退出回调后）调用 |
| utility 路线收尾点 | unregisterUtilityProcess 后同款判定（官方 exitingCallback 关窗链同异步形态，同 1.0s 余量） |
| ensureActivated 复活路径 | 既有 `server.isHidden → hidden=NO`（GuestWindowBridge.m）零改动，验证即可 |

#### B：退出三态呈现

| 态 | 判定 | 文案 |
|---|---|---|
| ①自然退出 | decoded && signal==0 | 「guest 正常退出：exit=N（wait4 raw=R）」（非零加修复提示） |
| ②超时 | timedOut（优先） | 既有超时文案（存活至超时=GUI 预期形态） |
| ③a stop_build 终止 | stopRequested 标志（stopActiveRun 置位） | 「guest 已被 stop_build 终止（SIGKILL）+退出注记」 |
| ③b 外部终止 | signal>0 且非超时非 stop（排除法） | 「guest 被外部终止（signal=N）——浮窗关闭钮=终止进程（官方语义：关窗即杀进程）」 |
| 状态不可得 | !decoded | 既有 exitContext 缺失文案 |

事件 result 同步改：仅①=success；②③/不可得=failure（signal 被杀不再标「正常退出」）。

#### C v2：运行会话解耦

| 项 | 内容 |
|---|---|
| BuildAndRunTool app 路线重定义 | 构建→prepare（签名/安装细目 a-e 全保留）→spawn 成功→**工具立即返回 .success**（pid+prepare 细目+「浮窗已弹出——常驻交互面」注记）；spawn 失败路径保持同步失败返回 |
| GuestRunSession 常驻段 | performRun（阻塞式）拆为 spawnRun（同步段：管道/spawn/登记/run_log 头/读循环启动）+ 后台会话队列（等退出→收尾：run_log footer→A2 窗口收尾→endRun→guest_run 退出事件 modelVisible 带 exit 注记+输出尾段+run_log 工作区副本） |
| writer 注入结论 | SessionWriter（WanWo/Storage/SessionWriter.swift:67-162）为 `@unchecked Sendable`，append 经内部 gate（NSLock+CheckedContinuation）串行化且无「工具调用生命周期」约束（写柄由 AppEnvironment sessionWriters 持有至会话关闭）——**工具返回后 append 已核验安全**；RunSession 持强引用，收尾段 `Task { try? await writer.append(...) }` 发退出事件 |
| 退出事件链 | exitingCallback 先官方语义采集（wait4 raw）再 signal semaphore；收尾由会话队列在 semaphore 之后执行（=先官方后万我序，utility 路线 BuildTools.swift:838-841 同款模式） |
| run 门 | beginRun 时机不变（build 前）；endRun 从工具 defer 移至 RunSession 收尾（spawn 成功路径）；build/prepare/spawn 失败路径工具内显式 endRun；utility 路线开窗即返（官方语义）本方法内显式 endRun |
| 重复运行（C-b） | beginRun 失败且 runInFlight 时返回明确失败带活跃 pid（GuestRunService.activeRunInfo——「guest 运行中（pid=X 工程=Y）——stop_build 终止或等其退出；重复运行被拒绝（不自动停旧起新）」）；activeRunInfo 落在 GuestRunService（会话登记的所有者）而非 BuildService——任务书「BuildService 需暴露」按信息归属微调 |
| timeout（C-a） | 默认**不限时**（.distantFuture 等待）；timeout_ms 可选保留为保护上限（5000-960000ms，到点 terminate→timedOut→既有超时文案）；工具 description/参数说明同步 |
| stop_build（C 项 7） | 语义不变（AI 的停止按钮）：terminate→exit 回调→收尾→endRun 链路兼容验证；工具层仅在「无活跃会话登记的异常残留态」兜底 endRun 防门卡死 |
| N9 观测链装备 | prepare 细目 a-e/installd 探针/输出尾段缓冲 80 行/run_log 工作区副本全部保留（副本落盘移由 RunSession 收尾段消费——copyRunLogToWorkspace 改 internal） |

**边界**：**vendored 树本轮零 diff**（A1 为运行时层覆盖，唯一登记例外=本节；GuestWindowBridge.h/.m 为万我自有文件）；交付路线（build_ipa/signAndRepackage）零改动；utility 路线编排零改动（仅补 A2 收尾+endRun 显式化）；N9 管道编排（FDMapObject 三映射+持活 fd 100/101）/退出码捕获（exitingCallback+wait4 解码）/run_log 落盘逻辑逐行保留。

### N10e · utility 终端修复批（2026-10-21，用户拍板修 A+修 B；诊断=analysis/utility-terminal-build-failure-diagnosis.md）

**背景三段定罪**（N10d 装机验收 utility 三工程六配置全灭，源码考古定罪）：①段 1 万我 project_create 只出 App 模板（NXSwiftFlags 带 -parse-as-library，NXCodeTemplate.m:178-182），设备 AI sed 改 NXProjectScheme=Utility 后 flags 未随动 → 官方 Utility Swift 模板顶层代码（Templates.bundle/Templates/Utility/Swift/Main.swift=import Foundation+print）必拒；②段 2 App 模板 NXOutputPath=$(CACHEROOT)/Payload/... 指向管线不为 Utility 创建的 .app 目录（官方 Utility=裸路径 $(CACHEROOT)/$(NXExecutable)，NXProject.m:279-283，且无 Resources 目录/无 NXBundleInfo）→ 链接断；③段 3 token 步 macho_after_sign rc=-1（唯一真管线问题，trust.c:212-276 三路失败黑盒不可区分——open(O_RDWR) 失败的 perror 只进宿主 stderr）。

**修 A（project_create 暴露 scheme，根治段 1/2）**：
| 项 | 内容 |
|---|---|
| BuildService.createOrReuseProject | 新增 `schemeKind` 参数（默认 .app=旧行为零回归）透传官方工厂全参数形态（NXProject.m:169-178 本就在位，万我此前固定 .app）；**Utility 时 interfaceKind 强制 NXProjectInterfaceKind.unknown**——官方合法性矩阵 NXProjectConfigurationIsValid（NXType.m:157-199）要求 Utility+Unknown，Utility+SwiftUI 会撞工厂 assert(NXProject.m:178) 炸宿主进程（本轮施工新钉雷点） |
| BuildTools.ProjectCreateTool | 工具面新增可选参数 `scheme`（"Application"（默认）/"Utility" 两值白名单，其他值 INVALID_ARGS 不静默纠正）；result 文本如实报告 scheme 形态+NXOutputPath 模板形态（Utility 附顶层代码模板注记+build_and_run 引导；复用路径按工程实际 scheme 报告并带 mismatch 警告） |
| 创建后覆写兼容 | D2 输出路径覆写对 Utility 为 no-op（guard 只匹配官方 App 默认形态）；出厂 gate false 对 Utility 保持（万我 utility token 步 prepareUtilityRun 无条件执行不读该键；vendored NXBuilder WANWO_BUILD_RUN 防撞语义与 scheme 无关） |
| 官方模板脚手架 | NXCodeTemplateMakeProjectStructure（NXCodeTemplate.h:28）在 Utility 路径按 Templates.bundle/Templates/Utility/Swift/Main.swift 铺顶层代码形态 main.swift——工具 result sources 行如实呈现 |

**修 B（appendEntitlementTokenAtPath errno 级诊断增强，钉死段 3）**：
| 项 | 内容 |
|---|---|
| 前置探测 | macho_after_sign 调用前 stat/access 探测（exists/size/mode 八进制/R_OK/W_OK——errno.h+sys/stat.h+unistd.h+string.h 新 import）；探测失败（不存在或不可读写）fail fast 错误码 5（新增，全域唯一）直接带探测数据返回、不调 macho_after_sign |
| 失败增强 | rc!=0 路径 NSError userInfo 增三键：WanWoTokenProbe（前置探测平铺字段）/WanWoTokenSignErrno（errno=0 清零后紧随调用捕获——EACCES/EPERM/ENOENT 候选=open 实锤，残留值=gen 嫌疑上升的弱信号）/WanWoTokenProbeConclusion（open vs gen 判读指引）；NSLocalizedDescriptionKey 原文逐字保留 |
| 零行为变更 | macho_after_sign 调用本身/成功路径/token 语义完全不动（纯诊断；fail fast 仅在 open(O_RDWR) 必失败的前置态短路——调用方 NO+error 失败语义不变）；app 路线 prepareGuestRun 同函数消费零改动 |

**修 C（appendEntitlementTokenAtPath OpenSSL error queue + 私钥前缀诊断增强，2026-10-21；背景=修 B 真机数据 errno=0/probe 全过定罪失败在 gen 的 OpenSSL 消费链，d2i_PrivateKey/DigestSignInit/DigestSign 三候选黑盒）**：
| 项 | 内容 |
|---|---|
| C1 error queue dump | GuestRunSupport.m appendEntitlementTokenAtPath 在 macho_after_sign 返回 rc!=0 后同线程立即 ERR_get_error 循环（include <OpenSSL/err.h>——vendored entitlement.c:27 同款 include，编译面零新增链接配置）直到 0，逐条 ERR_error_string_n + ERR_GET_LIB/ERR_GET_REASON 格式化（#n code=0x… lib=… reason=… 字符串；分号分隔）进 NSError 新键 WanWoTokenOpenSSLErrors；不调 ERR_clear_error（保留队列态）；队列为空如实记录「queue empty——失败可能未走 OpenSSL 报错路径」（0 条也是决定性证据面） |
| C2 私钥前缀诊断 | 前置探测扩展：import <LindChain/ProcEnvironment/Surface/surface.h>（extern ksurface 声明 surface.h:35——与已 import 的 trust.h 同目录，头搜索路径零新增）只读读 ksurface->priv_key 的 len+前 16 字节 hex 进新键 WanWoTokenKeyPrefix（合法 DER EC 私钥首字节 0x30 SEQUENCE 判读）；ksurface==NULL（kinit 未跑）/priv_key==NULL/len==0 三层防护逐态如实标注（直接解引用 NULL 会崩宿主——防护硬要求）；⚠️ 只读禁写 ksurface 任何字段 |
| 零行为变更 | macho_after_sign 调用本身/成功路径/token 语义/既有三键（WanWoTokenProbe/WanWoTokenSignErrno/WanWoTokenProbeConclusion 逐字不动）/fail fast 错误码 5 语义完全不动；C1/C2 仅失败路径 NSError userInfo 新增两键；trust_nxt2_sign 边界（§N7:236）未触碰 |

**边界（修 C）**：全部改动 WanWo/ 层（GuestRunSupport.{h,m} 注释与失败路径诊断）+ 本节登记，**vendored 树零 diff**；无新增文件（project.yml 零改动）；macho_after_sign 仍为 token 唯一合法实现。

**边界**：全部改动 WanWo/ 层四文件（BuildService.swift/BuildTools.swift/GuestRunSupport.{h,m}），**vendored 树零 diff**；build_ipa/交付路线/app 路线（prepareGuestRun/GuestRunSession）零改动；utility 签名编排顺序（补片→ZSign→token→fastpath）零改动；stop_build/build_and_run 语义零改动；无新增文件（project.yml 零改动）；trust_nxt2_sign 历史裁决（§N7:236）维持——macho_after_sign 为 token 唯一合法实现，本轮未触碰该边界。

### N10e 第二批 · utility 终端修复 F/G/H/I（2026-10-21，用户拍板全修；语义拍板=修 F「和 app 一样」——stop_build 主动关窗+自然退出也自动关窗不留空壳；诊断=analysis/utility-terminal-build-failure-diagnosis.md「utility 终端新问题三连」）

**考古定罪复核结论（施工前全文复读）**：①NXWindowSessionTerminal.m exitingCallback（:167-187）focused 态只写 "[process exited]"+atExit=YES 不关窗，关窗仅 deactivateWindow（:232-236）/sendWithSource（:263-266）两触发点；万我环境 activateWindow（:221）后恒 focused → 进程退出必留空壳；②exitingCallback 触发线程不保证主线程（官方回调内关窗自走 dispatch_async(main) :183 为证）；③PEProcess.terminate（PEProcess.m:232-236）=sendSignal(SIGKILL)→[self.process.nsExtension _kill:SIGKILL]——对已死进程官方容错有先例：自然退出链 processDidExit 内 dispatch_async(main) closeWindowWithIdentifier（:286-294）→NXWindow.closeWindowWithCompletion（NXWindow.m:153-179，dispatch_once _closeOnce 幂等）→session closeWindow→[_process terminate]——官方本来就对已死进程 terminate（NXWindowSessionApplication.closeWindow 同款），_kill 返回错误码被弃不炸；④退出码可及：exitingCallback 在 processDidExit :284 触发，同函数 :275 已读 arg1.exitContext.underlyingContext.legacyCode——回调时退出码可及（app 路线 spawnRun 同点同读实证）；⑤修 I 钩子在位：TerminalViewObjC.ttyHandle（=masterFD）readabilityHandler 是输出数据唯一入口（availableData→main 队列 feed）——万我树内 Terminal.swift 副本（非 vendored）可加 tee 分流，降级条件（SwiftTerm 封装过深）不成立。

| 项 | 内容 |
|---|---|
| 修 F 关窗（GuestWindowBridge） | openUtilityTerminalWithPath 签名直改（+windowIdentifierOut:(id_t*)+teeLog 参数——全树唯一消费点 BuildAndRunTool 同步改，保留旧形态即死代码故取直改）；新增 closeTerminalWindowWithIdentifier:（wanwoServerActivated 守卫+主队列 dispatch——show/hideGuestOverlay 同款模式；vendored closeWindowWithIdentifier 自带主线程 assert）；NXWindow.closeWindowWithCompletion dispatch_once（NXWindow.m:155）保证与官方 sendWithSource/deactivateWindow 关窗路径竞态双重关闭幂等无害；关窗链=closeWindowWithIdentifier→NXWindow.closeWindowWithCompletion（0.25s 动画）→session closeWindow（terminate 容错见上）→windowWantsToClose（NXWindowServer.m:822-831）→windows 字典拆除→既有 A2 hideGuestOverlayIfNoWindows(afterDelay:1.0) 联动（unregisterUtilityProcess 内保留——1.0s 余量>0.25s 动画，判定排在字典拆除后） |
| 修 G 退出事件（GuestRunService） | registerUtilityProcess 扩展（projectName/windowIdentifier/teeLog/prepDetail/writer 同处登记+stopRequested 清零）；noteUtilityExitRaw（exitingCallback 任意线程采集——lock 内写）；unregisterUtilityProcess 升级：清登记（writer/tee 置 nil 防泄漏）→tee footer→guest_run exit 事件（modelVisible，字段与 app 路线 finalize 对齐：name/phase="exit"/result/exit/runLog/diagnostics）→A2；退出三态 composeUtilityExitMessage（stopRequested→failure「已被 stop_build 终止」/signal→failure「终端窗口关闭钮=终止进程」/自然退出→success）+renderUtilityExitNote（wait4 解码同 app 路线）；stopActiveRun utility 分支置 stopRequested 标志 |
| 修 H raw 语义告知 | BuildAndRunTool description utility 段+StopBuildTool description+ProjectCreateTool result 文本（Utility schemeNote）补：「utility 终端为 raw 模式（官方终端模拟器语义：无行缓冲/无内核回显）——交互程序需自管回显与行编辑（或逐字节读+写回，参考设备 AI 已验证的自绘回显模式）」 |
| 修 I run_log tee（Terminal.swift 万我副本） | 新增 UtilityTeeLog（@objc，串行队列收敛全部写入——readabilityHandler 后台线程触发/FileHandle 非线程安全；footer 写完即 close+closed 标志防已关句柄写异常；queue-confined 状态）；TerminalViewObjC 增 pendingTee 静态认领槽（GuestWindowBridge 开窗前置入→init 认领取走——一窗一 tee）+readabilityHandler 内 appendRaw 分流（feed 渲染链零改动）；头部行（run start+pid——bridge 开窗成功后写入，tee 串行队列 FIFO 有序）/尾部行（run end+退出注记——unregister 写）落 workspace BuildArtifacts/run_log-<HHmmss>.txt（对齐 app 路线工作区副本语义；fakefs 元数据补注册同 ipa 副本缝）；已知微小竞态：进程死亡收尾字节流若晚于 unregister 的 footer 到达则排在 footer 后（观测语义可接受，如实登记） |

**边界（N10e 第二批）**：全部改动 WanWo/ 层四文件（BuildTools.swift/GuestRunService.swift/GuestWindowBridge.{h,m}）+万我树内 Terminal.swift 副本（本就非 vendored——N10a 落位副本，适配登记原样保留）+本节登记，**vendored 树零 diff**（git diff Vendor/ 空）；build_ipa/交付路线/app 路线（prepareGuestRun/GuestRunSession/RunSession 退出事件）零改动；GuestRunSupport.m :552-640 区段未触碰；trust_nxt2_sign 未触碰；无新增文件（UtilityTeeLog 落 Terminal.swift——project.yml 零改动）；app 路线 exitingCallback 链零改动（spawnRun 的 process.exitingCallback 包装原样）。

## N11、实战轮修复批 1 · 修 J（2026-10-21，用户拍板六批修复之批 1；诊断=工作区 analysis/shizhan-crash-timeout-diagnosis.md §一）

**背景（.ips 崩溃定罪链）**：2026-10-21 17:25 宿主 WanWo 进程 SIGBUS（EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE），线程 19（无名义后台线程）撞栈守卫页（vmRegionInfo 明示 544KB 栈区=512KB+guard）；511 帧调用栈为进程内编译前端——CoreCompiler `swift::DiagnosticBridge::getSourceFileSyntax` ×105 递归 → lib_CompilerSwiftParser `parseMemberBlock` 约 93 层嵌套类型解析递归 → demangler（swift_getTypeByMangledName → decodeGenericArgs）写穿守卫页。触发输入=实战 turn 3 `build_and_run RenderCapProbe`（深层泛型 SwiftUI 探针）。

**动机（vendored 上游 bug）**：上游 `MDKPthreadDispatch` 与 `MDKThreadPool` worker 均以 `pthread_create(..., NULL, ...)`（attr=NULL）建线程——iOS 次线程默认 512KB 栈；而消费点把进程内编译前端派到这些线程上跑（见下方考古）。swiftc 官方前端惯例 8-64MB 栈，512KB 上跑递归下降解析器必然边界。

**池 worker 承载编译考古结论（施工前全文读码定案）**：编译**确实进池 worker**——`MDKPhaseEngine.m:48` clang 编译 phase 以 `withMultithreadingSupport:YES` 生成 → `MDKPhaseRunner.m:71-143 runPhase` 把编译 job `dispatchExecution` 派到 `MDKThreadPoolGroup`（继承 `MDKThreadPool`）池 worker → `MDKJob.m:98 executeJobWithOutDiagnostics → CCJobExecuteJob` 进程内编译同步执行在 worker 线程上。因此 `MDKThreadPool.m:156`（现 :192）的 worker `pthread_create` 同样需要大栈。旁证消费面：`NXBuilder+MDKDriver.swift:44-129` 池 worker 只跑依赖扫描轻活（不承载编译）；`NXDocumentManager.m:120` 文档读写（轻活）；Swift 编译 phase（`MDKPhaseEngine.m:52` =NO）串行跑在 MDKPthreadDispatch 派发线程（即 .ips 崩溃线程 19）。

**diff 内容（vendored 唯一改动文件，`git diff Vendor/` 仅此一个）**：
| 文件:行号 | 内容 |
|---|---|
| MobileDevelopmentKit/Support/MDKThreadPool.m:32-45 | `MDK_COMPILE_THREAD_STACK_SIZE` 宏（64MB）+ 定罪注释（崩溃证据/消费链/对齐 swiftc 惯例/惰性物化页说明） |
| MDKThreadPool.m:47-68 | 新增 static helper `MDKThreadAttrWithLargeStack`：`pthread_attr_init` + `pthread_attr_setstacksize(64MB)`，任一步失败 NSLog 报告（setstacksize 失败先 destroy 半成品 attr）并返回 NO——调用方回退 NULL attr（上游默认语义） |
| MDKThreadPool.m:79-109 `MDKPthreadDispatch` | pthread_create 前经 helper 构造 attr，创建后立即 `pthread_attr_destroy`；成功路径语义零变化（同签名同派发仅栈变大）；附带硬化：`pthread_create` 失败时释放 retained block 并跳过 `pthread_detach`（上游原实现忽略返回值=block 泄漏+对未初始化 thread detach 为 UB——成功路径不动，登记） |
| MDKThreadPool.m:185-211 `initWithThreads` | worker 循环共享单个 64MB attr（创建后 destroy）；`pthread_create` 失败逐个 NSLog（上游静默）；池 worker 现跑 clang 编译 job 故同栈扩容 |

**边界**：仅栈尺寸变化（512KB→64MB），函数签名/派发语义/池语义零变化；`MDKThreadPool.h` 零改动（64MB 常量私有于 .m，最小暴露面）；`MDKThreadPoolGroup.m`/`MDKPhaseRunner.m`/`MDKPhaseEngine.m`/`NXBuilder*.swift`/`NXBootstrap.m`/`NXDocumentManager.m` 全部零改动；本仓其余 vendored 路径 `git diff Vendor/` 除上述唯一文件外必须为空。64MB×N worker 为虚拟内存预留（页惰性物化），实测内存代价可忽略。

## N12、实战轮修复批 2 · 修 K+M+L+R（2026-10-21，用户拍板之批 2；诊断=工作区 analysis/shizhan-crash-timeout-diagnosis.md §二/§五/§六；**vendored 树零 diff**，全部改动 WanWo 层 + 单测）

### 修 R 全表（本节登记主体——压缩管线对齐 dsh 两段式，修 N9c 每步掩码的缓存病根）

**动机（§六 定罪）**：CondensationWorkingSet.masked 每步请求构造时把「倒数第 12 个模型可见事件前」的旧 toolResult 替换占位符——这是 View 变换（不落盘），每步新事件进窗 → cutoff 前移 → 紧贴边界的 toolResult 从全文变占位 → 该位置之后全部内容 DeepSeek 前缀缓存失效（数学：400K 上下文、失效点 ~50K 前 → 命中 ~87%，与实测 80-90% 吻合）。dsh 对照（repos/deepseek-harness-master）：无每步掩码；compaction-basic（index.ts:284-333）两段式 = 触发 → toolResultPruner.pruneSession **一次性落盘裁剪** → 重估 → 仍超限才 LLM 摘要。

| 项 | 内容 |
|---|---|
| R1 停用每步掩码 | CondensationWorkingSet.projected 删除 masked() 调用（掩码函数整体删除，git 留痕）；Policy.attentionWindow 字段删除（grep 全树消费点清点=仅掩码函数自身 + 单测构造参数，无独立消费——字段一并删除；窗口口径 12 固化为 CondensationWorkingSet.pruneWindow 常量供一级裁剪沿用）。**N9c 拍板背景知悉**：窗口 5→12 原为解决「上轮工具结果落窗致 AI 重复调用」——停用后旧工具结果保留全文，重复调用防线由 RepeatCallAdviser（已移植 dsh repeat-tool-reminder）承接，token 上涨由修 L 收敛后的 HARD 触发兜底（已拍板权衡） |
| R2 落盘裁剪记录 | CondensationRecord 扩展 `prunedSeqs: [Int]`（默认 []；语义=这些 seq 的 toolResult 在投影中以占位符呈现——**内容替换不是遗忘**，与 forgottenSeqs 严格区分）；编解码同步：空数组不落载荷（最小 payload），缺席解码=空数组（旧记录兼容），坏元素 fail closed return nil；写侧门 requiredFields 不含本字段（只增不改，旧载荷照常通过）。projected() 按 seq 精确替换 content=maskPlaceholder（turn/step/callId/错误面原样——配对不受扰、审计可溯源）；冻结语义：record 落盘后这些位置恒定，不再随步移动 |
| R3 两段式编排 | Compactor.runCondensation：触发 → **第一级无 LLM 裁剪**：selectPrunedSeqs（新纯函数：keepFirst 前缀 + 最近 12 个模型可见事件之外的非 error toolResult 全部入选；已遗忘/已裁剪/负 seq 排除；配对保护天然成立——prune 只替换载荷内容不动事件本体）→ minimum_progress 守门适配（裁剪节省 token < 工作集×0.1 跳过一级，避免无谓缓存失效）→ 落盘 prune record（forgottenSeqs=[]、可无 summary、prunedSeqs 为权威载荷面）→ 重估（口径统一结论：Compactor.estimateSession 本就经 DeriveFold 内 projected() 计价（DeriveFold.swift:27），tombstone 过滤+占位替换后与请求构造同一折叠——派单担心的「:193 传原始事件」实为已投影口径，本轮仅补合成事件模拟重估与 tokensAfter 审计）→ 仍超预算（HARD）/事件数仍超（SOFT——裁剪不减事件数，maxSize 计数口径不变，SOFT 恒走摘要）→ 第二级既有 LLM 摘要路径（遗忘集选择/序列化/summarizer/hard reset/熔断全链不动）。一级已消解（token 落回预算 + request 随 tombstone 落地清位）则跳过摘要；onCondensation 观察缝仅对含 summary 的二级 record 触发（prune record 无正文，常驻笔记缝按 summary 重写 activeContext 不消费） |
| 缓存收益机理 | 压缩之间历史逐字节稳定（占位替换一次落盘、位置冻结）→ DeepSeek 前缀缓存 ~99%（dsh 对照实证）；每步掩码的持续中段改写消除 |
| R4 兼容与测试 | CondensationTests 同步：Policy 构造去 attentionWindow 参数（4 处）；掩码测试替换为 prunedSeqs 投影/选择面/record 往返+旧载荷兼容测试（5 件）；ModelCatalogTests 默认窗口断言 1_000_000→128_000。compactNow/condensePendingRequest/catch-condense-retry 三消费面回归核对：compactNow 测试（user-only 无 toolResult）一级空转、行为同旧 |

### 修 K/M/L 速览（同批随行，dsh 语义对齐登记）

| 项 | 内容 | dsh 出处 |
|---|---|---|
| 修 K | OpenAICompatAdapter 请求超时按 wire body 体量分档：<1MB→120s / <4MB→240s / ≥4MB→300s（旧固定 60s=首 byte 前空闲上限，大 prefill 必超时 -1001；bodyData 构造上移至 urlRequest 之前供分档读取） | — |
| 修 M1 | RetryPolicy 缺省对齐 dsh（maxRetries 5 / initial 500ms / maxDelay 10s / jitter 0.1）；首 chunk 守卫：已收到任何字节的失败禁重试（防重复生成），仅未收到字节的失败重试；白名单覆盖 TIMEOUT/TRANSPORT/SERVER/RATE_LIMIT（+STREAM_CLOSED 万我既有；EMPTY_RESPONSE 差异如实登记——万我该错误经 finish(.error) 落点不在请求错误面） | packages/llm/llm/src/retry-policy.ts:14-24 |
| 修 M2 | 瞬态耗尽自愈：M1 重试耗尽仍 TIMEOUT/TRANSPORT → condensation-request(**transientExhausted** 新 reason 值，allowedValues 同步扩展) → HARD 压缩 → 重试一轮一次；每回合限 1 次（transientRecoveryAttempted per-turn 标志，与溢出恢复同款）；未落地则原样抛回原错误。既有溢出 catch-condense-retry 零回归 | compaction-basic index.ts:180-224（overflowRetries per-agent 门同构） |
| 修 L | ModelCatalogDefaults.contextWindow 1_000_000 → 128_000（保守底线；解析链顺序 entry ?? endpoint 缺省 ?? 默认 不变——/models 返回真实窗口时真实值优先，ModelDiscovery.swift:129 解析链在位）。dsh 对未配置容量直接抛 TargetPressureConfigError（index.ts:297-303）——万我保留回落但收敛保守值，偏差登记 | compaction-basic config.ts |

**边界**：全部改动 WanWo 层（OpenAICompatAdapter/RetryPolicy/AgentLoop/ModelCatalog/LLMTypes 注释/CondensationRecord/CondensationWorkingSet/Compactor/DeriveFold 注释）+ WanWoTests 两文件 + 本节；**vendored 树零 diff（git diff Vendor/ 空）**；事件 kind 词汇零新增（condensation/v1 载荷只增可选键 prunedSeqs、condensation-request/v1 值域只增 transientExhausted——旧版本读侧向前兼容，新版本读旧载荷兼容）；流式重试边界（首 chunk 后禁重试）与每回合自愈限 1 次为硬约束已落码；app 路线 RunSession/build_and_run/build_ipa 工具面零改动。

## N13、实战轮修复批 3 · 修 O+P（2026-10-21，用户拍板全修；诊断=工作区 analysis/shizhan-crash-timeout-diagnosis.md §三缺陷集；**vendored 树零 diff**，全部改动 WanWo 层）

### 修 O：utility 运行管理三连（P0-1/P0-2/P1-3）

| 项 | 内容 |
|---|---|
| O1 并发 gate | BuildAndRunTool utility 分支入口（isUtilityProject 判定后、审批/编译前——不白批一次+不省略浪费 CPU）查 GuestRunService.utilityActiveInfo()（新查询方法——取最新登记 (pid, projectName)），非 nil 即 .failure RUN_IN_FLIGHT：「utility 进程运行中（pid=X 工程=Y）——stop_build 终止或等其自然退出」（app 路线 C-b 拍板语义对齐——明确失败带活跃 pid，不自动停旧起新）。**域划分：utility-vs-utility 拒绝；utility-vs-app 不拒绝**——app 路线 C v2 开窗即返后 run 门已放行，app 长活会话（浮窗常驻交互面）与 utility 终端各自独立窗口域、无 run 门互持；O2 数组化后两路线登记/回收互相独立（旧缺陷根源=utility 单槽覆写 app 的 activeProcess——一并消除） |
| O2 全量回收 | 登记结构单槽字段（utilityProjectName/utilityWindowIdentifier/utilityTeeLog/utilityPrepDetail/utilityWriter/utilityExitRaw/utilityStopRequested 七槽）升级为 `[UtilityRegistration]` 数组（新 class 登记盒——stopRequested/timedOut/exitRaw 需跨线程置位故 class 形态；writer/tee 强引用随移除即释放，原「置 nil 防泄漏」语义由移除承接）。**抉择理由：倾向采纳**——修 O1 gate 后同一时刻常态至多 1 个 utility，但历史残留（gate 拒绝前的旧会话）与极端竞态仍可能多实例，数组一次性到位防御性回收。stopActiveRun 重写：app 分支（activeSession.stopRequested 标志）与 utility 分支（遍历全登记置 stopRequested+terminate）独立并行（app+utility 可并存——见 O1 域划分）；unregisterUtilityProcess 改按窗口 id 定位单条移除（幂等——查无静默返回），**单实例退出事件链逐项核对不破坏**：移除→超时 timer cancel（防泄漏）→tee footer→guest_run exit 事件（modelVisible 字段原样）→A2 hideGuestOverlayIfNoWindows(afterDelay:1.0)——全链与批 2 逐行同构仅作用对象由单槽改登记盒；noteUtilityExitRaw 同改按窗口 id 定位。hasActiveRegisteredProcess 扩为 activeProcess != nil ‖ !utilityRegistrations.isEmpty |
| O3 超时机制 | BuildAndRunTool utility 分支复用既有 timeout_ms 解析（5000-960000ms clamp——与 app 分支同一段代码，零重复）；registerUtilityProcess 增 timeoutSeconds 参数。消费形态：**DispatchSourceTimer**（app 路线 RunSession 用 exitSemaphore.wait(timeout:) 阻塞等待——utility 开窗即返无常驻等待段，形态照搬语义改定时器）：makeTimerSource 专用队列、deadline=.now()+t、到点 fireUtilityTimeout（lock 内置 timedOut 标志+取 process→terminate→exitingCallback→既有关窗+unregister 事件链自然收尾）；timer 句柄存登记盒（reg.timeoutTimer）+unregister 侧 cancel——两侧同址管理防泄漏；登记已移除（自然退出竞态）则无操作。退出文案三态→**四态**（composeUtilityExitMessage 增 timedOut 优先判定——对齐 app 路线 composeExitMessage 判定序：「utility 超时（Xs 保护上限）→ 已 terminate；…；超时=保护性上限非故障（默认不限时——需要更长运行时提高 timeout_ms 重跑）」，result=failure）；renderUtilityExitNote 增 timedOut（raw<0 时超时态标注 terminate 后回调未触发——app 路线 renderExitNote 同款）。默认不传=不限时（C-a 拍板语义对齐） |

### 修 P：DX 小批（测试1 P2/P3 集逐项）

| 项 | 落点 | 内容 |
|---|---|---|
| P1 build_log 渲染 | BuildLogTool.execute | 旧形态 "[\($0.severity)] \($0.message)" 直出枚举描述（实测 "[MDKDiagnosticLevel(rawValue: 3)] cannot convert..."）且无 file:line。修复（BuildService.build 渲染同源口径）：severity 经 BuildService.levelNames 映射等级名（表补齐 vendored MDKDiagnosticLevel 全枚举——fatal=4/unknown=5，MDKDiagnostic.h:39-45）；file=debugObjects 键（DebugObject.title——DebugItem 只存行列，MDKSourceLocation 无文件字段）；message 前附 file:line:col（行号>0 才附）。**排序如实报告**：按文件标题稳定化（Swift 字典遍历序不确定）；同文件条目保持落盘序不强改；与 build_ipa 摘要顺序差异根源=build() 额外 level 二次稳定排序（file→level 双键）——build_log 保持 file 单键，既有设计不强改 |
| P2 Info.plist 补键 | BuildService.createOrReuseProject（新建分支）+ injectDefaultBundleKeys | 对 Application scheme 新建工程向 Config/Project.plist 的 NXBundleInfo 注入 CFBundleDevelopmentRegion=en、CFBundlePackageType=APPL（guest Info.plist 由 NXBundleInfo 渲染——vendored NXProject.m:90 装载链，实测两键缺失=启动告警）。只补缺失键（已存在不覆盖——防冲用户自定义）；幂等 best effort（失败不阻塞创建）；**只对新建工程——复用路径不动**（避免意外改用户既有工程）；Utility 工程无 bundle 面不触碰。零 vendored（plist 万我层可写——D2 先例） |
| P3 伪 ipa 拦截 | BuildIPATool.execute（工程定位后、证书/宏预检/审批前） | projectConfig.schemeKind==.utility 即 .failure（code=UTILITY_NOT_IPA）：「UTILITY 工程（scheme=Utility）产出为裸可执行文件，不打包 .ipa——用 build_and_run 直接运行；需要分发时改用 Application scheme 工程（project_create scheme="Application"）。」消费形态参照 BuildAndRunTool 的 schemeKind 分叉先例 |
| P4 tee 头 (null) | GuestWindowBridge.m openUtilityTerminalWithPath | 定罪：头部行首 %@ = NSISO8601DateFormatter.stringFromDate 真机返回 nil（实测 "run start (null) utility=BuildProbeCLI pid=6839"——utility= 段非空，(null) 在时间戳位）。修复：改 NSDateFormatter 固定 en_US_POSIX locale + 显式 format（ISO8601 同形态 yyyy-MM-dd'T'HH:mm:ssZZZZZ，dispatch_once 单例）；时间戳/ utility 名均兜底 nil/空→"-"——禁 "(null)" 出现在产物文件头 |
| P5 截断考古+提示 | BuildIPATool BUILD FAILED 文案 | **考古结论**：万我拼接面无静默数量截断（build() 的 uniq.prefix(50) 截断带显式尾注「仅显示前 50 条」；事件 diagnostics prefix(2000) 为字符级截断——均非 3 报 2 的量级）；去重键=file:line:col:message（三类不同错误不命中）。真凶定位在 **vendored DebugDatabase.appendDebug**（Project+Debug.swift:217-229）：按 fileSourceLocation.fileURL 分桶后 `where !absPath.isEmpty`——**无文件位置的诊断被静默丢弃**（swiftc 部分诊断不带 fileSourceLocation→落 "" 桶丢弃）；CC 前端诊断收集为预编译库不可达。vendored 零改动纪律→build_ipa 失败文案追加一行「（诊断可能未列全——完整列表见 build_log）」 |

**边界（批 3）**：全部改动 WanWo 层五文件（GuestRunService.swift/BuildTools.swift/BuildService.swift/GuestWindowBridge.m/docs/gpl-compliance.md 本节），**vendored 树零 diff（git diff Vendor/ 空）**；app 路线（prepareGuestRun/GuestRunSession/spawnRun/waitForAndFinalize/finalizeRunSession/composeExitMessage/renderExitNote）零改动——O3 timer 形态参照实现但 app 代码未触碰；批 2 浓缩/重试链路零改动；GuestRunSupport.m :552-640 签名薄壳区段未触碰；trust_nxt2_sign（§N7:236）未触碰；交付路线 signAndRepackage 零改动；utility 签名编排（prepareUtilityRun 四步）零改动；project.yml 零改动（无新增文件）。
