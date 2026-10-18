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

- **lld UAF 根因（上游源码级实锤，swift-6.4.0-RELEASE 与 llvm main 同构）**：`lld/MachO/SymbolTable.cpp` 的 `dupSymDiags`（D134794 引入）文件级静态 **无 clear**（对照 undefs 有 clear=疏漏）；元素 `const Symbol *sym` 指向 per-link SymbolTable arena——同进程第二次链接 arena 释放后 Writer::run **无条件重放**残留诊断 → `toString(*悬空 sym)` UAF。src1/src2 是 std::string 值拷贝（StringRef 悬空论否证）。lld CLI 单进程单链接不触发→上游无感知。**万我侧拦截已落地（⑥）+上游 issue 草稿就绪（含 .ips 栈/地址证据，待用户拍板提交 llvm-project）**。
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
