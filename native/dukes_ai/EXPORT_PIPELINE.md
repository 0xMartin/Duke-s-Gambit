# Export pipeline instructions for dukes_ai_native
# Ensures correct native library is included in each Godot export

# 1. The CI workflow builds dukes_ai_native for all platforms and places the binaries in native/dukes_ai/bin/.
# 2. The Godot export step must copy the correct binary into the export directory for each platform.
# 3. In your export_presets.cfg, set up export filters to include the right native library for each platform:
#    - Windows: addons/dukes_ai_native/bin/dukes_ai_native.windows.template_release.{dll,lib}
#    - Linux:   addons/dukes_ai_native/bin/dukes_ai_native.linux.template_release.{so}
#    - macOS:   addons/dukes_ai_native/bin/dukes_ai_native.macos.template_release.{dylib}
#    - Android: addons/dukes_ai_native/bin/dukes_ai_native.android.template_release.{so}
# 4. You may need a post-export script to copy the correct binary from native/dukes_ai/bin/ to addons/dukes_ai_native/bin/ before export.
# 5. The CI workflow already automates this for GitHub Actions exports.

# See .github/workflows/ci.yml for details.
