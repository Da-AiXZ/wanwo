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
