# Post-export script for Godot: Copy correct dukes_ai_native binary
# Place this script in the project root and call it before each export if building locally.
# The CI workflow does this automatically.

import os
import shutil
import sys

PLATFORM_BINARIES = {
    "windows": "dukes_ai_native.windows.template_release.dll",
    "linux": "dukes_ai_native.linux.template_release.so",
    "macos": "dukes_ai_native.macos.template_release.dylib",
    "android": "dukes_ai_native.android.template_release.so",
}

SRC_DIR = os.path.join("native", "dukes_ai", "bin")
DST_DIR = os.path.join("addons", "dukes_ai_native", "bin")

if not os.path.exists(DST_DIR):
    os.makedirs(DST_DIR)

for platform, binary in PLATFORM_BINARIES.items():
    src = os.path.join(SRC_DIR, binary)
    dst = os.path.join(DST_DIR, binary)
    if os.path.exists(src):
        shutil.copy2(src, dst)
        print(f"Copied {src} -> {dst}")
    else:
        print(f"Warning: {src} not found, skipping.")
