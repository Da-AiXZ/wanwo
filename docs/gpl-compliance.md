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
