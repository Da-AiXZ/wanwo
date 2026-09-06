#!/bin/bash
set -e

# ============================================================================
# 万我 · Alpine rootfs 准备（CI 用）
# ============================================================================
# 流程（照 OpenMinis deps/prepare_alpine_rootfs.sh 验证过的路线）：
#   1. macOS native meson 构建 fakefsify 工具（tar.gz → iSH fakefs 格式）
#   2. 下载 Alpine minirootfs aarch64（版本固定 + sha256 可选校验）
#   3. fakefsify 转换 → alpine-rootfs/{data/,meta.db}
#   4. 基础配置（目录/resolv.conf/repositories/profile）
#   5. 产出目录整体进 App bundle（folder reference）
#
# 关键认知：fakefs 的权限/属主存在 meta.db（SQLite），不在文件系统位上，
# 所以 bundle 目录拷贝丢执行位无所谓 —— 这正是用 fakefsify 的原因。
#
# 产物: WanWo/Resources/rootfs/  （data/ + meta.db）
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ISH_DIR="$ROOT_DIR/Vendor/ish"
RES_DIR="$ROOT_DIR/WanWo/Resources"
OUT_DIR="$RES_DIR/rootfs"

ALPINE_VERSION="3.21"
ALPINE_MINOR="0"
ALPINE_ARCH="aarch64"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ROOTFS_FILE="alpine-minirootfs-${ALPINE_VERSION}.${ALPINE_MINOR}-${ALPINE_ARCH}.tar.gz"
ROOTFS_URL="$ALPINE_MIRROR/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/${ROOTFS_FILE}"

CACHE_DIR="$ROOT_DIR/.cache"
log_step() { echo "==> $1"; }
log_ok()   { echo "OK  $1"; }
die()      { echo "FAIL $1" >&2; exit 1; }

build_fakefsify() {
    log_step "Building fakefsify (native macOS tool)"
    # fakefsify 依赖 libarchive（meson 探测 /opt/homebrew/opt/libarchive —— tools/meson.build 已内置该路径）
    command -v brew >/dev/null && brew list libarchive >/dev/null 2>&1 || brew install --quiet libarchive || die "libarchive install failed"
    NATIVE_DIR="$ISH_DIR/build-native"
    if [ ! -f "$NATIVE_DIR/tools/fakefsify" ]; then
        cd "$ISH_DIR"
        meson setup "$NATIVE_DIR" --buildtype=release \
            -Dkernel=ish -Dengine=asbestos -Dguest_arch=arm64 -Db_ndebug=true \
            || die "native meson setup failed"
        ninja -C "$NATIVE_DIR" tools/fakefsify || die "fakefsify build failed"
        cd "$ROOT_DIR"
    fi
    [ -x "$NATIVE_DIR/tools/fakefsify" ] || die "fakefsify binary missing"
    log_ok "fakefsify ready"
}

download_rootfs() {
    log_step "Downloading Alpine minirootfs"
    mkdir -p "$CACHE_DIR"
    [ -s "$CACHE_DIR/$ROOTFS_FILE" ] || curl -fSL --retry 3 -o "$CACHE_DIR/$ROOTFS_FILE" "$ROOTFS_URL" \
        || die "download failed: $ROOTFS_URL"
    ls -lh "$CACHE_DIR/$ROOTFS_FILE"
    log_ok "downloaded"
}

convert_and_configure() {
    log_step "Converting to fakefs format"
    rm -rf "$OUT_DIR"
    mkdir -p "$RES_DIR"
    "$ISH_DIR/build-native/tools/fakefsify" "$CACHE_DIR/$ROOTFS_FILE" "$OUT_DIR" \
        || die "fakefsify conversion failed"
    [ -d "$OUT_DIR/data" ] && [ -f "$OUT_DIR/meta.db" ] || die "fakefs output incomplete"
    log_ok "data/ + meta.db created"

    DATA="$OUT_DIR/data"
    mkdir -p "$DATA/dev" "$DATA/proc" "$DATA/sys" "$DATA/tmp" "$DATA/run" "$DATA/root" "$DATA/home"

    # root shell 固定为 /bin/sh
    if [ -f "$DATA/etc/passwd" ]; then
        sed -i.bak 's|^root:.*|root:x:0:0:root:/root:/bin/sh|' "$DATA/etc/passwd" && rm -f "$DATA/etc/passwd.bak"
    fi

    cat > "$DATA/etc/resolv.conf" << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

    cat > "$DATA/etc/apk/repositories" << EOF
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community
EOF

    cat >> "$DATA/etc/profile" << 'EOF'
export PS1='\u@wanwo:\w\$ '
export TERM=xterm-256color
export HOME=/root
export LANG=C.UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd ~
EOF

    # Y9 兜底：bundle 拷贝会丢执行位，fakefs 权限在 meta.db 不受影响；
    # 但 data 内真实文件的 mode 位仍整理一遍，双保险
    chmod -R u+rw "$DATA" 2>/dev/null || true

    # 打成单个 tar（ustar）：避免 folder reference 的逐文件资源冲突
    # （apk keys 多架构同名文件会让 CpResource 冲突 exit 65）
    cd "$OUT_DIR"
    rm -f "$RES_DIR/rootfs.tar"
    tar -cf "$RES_DIR/rootfs.tar" data meta.db
    cd "$ROOT_DIR"
    rm -rf "$OUT_DIR"

    log_ok "rootfs packaged at $RES_DIR/rootfs.tar"
    ls -lh "$RES_DIR/rootfs.tar"
}

main() {
    echo "==== WanWo Alpine rootfs (v${ALPINE_VERSION}.${ALPINE_MINOR} ${ALPINE_ARCH}) ===="
    build_fakefsify
    download_rootfs
    convert_and_configure
    echo "==== done ===="
}

main "$@"
