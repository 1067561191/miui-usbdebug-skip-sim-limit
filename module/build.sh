#!/usr/bin/env bash
# ============================================================================
# 构建 MIUI ADB Input Bypass Zygisk 模块
# 依赖: Android NDK (默认读取 $ANDROID_HOME/ndk 下最新版本，或显式指定 NDK)
# 用法: ./build.sh            # 构建全部 ABI 并打包 zip
#       ./build.sh abi        # 只编译 .so，不打包
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")"

MODULE_ID="miui_adbinput_bypass"
MODULE_NAME="MIUI ADB Input Bypass"

# 版本号可由环境变量覆盖（CI 在打 tag 时注入），默认值用于本地构建
MODULE_VERSION="${MODULE_VERSION:-v1.0.0}"
MODULE_VERSION_CODE="${MODULE_VERSION_CODE:-1}"

# ---------- 定位 NDK ----------
# 优先级: $NDK > $ANDROID_HOME/ndk/<latest> > 报错
if [[ -z "${NDK:-}" ]]; then
    SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    if [[ -z "$SDK" ]]; then
        echo "错误: 未设置 ANDROID_HOME/NDK，且未找到 Android SDK" >&2
        exit 1
    fi
    if [[ ! -d "$SDK/ndk" ]]; then
        echo "错误: $SDK/ndk 不存在，请用 sdkmanager 安装 NDK" >&2
        exit 1
    fi
    NDK="$SDK/ndk/$(ls "$SDK/ndk" | sort -V | tail -1)"
fi

# Windows 下 NDK 的 clang 是原生程序，需要 Windows 风格绝对路径；
# Linux/macOS 无 cygpath，保持原路径（此处曾经因缺少 fallback 导致 CI 失败）。
if command -v cygpath >/dev/null 2>&1; then
    NDK=$(cygpath -m "$NDK")
fi

if [[ ! -d "$NDK" ]]; then
    echo "错误: NDK 目录不存在: $NDK" >&2
    exit 1
fi
echo "NDK: $NDK"

HOST_TAG="windows-x86_64"
case "$(uname -s)" in
    Linux*)  HOST_TAG="linux-x86_64" ;;
    Darwin*) HOST_TAG="darwin-x86_64" ;;
esac

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"

SRC_DIR="src/main/cpp"
BUILD_DIR="build"
PKG_DIR="build/pkg"

CXXFLAGS=(
    -shared -fPIC -O2
    -std=c++17
    -fno-exceptions -fno-rtti
    -fvisibility=hidden -fvisibility-inlines-hidden
    -Wall -Wextra
    "-I$SRC_DIR"
)
LDLIBS=(-llog -static-libgcc)

# API level：Zygisk 官方 sample 用 android-21；这里取 26 兼顾新 API 与覆盖率
API=26

# ABI  ->  clang 前缀
declare -A ABI_PREFIX=(
    [arm64-v8a]="aarch64-linux-android"
    [armeabi-v7a]="armv7a-linux-androideabi"
    [x86]="i686-linux-android"
    [x86_64]="x86_64-linux-android"
)

build_abi() {
    local abi="$1"
    local prefix="${ABI_PREFIX[$abi]}"
    local cc="$TOOLCHAIN/${prefix}${API}-clang"
    local out="$BUILD_DIR/$abi"
    mkdir -p "$out"

    if [[ ! -x "$cc" ]] && [[ ! -x "$cc.cmd" ]]; then
        echo "跳过 $abi (找不到编译器 $cc)"
        return 0
    fi

    echo "==> 编译 $abi"
    "$cc" "${CXXFLAGS[@]}" \
        -o "$out/$abi.so" \
        "$SRC_DIR/module.cpp" "$SRC_DIR/abi_stub.cpp" \
        "${LDLIBS[@]}"
}

ALL_ABIS=(arm64-v8a armeabi-v7a x86 x86_64)
for abi in "${ALL_ABIS[@]}"; do
    build_abi "$abi"
done

if [[ "${1:-}" == "abi" ]]; then
    echo "仅编译完成，未打包。产物在 $BUILD_DIR/<abi>/"
    exit 0
fi

# ---------- 打包 Magisk 模块 zip ----------
echo "==> 组装模块"
PKG="$PKG_DIR/$MODULE_ID"
rm -rf "$PKG"
mkdir -p "$PKG/META-INF/com/google/android"
mkdir -p "$PKG/zygisk"

# module.prop
cat > "$PKG/module.prop" <<EOF
id=$MODULE_ID
name=$MODULE_NAME
version=$MODULE_VERSION
versionCode=$MODULE_VERSION_CODE
author=CMing
description=绕过 MIUI/HyperOS 「USB调试（安全设置）」需插入 SIM 卡的限制。原理：在 system_server 中置 persist.security.adbinput=1 并刷新权限缓存，使 uid=2000(shell) 获得 INJECT_EVENTS 等权限。仅影响 shell。
EOF

# 拷贝 .so
for abi in "${ALL_ABIS[@]}"; do
    if [[ -f "$BUILD_DIR/$abi/$abi.so" ]]; then
        cp "$BUILD_DIR/$abi/$abi.so" "$PKG/zygisk/$abi.so"
    fi
done

# 安装脚本（Magisk 官方模板）
cp template/update-binary "$PKG/META-INF/com/google/android/update-binary"
cp template/updater-script "$PKG/META-INF/com/google/android/updater-script"
cp template/customize.sh "$PKG/customize.sh"

# 打包（用 Python 实现，避免依赖 zip 命令；Windows 环境常见缺失）
ZIP_OUT="$BUILD_DIR/${MODULE_ID}-${MODULE_VERSION}.zip"
rm -f "$ZIP_OUT"

python - "$PKG" "$ZIP_OUT" <<'PY'
import os, sys, zipfile

src_dir, zip_path = sys.argv[1], sys.argv[2]

with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(src_dir):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(root, name)
            rel = os.path.relpath(full, src_dir).replace(os.sep, "/")
            zf.write(full, rel)
    # Magisk 要求 update-binary 具备可执行权限
    for info in zf.infolist():
        if info.filename.endswith("update-binary"):
            info.external_attr = (0o755 << 16) | 0o100000
print("packed:", zip_path)
PY

echo
echo "完成: $ZIP_OUT"
ls -la "$ZIP_OUT"
unzip -l "$ZIP_OUT" | tail -15

echo
# 输出 SHA256，便于 CI 写入 Release 说明
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$ZIP_OUT" | awk '{print "SHA256=" $1}'
else
    shasum -a 256 "$ZIP_OUT" | awk '{print "SHA256=" $1}'
fi
