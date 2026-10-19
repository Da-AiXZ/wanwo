//
//  WanWo-Bridging-Header.h
//  万我
//

#import "ISHKernel.h"
#import "ISHShellExecutor.h"
// 万我 M6.1 增：offload 公共设施（B1b Bridge 文件与 Swift 侧复用；
// HEADER_SEARCH_PATHS 已含 WanWo/NativeOffload，见 project.yml）
#import "NativeOffloadUtils.h"

// N2 BuildExt：CoreCompiler C API（framework 形式 include——FRAMEWORK_SEARCH_PATHS
// 已含 BUILT_PRODUCTS_DIR；Swift 侧不 import CoreCompiler module——其 umbrella
// 含 C++ 头，Xcode 16.4 Swift 无法 import，官方 Nyxian 同走 bridging header）
#import <CoreCompiler/CCUtils.h>

// N3b BuildExt：编译引导（vendored 16 化 NXBootstrap）+ 宿主 OS 读数
// （MDKOSVersion）。头树经主 target HEADER_SEARCH_PATHS=$(PROJECT_DIR)/
// Vendor/nyxian 解析（<LindChain/...> 官方路径语义）；MDK 经 framework
// include。NXBootstrap.h/MDKOSVersion.h 均纯 ObjC 无 C++，可桥。
#import <LindChain/IDEFoundation/NXBootstrap.h>
#import <MobileDevelopmentKit/MDKOSVersion.h>

// N4/N5 BuildExt：项目模型 + 构建编排（Swift 侧 NXBuilder/Project+Debug
// 消费的 ObjC 类；NXProject.h 内部链 NXPlist/NXType/NXDocument 等；
// NXPhaseRunner.h 链 NXPhaseEngine）。全部纯 ObjC 无 C++。
#import "XCButtonCompat.h"
#import <LindChain/IDEFoundation/NXProject.h>
#import <LindChain/IDEFoundation/NXUser.h>
#import <LindChain/IDEFoundation/NXUtils.h>
#import <LindChain/IDEFoundation/NXCodeTemplate.h>
#import <LindChain/IDEFoundation/NXDocumentManager.h>
#import <LindChain/IDEFoundation/NXRemoteCompiler.h>
#import <LindChain/IDEBuilder/NXPhaseRunner.h>
#import <LindChain/IDEBuilder/NXPhaseEngine.h>
#import <LindChain/IDEBuilder/LDEFilesFinder.h>
#import <LindChain/Utils/Zip.h>

// N7b BuildExt：ZSigner 证书校验/签名（Swift 侧 SigningSetupService
// checkCert 消费；N7c 签名编排 signWithAppPath 同类）。zsigner.h 纯 ObjC
// （仅 Foundation），可桥；ZSigner 类已在主 App 编译面（N7a 落位 15 文件）。
#import <LindChain/LiveContainer/ZSign/zsigner.h>

// N8 BuildExt：PE 运行侧宿主面（pe_smoke 冒烟工具消费，含 liveProcessIsAvailable；
// SigningSetupService extensionExists 走自带 fileExists 等义实现不经此处——QA 勘误）。链上头全部
// 纯 ObjC/C 可桥：PEProcessManager.h 链 PEProcess.h→Private/UIKitPrivate/
// NXWindowServer/FDMapObject/Surface proc；PELaunchServiceRegistry.h 链
// PELaunchService.h；PEContainer.h（宿主代理面，主 App 编入面 N8）链
// FDObject/Surface entitlement。<LindChain/Services/...> 代理头经主 target
// HEADER_SEARCH_PATHS 第 8 根 WanWoLiveProcess 解析。
#import <LindChain/ProcEnvironment/Process/PEProcessManager.h>
#import <LindChain/ProcEnvironment/Process/PEBootstrapRegistry.h>
#import <LindChain/ProcEnvironment/Process/PELaunchServiceRegistry.h>
#import <LindChain/ProcEnvironment/Process/PEExtension.h>
#import <LindChain/Services/containerd/PEContainer.h>
