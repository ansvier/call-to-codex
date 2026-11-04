# CallToCodex 0.3.1

Local speech detection now runs before transcription. Whisper receives detected speech regions, reducing invented phrases during quiet pauses and at the end of a call. The original recording and its timeline are retained; transcript timestamps still refer to the original audio.

The small Silero VAD model is bundled, works offline and is MIT licensed. There are no phrase blacklists or automatic text deletions. Previously saved transcripts are left as they were.

Regression checks cover quiet background noise, speech on either side of a long pause, and timestamp preservation. Recognition can still make mistakes; speech detection reduces silence-related hallucinations without guaranteeing perfect transcripts.

Requires Apple Silicon and macOS 15+. The release remains ad-hoc signed and is not notarized by Apple. See the [installation instructions](https://github.com/ansvier/call-to-codex#readme).
