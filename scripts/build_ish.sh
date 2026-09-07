#!/bin/bash
set -e

# ============================================================================
# 万我 · iSH-ARM64 静态库构建（CI 用）
# ============================================================================
# 改造自 OpenMinis deps/build_ish.sh（生产验证模板），适配 GitHub Actions：
#   - 不做 submodule init（Vendor/ish 已含构建所需全部源码；
#     deps/libapps、libarchive、linux 三个空 submodule 不参与三库构建）
#   - LLVM 用 brew --prefix 探测（runner 上路径不固定）
#   - 产物输出到 Vendor/libs / Vendor/include / Vendor/resources
#
# 用法: ./scripts/build_ish.sh [release|debug]
# 产物: Vendor/libs/{libish,libish_emu,libfakefs}.a + Vendor/include/ish/...
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ISH_DIR="$ROOT_DIR/Vendor/ish"
OUTPUT_LIBS="$ROOT_DIR/Vendor/libs"
OUTPUT_INCLUDE="$ROOT_DIR/Vendor/include"
OUTPUT_RESOURCES="$ROOT_DIR/Vendor/resources"

BUILD_TYPE="${1:-release}"
ARCHS="arm64"
IOS_DEPLOYMENT_TARGET="14.0"

log_step() { echo "==> $1"; }
log_ok()   { echo "OK  $1"; }
die()      { echo "FAIL $1" >&2; exit 1; }

check_prerequisites() {
    log_step "Checking prerequisites"
    command -v meson >/dev/null || die "meson missing (brew install meson)"
    command -v ninja >/dev/null || die "ninja missing (brew install ninja)"
    xcode-select -p >/dev/null 2>&1 || die "Xcode CLT missing"
    LLVM_PREFIX="$(brew --prefix llvm 2>/dev/null || true)"
    LLD_PREFIX="$(brew --prefix lld 2>/dev/null || true)"
    if [ -n "$LLVM_PREFIX" ] && [ -x "$LLVM_PREFIX/bin/clang" ]; then
        echo "LLVM: $LLVM_PREFIX (vdso build enabled)"
        export PATH="$LLVM_PREFIX/bin:$PATH"
    else
        echo "WARN: brew llvm not found, vdso build will be skipped"
    fi
    if [ -n "$LLD_PREFIX" ] && [ -d "$LLD_PREFIX/bin" ]; then
        export PATH="$LLD_PREFIX/bin:$PATH"   # 提供 ld.lld（-fuse-ld=lld）
    fi
    log_ok "prerequisites"
}

setup_cross_compile() {
    log_step "Setting up iOS cross compilation"
    BUILD_DIR="$ISH_DIR/build-ios"
    mkdir -p "$BUILD_DIR"
    IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)

    cat > "$BUILD_DIR/ios-cross.txt" << EOF
[binaries]
c = ['clang', '-arch', 'arm64', '-isysroot', '$IOS_SDK', '-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET']
ar = 'ar'
strip = 'strip'
pkg-config = 'false'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = []
c_link_args = ['-L$IOS_SDK/usr/lib']

[properties]
needs_exe_wrapper = true
sys_root = '$IOS_SDK'
library_dirs = ['$IOS_SDK/usr/lib']
EOF
    log_ok "cross file: $BUILD_DIR/ios-cross.txt"
}

build_ish() {
    log_step "Building iSH libraries ($BUILD_TYPE, b_ndebug enforced)"
    cd "$ISH_DIR"

    # 一级坑 R1：release 必须编掉 assert（mem_ptr CoW assert 曾 SIGABRT 上架）
    MESON_BUILDTYPE="release"; MESON_NDEBUG="true"
    if [ "$BUILD_TYPE" == "debug" ]; then
        MESON_BUILDTYPE="debug"; MESON_NDEBUG="false"
    fi

    if [ ! -f "$BUILD_DIR/build.ninja" ]; then
        meson setup "$BUILD_DIR" \
            --cross-file "$BUILD_DIR/ios-cross.txt" \
            --buildtype="$MESON_BUILDTYPE" \
            -Db_ndebug="$MESON_NDEBUG" \
            -Dlog="" \
            -Dlog_handler=nslog \
            -Dkernel=ish \
            -Dengine=asbestos \
            -Dguest_arch=arm64
    else
        meson configure "$BUILD_DIR" --buildtype="$MESON_BUILDTYPE" -Db_ndebug="$MESON_NDEBUG"
    fi

    ninja -C "$BUILD_DIR" libish.a libish_emu.a libfakefs.a

    # VDSO（尽力而为；缺失时 M0 不阻塞）
    ninja -C "$BUILD_DIR" vdso/arm64/libvdso.so.elf \
        || echo "WARN: vdso build failed (continuing without)"

    cd "$ROOT_DIR"
    log_ok "libraries built"
}

