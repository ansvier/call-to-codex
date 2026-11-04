# Troubleshooting

## Permission is enabled, but the app asks again

Keep CallToCodex in Applications and launch that copy. Quit it completely from its menu, then reopen it after changing Screen & System Audio Recording access. Closing the window alone leaves it running in the menu bar.

This release uses an ad-hoc signature. Rebuilding or updating it can change how macOS recognizes the app. If access is already enabled, remove the old CallToCodex entry from that permission list, add the current Applications copy and allow it again, then quit and reopen the app. Do not keep using an older copy from a different folder.

Microphone and system audio are separate permissions. **AUDIO ACCESS** checks the latter; **MIC CHECK · 8 SEC** checks the microphone signal.

## My voice is missing

Choose the intended input from **MICROPHONE**, then run the mic check and speak. Check System Settings → Sound → Input for its input level. Bluetooth devices may switch inputs when a meeting starts; refresh the microphone list and reselect the device.

If the app detects that the device is muted by macOS, it offers **ENABLE MIC**. This changes that device's shared hardware mute state, including for other apps using it.

## I hear myself, but not the other person

Check Screen & System Audio Recording access and the **CALL** level meter while other audio plays. System audio is independent from the **MIC** meter. Permission must be granted to the currently running build.

## The transcript exists, but there is no summary

Open Codex and confirm you are signed in. Check the internet connection, then select the call and retry. The app reuses an existing transcript and, when available, the already created chat. It does not need to record the call again.

The app searches for the `codex` executable in common installation locations and in its launch environment's `PATH`. Advanced setups can pass an explicit executable through `CODEX_BIN`.

## Import or recognition failed

Try an unprotected WAV, M4A, AIFF or MP3 file. Import support depends on macOS's audio decoders. The original file is retained in the call folder. Silent recordings are rejected before recognition.

**FOLDER** opens the selected call's local files, including diagnostic logs. Logs and recognition output may contain the conversation; inspect and redact them before sharing anything in a public issue.

## Where did a deleted call go?

Use **UNDO** immediately after deletion, or open Finder's Trash and restore the call folder. The Codex chat is not deleted with the local files. The transcript link needs its local file to exist again.
