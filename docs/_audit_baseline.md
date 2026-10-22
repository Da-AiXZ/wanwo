# 基线精判报告

## 18 个 SPLIT 文件的基线判定（diff 行数：万我 vs main / 万我 vs 0103，小者为基线）

| 文件 | vs main | vs 0103 | 判定 |
|---|---|---|---|
| `CoreCompiler/Tools/Linker/CCLinker.cpp` | 46 | 97 | main（46 < 97） |
| `LindChain/IDEFoundation/NXBootstrap.m` | 160 | 269 | main（160 < 269） |
| `LindChain/IDEFoundation/NXCodeTemplate.m` | 15 | 133 | main（15 < 133） |
| `LindChain/IDEFoundation/NXProject.h` | 17 | 39 | main（17 < 39） |
| `LindChain/IDEFoundation/NXProject.m` | 41 | 271 | main（41 < 271） |
| `LindChain/IDEFoundation/Project+Debug.swift` | 19 | 218 | main（19 < 218） |
| `LindChain/LiveContainer/LCBootstrap.m` | 266 | 70 | 0103（70 < 266） |
| `LindChain/LiveContainer/Tweaks/Dyld.m` | 479 | 36 | 0103（36 < 479） |
| `LindChain/LiveContainer/ZSign/openssl.cpp` | 49 | 32 | 0103（32 < 49） |
| `LindChain/LiveContainer/ZSign/zsigner.h` | 24 | 14 | 0103（14 < 24） |
| `LindChain/LiveContainer/ZSign/zsigner.m` | 35 | 26 | 0103（26 < 35） |
| `LindChain/ProcEnvironment/Process/PEExtension.m` | 230 | 20 | 0103（20 < 230） |
| `LindChain/ProcEnvironment/Process/PEProcess.m` | 543 | 11 | 0103（11 < 543） |
| `LindChain/ProcEnvironment/Process/PEProcessManager.m` | 209 | 11 | 0103（11 < 209） |
| `LindChain/ProcEnvironment/Surface/sys/compat/pectl.h` | 24 | 11 | 0103（11 < 24） |
| `LindChain/Utils/entitlement.c` | 140 | 205 | main（140 < 205） |
| `LindChain/WindowServer/Session/NXWindowSessionTerminal.m` | 194 | 27 | 0103（27 < 194） |
| `MobileDevelopmentKit/Support/MDKThreadPool.m` | 114 | 185 | main（114 < 185） |

## EQ_MAIN / EQ_0103 顶层目录分布（万我原样取了哪版）

### EQ_MAIN（107）

按二级目录: 
- CoreCompiler/Tools: 17
- MobileDevelopmentKit/Support: 17
- MobileDevelopmentKit/Tools: 14
- LindChain/IDEFoundation: 12
- CoreCompiler/Support: 9
- LindChain/Utils: 7
- LindChain/IDEBuilder: 6
- MobileDevelopmentKit/PhaseEngine: 6
- Shared/Templates.bundle: 6
- LindChain/IDEConsole: 3
- LindChain/IDELanguageServer: 2
- CoreCompiler/CCBase.h: 1
- CoreCompiler/CCBaseSwift.swift: 1
- CoreCompiler/CCUtils.cpp: 1
- CoreCompiler/CCUtils.h: 1
- CoreCompiler/CCUtilsPrivate.h: 1
- CoreCompiler/CoreCompiler.h: 1
- MobileDevelopmentKit/MDKBaseSwift.swift: 1
- MobileDevelopmentKit/MobileDevelopmentKit.h: 1

### EQ_0103（178）

按二级目录: 
- LindChain/ProcEnvironment: 132
- LindChain/LiveContainer: 19
- LindChain/WindowServer: 12
- LindChain/Private: 6
- LindChain/Utils: 4
- LindChain/Debugger: 2
- LindChain/litehook: 2
- LindChain/Project: 1

