#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="${CALLTOCODEX_CACHE_DIR:-$project_dir/.cache}"
build_dir="$project_dir/.build"
signing_identity="${CALLTOCODEX_SIGN_IDENTITY:--}"
whisper_commit="4da27c41cebadb3cbbcd2563e9c7cbc8d84bdcad"
model_sha="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
model_name="ggml-large-v3-turbo-q5_0.bin"
if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "This release builds on Apple Silicon macOS." >&2; exit 1
fi
cmake_bin="${CALLTOCODEX_CMAKE:-$(command -v cmake || true)}"
if [[ -z "$cmake_bin" ]]; then echo "CMake is required to build whisper.cpp. Install it first (for example: brew install cmake)." >&2; exit 1; fi
mkdir -p "$cache_dir" "$build_dir" "$project_dir/dist"
if [[ ! -d "$cache_dir/whisper.cpp/.git" ]]; then
  git clone https://github.com/ggml-org/whisper.cpp.git "$cache_dir/whisper.cpp"
fi
git -C "$cache_dir/whisper.cpp" checkout --detach "$whisper_commit"
if [[ ! -f "$cache_dir/$model_name" ]]; then
  curl -fL --retry 3 "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$model_name" -o "$cache_dir/$model_name.part"
  mv "$cache_dir/$model_name.part" "$cache_dir/$model_name"
fi
printf '%s  %s\n' "$model_sha" "$cache_dir/$model_name" | shasum -a 256 -c -
"$cmake_bin" -S "$cache_dir/whisper.cpp" -B "$build_dir/whisper" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
  "-DCMAKE_C_FLAGS=-ffile-prefix-map=$cache_dir=Dependencies -ffile-prefix-map=$project_dir=CallToCodex" \
  "-DCMAKE_CXX_FLAGS=-ffile-prefix-map=$cache_dir=Dependencies -ffile-prefix-map=$project_dir=CallToCodex" \
  -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
"$cmake_bin" --build "$build_dir/whisper" --target whisper-cli --parallel "$(sysctl -n hw.ncpu)"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx15.0 -module-cache-path "$build_dir/module-cache" \
  -file-prefix-map "$project_dir=CallToCodex" \
  "$project_dir/Sources/CallToCodex.swift" -o "$build_dir/CallToCodex"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx15.0 -module-cache-path "$build_dir/module-cache" \
  -file-prefix-map "$project_dir=CallToCodex" \
  "$project_dir/Sources/AudioPreparation.swift" "$project_dir/Sources/Processor.swift" -o "$build_dir/CallToCodexProcessor"
xcrun swiftc "$project_dir/scripts/make-icon.swift" -module-cache-path "$build_dir/module-cache" -o "$build_dir/make-icon"
mkdir -p "$build_dir/AppIcon.iconset"
"$build_dir/make-icon" "$build_dir/AppIcon.iconset"
iconutil -c icns "$build_dir/AppIcon.iconset" -o "$build_dir/AppIcon.icns"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/call-to-codex-release.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
app="$staging_dir/CallToCodex.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses"
cp "$project_dir/Info.plist" "$app/Contents/Info.plist"
cp "$build_dir/CallToCodex" "$app/Contents/MacOS/CallToCodex"
cp "$build_dir/CallToCodexProcessor" "$app/Contents/Resources/CallToCodexProcessor"
cp "$build_dir/whisper/bin/whisper-cli" "$app/Contents/Resources/whisper-cli"
cp "$cache_dir/$model_name" "$app/Contents/Resources/$model_name"
cp "$build_dir/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$project_dir/LICENSE" "$app/Contents/Resources/Licenses/CallToCodex.txt"
cp "$project_dir/LICENSES/"*.txt "$app/Contents/Resources/Licenses/"
for binary in "$app/Contents/Resources/whisper-cli" "$app/Contents/Resources/CallToCodexProcessor"; do
  codesign --force --sign "$signing_identity" "$binary"
done
if [[ "$signing_identity" == "-" ]]; then
  codesign --force --sign - "$app"
else
  codesign --force --options runtime --timestamp --entitlements "$project_dir/CallToCodex.entitlements" --sign "$signing_identity" "$app"
fi
codesign --verify --deep --strict "$app"
if [[ -d "$project_dir/dist/CallToCodex.app" ]]; then rm -rf "$project_dir/dist/CallToCodex.app"; fi
cp -R -X "$app" "$project_dir/dist/CallToCodex.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Info.plist")"
ditto -c -k --keepParent --norsrc "$app" "$project_dir/dist/CallToCodex-$version-macOS-arm64.zip"
mkdir -p "$staging_dir/dmg"
cp -R -X "$app" "$staging_dir/dmg/CallToCodex.app"
ln -s /Applications "$staging_dir/dmg/Applications"
hdiutil create -volname CallToCodex -srcfolder "$staging_dir/dmg" -ov -format UDZO "$project_dir/dist/CallToCodex-$version-macOS-arm64.dmg"
(cd "$project_dir/dist" && shasum -a 256 "CallToCodex-$version-macOS-arm64.dmg" "CallToCodex-$version-macOS-arm64.zip" > SHA256SUMS.txt)
echo "Built dist/CallToCodex.app and release archives."
