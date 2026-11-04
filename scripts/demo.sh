#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
demo_root="$(mktemp -d "${TMPDIR:-/tmp}/call-to-codex-demo.XXXXXX")"
screenshots="$demo_root/screenshots"
demo_app="${CALLTOCODEX_PREVIEW_APP:-${TMPDIR:-/tmp}/CallToCodex Preview.app}"
if [[ ! -x "$project_dir/.build/CallToCodex" ]]; then echo "Run ./scripts/build.sh first." >&2; exit 1; fi
mkdir -p "$demo_root" "$demo_app/Contents/MacOS" "$demo_app/Contents/Resources"
for entry in '2026-11-04_14-25-00_demoRelease' '2026-11-04_13-10-00_demoDesign' '2026-11-03_18-40-00_demoWeekly'; do
  mkdir -p "$demo_root/$entry"
  printf '# Demo transcript\n\nSynthetic conversation data for documentation screenshots.\n' > "$demo_root/$entry/transcript.md"
done
cat > "$demo_root/2026-11-04_14-25-00_demoRelease/session.json" <<'JSON'
{"title":"Release planning","status":"done","created_at":"2026-11-04T14:25:00+03:00","thread_id":"demo-release"}
JSON
cat > "$demo_root/2026-11-04_13-10-00_demoDesign/session.json" <<'JSON'
{"title":"Design review — classic never gets old","status":"transcribed","created_at":"2026-11-04T13:10:00+03:00"}
JSON
cat > "$demo_root/2026-11-03_18-40-00_demoWeekly/session.json" <<'JSON'
{"title":"Weekly sync","status":"done","created_at":"2026-11-03T18:40:00+03:00","thread_id":"demo-weekly"}
JSON
printf '# Demo summary\n\nShip the release on Friday. Audio stays local.\n' > "$demo_root/2026-11-04_14-25-00_demoRelease/summary.md"
cp "$project_dir/.build/CallToCodex" "$demo_app/Contents/MacOS/CallToCodex"
cp "$project_dir/Info.plist" "$demo_app/Contents/Info.plist"
if [[ -f "$project_dir/.build/AppIcon.icns" ]]; then cp "$project_dir/.build/AppIcon.icns" "$demo_app/Contents/Resources/AppIcon.icns"; fi
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.answer.CallToCodex.Preview' "$demo_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName CallToCodex Preview' "$demo_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName CallToCodex Preview' "$demo_app/Contents/Info.plist"
codesign --force --sign - "$demo_app"
open --env "CALLTOCODEX_RECORDINGS_ROOT=$demo_root" --env CALLTOCODEX_DEMO=1 \
  --env "CALLTOCODEX_SCREENSHOT_DIR=$screenshots" "$demo_app"
echo "Demo data only. The first screenshot is exported automatically."
echo "Use App menu → Save Demo Screenshot for another frame."
echo "Preview: $demo_app"
echo "Screenshots: $screenshots"
echo "Copy the exported PNG files into docs/screenshots/ when finished."