copy_outputs() {
    log_step "Copying outputs"
    BUILD_DIR="$ISH_DIR/build-ios"

    mkdir -p "$OUTPUT_LIBS" "$OUTPUT_RESOURCES"
    rm -rf "$OUTPUT_INCLUDE"; mkdir -p "$OUTPUT_INCLUDE/ish"

    cp "$BUILD_DIR/libish.a"     "$OUTPUT_LIBS/"
    cp "$BUILD_DIR/libish_emu.a" "$OUTPUT_LIBS/"
    cp "$BUILD_DIR/libfakefs.a"  "$OUTPUT_LIBS/"

    # VDSO：arm64 路径优先
    if [ -f "$BUILD_DIR/vdso/arm64/libvdso.so.elf" ]; then
        cp "$BUILD_DIR/vdso/arm64/libvdso.so.elf" "$OUTPUT_RESOURCES/"
    elif [ -f "$BUILD_DIR/vdso/libvdso.so.elf" ]; then
        cp "$BUILD_DIR/vdso/libvdso.so.elf" "$OUTPUT_RESOURCES/"
    fi

    # ---- 头文件清单（照 OpenMinis 模板） ----
    H="$OUTPUT_INCLUDE/ish"
    mkdir -p "$H/emu" "$H/kernel" "$H/fs/proc" "$H/util" "$H/platform" "$H/asbestos" "$H/deps"

    cp "$ISH_DIR/debug.h" "$ISH_DIR/misc.h" "$ISH_DIR/xX_main_Xx.h" "$H/"
    cp "$ISH_DIR"/emu/*.h "$H/emu/"
    cp "$ISH_DIR"/kernel/*.h "$H/kernel/"
    cp "$ISH_DIR"/fs/*.h "$H/fs/"
    [ -d "$ISH_DIR/fs/proc" ] && cp "$ISH_DIR"/fs/proc/*.h "$H/fs/proc/" 2>/dev/null || true
    cp "$ISH_DIR"/util/*.h "$H/util/" 2>/dev/null || true
    cp "$ISH_DIR"/platform/*.h "$H/platform/"
    cp "$ISH_DIR"/asbestos/*.h "$H/asbestos/" 2>/dev/null || true
    mkdir -p "$H/asbestos/guest-arm64/gadgets-aarch64"
    cp "$ISH_DIR"/asbestos/guest-arm64/gadgets-aarch64/*.h "$H/asbestos/guest-arm64/gadgets-aarch64/" 2>/dev/null || true
    cp "$ISH_DIR/asbestos/gadgets-generic.h" "$H/asbestos/" 2>/dev/null || true
    mkdir -p "$H/emu/arch/arm64" "$H/kernel/arch/arm64"
    cp "$ISH_DIR"/emu/arch/arm64/*.h "$H/emu/arch/arm64/" 2>/dev/null || true
    cp "$ISH_DIR"/kernel/arch/arm64/*.h "$H/kernel/arch/arm64/" 2>/dev/null || true
    [ -f "$BUILD_DIR/cpu-offsets.h" ] && cp "$BUILD_DIR/cpu-offsets.h" "$H/"
    [ -f "$ISH_DIR/deps/config.h" ] && cp "$ISH_DIR/deps/config.h" "$H/deps/"

    # RootfsPatch.bundle——boot 时由 CurrentRoot.FsApplyOverlay 应用 rootfs overlay 补丁
    # （ERR-019：manifest.plist v3 → files/lib/{fetch,wasm}-polyfill.js 写入 guest /lib/，
    # /ish/overlay-version 版本管理；Platform/CurrentRoot.m 在 ISHKernel boot 流程调用）
    [ -d "$ISH_DIR/app/RootfsPatch.bundle" ] && cp -r "$ISH_DIR/app/RootfsPatch.bundle" "$OUTPUT_RESOURCES/"

    log_ok "libs+headers copied"
    ls -lh "$OUTPUT_LIBS"/*.a
}

main() {
    echo "==== WanWo iSH-ARM64 static libs (arm64 guest) ===="
    check_prerequisites
    setup_cross_compile
    build_ish
    copy_outputs
    echo "==== done ===="
}

main "$@"
