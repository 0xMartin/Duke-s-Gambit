#!/usr/bin/env bash
# Build dukes_ai_native for all available platforms.
# Run from: duke-s-gambit/native/dukes_ai/
#
# Requirements:
#   macOS (arm64 + x86_64) — always available on macOS
#   Windows (x86_64)       — requires MinGW: brew install mingw-w64
#   Linux (x86_64)         — requires cross-compiler: brew install x86_64-unknown-linux-gnu
#   Android (arm64, arm32) — requires Android NDK; set ANDROID_NDK_ROOT

set -euo pipefail

JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)
TARGET="${1:-template_release}"

ok()   { echo "  ✓ $*"; }
skip() { echo "  – $* (skipped: $1)"; }
fail() { echo "  ✗ $* failed"; }

build() {
    local label="$1"; shift
    if scons "$@" target="$TARGET" -j"$JOBS" 2>&1; then
        ok "$label"
    else
        fail "$label"
    fi
}

echo "Building dukes_ai_native ($TARGET) with $JOBS jobs"
echo "────────────────────────────────────────────────────"

# ── macOS ──────────────────────────────────────────────────────────────────
build "macOS arm64"  platform=macos arch=arm64
build "macOS x86_64" platform=macos arch=x86_64

# ── Windows (MinGW cross-compile from macOS) ───────────────────────────────
if command -v x86_64-w64-mingw32-g++ &>/dev/null; then
    build "Windows x86_64" platform=windows arch=x86_64 use_mingw=yes
else
    skip "MinGW not found (brew install mingw-w64)" "Windows x86_64"
fi

# ── Linux (cross-compile from macOS) ──────────────────────────────────────
if command -v x86_64-unknown-linux-gnu-g++ &>/dev/null; then
    build "Linux x86_64" platform=linux arch=x86_64
else
    skip "Linux cross-compiler not found" "Linux x86_64"
fi

# ── Android ───────────────────────────────────────────────────────────────
NDK="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-}}"
if [ -z "$NDK" ]; then
    # Scan common SDK locations for any installed NDK version
    for sdk_base in \
        "$HOME/Library/Android/sdk" \
        "$HOME/Android/Sdk" \
        "/usr/local/lib/android/sdk"; do
        ndk_dir="$sdk_base/ndk"
        if [ -d "$ndk_dir" ]; then
            # Pick the latest version (last alphabetically)
            NDK=$(ls -d "$ndk_dir"/*/ 2>/dev/null | sort -V | tail -1)
            [ -n "$NDK" ] && break
        fi
        # Fallback: ndk-bundle (older Android Studio)
        if [ -d "$sdk_base/ndk-bundle" ]; then
            NDK="$sdk_base/ndk-bundle"
            break
        fi
    done
fi

if [ -n "$NDK" ]; then
    export ANDROID_NDK_ROOT="$NDK"
    build "Android arm64" platform=android arch=arm64
    build "Android arm32" platform=android arch=arm32
else
    skip "ANDROID_NDK_ROOT not set and NDK not found in common paths" "Android"
fi

echo "────────────────────────────────────────────────────"
echo "Output: $(pwd)/bin/"
ls bin/ 2>/dev/null || echo "(bin/ is empty)"
