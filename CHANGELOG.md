# Changelog

What's new in each version of Overheard. `release.sh` puts the section of the version it publishes
in the update window and on the GitHub release, so write it for people who use the app.

## 0.3.1

- New installs on macOS 15 transcribe **on your Mac** by default: no account and no API key. The models download during the introduction. If you already use ElevenLabs, nothing changes.
- Summaries with Claude Code run with no tools and no MCP servers, in an empty folder: whatever anyone says in a call stays text and is never run as a command.
- Updates now come from getoverheard.dev.

## 0.3

- **Apple Intelligence** for summaries and chat: everything on your Mac, no account and nothing to install (macOS 26, Apple Intelligence turned on).
- Pick the AI for summaries and chat in **Settings**: Claude Code, Codex or Apple Intelligence.
- Updates no longer interrupt you: during a call or a transcription Overheard waits, and shows a dot on the menu bar icon instead.
- New option: **Install updates automatically**.
- Signed and notarized by Apple: Overheard opens with a double click, no more "Open Anyway". Because the signature changes, macOS asks once more for microphone and system audio access after this update.

## 0.2.2

- Chat explains what to install when neither Claude Code nor Codex is found, instead of accepting questions it cannot answer.
- Shows which engine transcribed each meeting (ElevenLabs, on your Mac, or fallback).

## 0.2.1

- Fixed meetings showing "Recording interrupted" while the call was still being recorded.
- **Retry** button for failed transcriptions.

## 0.2

- Recordings interrupted by quitting or a crash are recovered and transcribed at the next launch.
- ElevenLabs key is checked as soon as you paste it, with a clear message if it is wrong or lacks the Speech to Text permission.
- Claude Code and Codex are found even when installed with nvm, npm or in `~/.zshrc`.
- Permissions are asked one by one in the introduction.

## 0.1

- First release: recording, transcription, summaries, chat, MCP server, automatic updates.
