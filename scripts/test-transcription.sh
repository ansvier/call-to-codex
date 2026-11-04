#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="${CALLTOCODEX_CACHE_DIR:-$project_dir/.cache}"
resources="${1:-$project_dir/dist/CallToCodex.app/Contents/Resources}"
mkdir -p "$project_dir/.build"
xcrun swiftc -swift-version 5 -O -module-cache-path "$project_dir/.build/module-cache" \
  "$project_dir/Tests/TranscriptionTests.swift" -parse-as-library -o "$project_dir/.build/TranscriptionTests"
"$project_dir/.build/TranscriptionTests" "$resources" "$cache_dir/whisper.cpp/samples/jfk.wav"
