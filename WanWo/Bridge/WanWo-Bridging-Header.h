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
