//
//  FFmpegOffload.h
//  WanWo
//
//  【vendored 复用 · 源=OpenMinis src/ios/NativeOffloads/FFmpegOffload.h，
//   语义 1:1。适配点（简报 B1b）：①头注释 MinisApp→WanWo；②注：实现文件
//   （FFmpegOffload.m）在本仓库带 __has_include 编译期守卫——无 FFmpeg.framework
//   时为降级路径（NOT_AVAILABLE envelope），本头文件接口不变。】
//
//  Bridges FFmpeg.framework's ffmpeg_main() to iSH native offload,
//  so `ffmpeg` commands in the iSH shell execute natively via the
//  linked FFmpeg library with real-time stdio forwarding.
//

#ifndef FFmpegOffload_h
#define FFmpegOffload_h

/// Register the ffmpeg native handler with iSH's native offload system.
/// Call once after the kernel has booted (e.g. in ISHKernel.bootWithRootPath:).
/// Guest execve("/usr/bin/ffmpeg", ...) will be routed to FFmpeg.framework.
void ffmpeg_offload_register(void);

#endif /* FFmpegOffload_h */
