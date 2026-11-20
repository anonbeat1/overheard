# Changelog

What's new in each version of Overheard. `release.sh` puts the section of the version it publishes
in the update window and on the GitHub release, so write it for people who use the app.

## 0.4

- **Cloud storage**, off until you turn it on: keep a copy of every meeting in Google Drive, Dropbox, OneDrive, iCloud Drive, a synced folder, WebDAV (Nextcloud, NAS…) or S3-compatible storage. Each copy is checked before anything is removed from your Mac. Thanks @Til0r!
- **Free up audio space**: once a meeting is transcribed and safely in the cloud, its audio can leave your Mac and come back with one click when you want to listen again. It can also happen automatically after 7, 30 or 90 days.
- Nothing is ever deleted for good: removed cloud copies go to the service's trash, and a meeting deleted on the cloud side is not uploaded again unless you choose to.
- **Sync conflict copies** (Syncthing, Dropbox, iCloud, Drive) show up in the library to review instead of appearing as new meetings.
- Uploads and downloads show size, speed and time left, with a Stop button. Guide: [getoverheard.dev/cloud-storage](https://getoverheard.dev/cloud-storage/).
- Overheard now speaks **ten more languages**: Arabic, Bengali, Chinese (Simplified), French, German, Hindi, Japanese, Portuguese, Russian and Spanish. It follows your Mac's language, or pick one in Settings. Thanks again @Til0r!
- Settings content no longer scrolls under the window buttons.

## 0.3.2

- Select several meetings in the library (checklist button or ⌘-click) and move them to the Trash with one confirmation. Thanks @VitoSaulle!
- **Tell participants** while recording: copies a short message to paste in the call chat, saying you are recording and that they can ask you to stop.

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
