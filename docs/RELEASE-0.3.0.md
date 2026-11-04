# CallToCodex 0.3.0

A native Mac call recorder with a classic audio-player interface. Record your microphone and system audio, transcribe locally, then get a separate Codex chat with a TL;DR and a Markdown transcript.

- Fully English interface, controls, help text and app messages.
- Classic green display, independent audio meters and a call playlist.
- Native audio preparation and processing: no Python or FFmpeg installation required.
- Bundled whisper.cpp and Whisper large-v3-turbo Q5 model.
- Recoverable history deletion through macOS Trash, with Undo.
- Standalone Applications bundle, custom icon, DMG and ZIP downloads.
- MIT-licensed source, build instructions, native audio checks and demo screenshots.

**Requires:** Apple Silicon, macOS 15+, and a signed-in Codex desktop/CLI installation. Codex summarization uses your existing account and needs a network connection. Audio transcription runs locally.

**Early release:** ad-hoc signed; not Apple notarized. Follow the installation instructions in the [README](https://github.com/ansvier/call-to-codex#readme) if macOS blocks first launch. No Intel build or speaker diarization yet.

Download the DMG, drag CallToCodex to Applications, grant Microphone and Screen & System Audio Recording access, then quit and reopen it. Existing local call history is preserved.

`SHA256SUMS.txt` contains checksums for both downloads. The app includes the speech model, so each archive is about 550 MB. Source archives do not include model weights or recordings.
