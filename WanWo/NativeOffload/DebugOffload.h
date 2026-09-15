//
//  DebugOffload.h
//  WanWo
//
//  【vendored 复用 · 源=OpenMinis src/ios/NativeOffloads/DebugOffload.h，
//   语义 1:1，仅文件头注释 MinisApp→WanWo 改名】
//
//  Native offload handler for `wanwo-debug`. RPC-backed subcommands are
//  Debug-build-only (they route through DebugLocalDispatch, compiled out in
//  Release). The `logs` subcommand reads the app's own runtime log in-process
//  and is available in ALL builds (T-ios-minis-debug-logs-oslogstore), so the
//  handler is registered unconditionally.
//

#ifndef DebugOffload_h
#define DebugOffload_h

/// Register the wanwo-debug native handler. Registered in every build so the
/// Release-safe `logs` subcommand is reachable; RPC subcommands self-report as
/// DEBUG-only at dispatch time.
void debug_offload_register(void);

#endif /* DebugOffload_h */
