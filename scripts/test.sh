#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_dir/.build"
xcrun swiftc -swift-version 5 -O -module-cache-path "$project_dir/.build/module-cache" \
  "$project_dir/Sources/AudioPreparation.swift" "$project_dir/Tests/AudioTests.swift" \
  -o "$project_dir/.build/AudioTests"
"$project_dir/.build/AudioTests"
if grep -n '[АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя]' "$project_dir"/Sources/*.swift "$project_dir/Info.plist"; then
  echo "Unexpected non-English UI strings." >&2
  exit 1
fi
