#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cache_dir="${CALLTOCODEX_CACHE_DIR:-$project_dir/.cache}"
resources="${1:-$project_dir/dist/CallToCodex.app/Contents/Resources}"
if [[ "${CALLTOCODEX_TEST_CPU_ONLY:-0}" == "1" ]]; then
  test_resources="$(mktemp -d "${TMPDIR:-/tmp}/call-to-codex-cpu-test.XXXXXX")"
  trap 'rm -rf "$test_resources"' EXIT
  for name in CallToCodexProcessor ggml-large-v3-turbo-q5_0.bin ggml-silero-v6.2.0.bin; do
    ln -s "$resources/$name" "$test_resources/$name"
  done
  ln -s "$resources/whisper-cli" "$test_resources/whisper-engine"
  cat > "$test_resources/whisper-cli" <<'SH'
#!/bin/bash
exec "$(dirname "$0")/whisper-engine" --no-gpu "$@"
SH
  chmod +x "$test_resources/whisper-cli"
  resources="$test_resources"
fi
mkdir -p "$project_dir/.build"
xcrun swiftc -swift-version 5 -O -module-cache-path "$project_dir/.build/module-cache" \
  "$project_dir/Tests/TranscriptionTests.swift" -parse-as-library -o "$project_dir/.build/TranscriptionTests"
"$project_dir/.build/TranscriptionTests" "$resources" "$cache_dir/whisper.cpp/samples/jfk.wav"
