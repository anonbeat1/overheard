# Cloud storage and conflict copies

This is the technical reference. For a plain-language user guide, see [Keep your meetings, free up your Mac](https://getoverheard.dev/cloud-storage/).

Implements [#8](https://github.com/anonbeat1/overheard/issues/8) and [#7](https://github.com/anonbeat1/overheard/issues/7).

## Supported destinations

New connections offer Google Drive, Dropbox, OneDrive, iCloud Drive and custom WebDAV. Existing S3 and synced-folder configurations remain accessible for compatibility and recovery; they are not offered as new destinations. The provider details below also document these legacy configurations.

## Setup

Cloud storage is off by default. Open Settings > Cloud storage, choose where to store, connect, then turn on Sync meetings.

- **Dropbox (default, for everyone):** click Connect Dropbox and approve in the browser. Files go to `Dropbox/Apps/Overheard/<meeting>/`. The app uses an App folder, so it cannot see the rest of the Dropbox. Sign-in uses PKCE with no client secret; the refresh token is stored in Keychain. Upload verification uses Dropbox's server-computed content hash (SHA-256 over 4 MiB blocks), computed locally the same way. Files over 8 MB use upload sessions that resume at the offset Dropbox reports. Removed files stay in Dropbox's deleted files for at least 30 days.
- **Google Drive:** click Connect Google Drive and approve in the browser. A new connection creates an `Overheard` folder in My Drive and puts each meeting in its own subfolder. The app requests `drive.file`, so it sees only the files it created. A different destination folder can be set under Drive folder (advanced).
- **OneDrive:** click Connect OneDrive and approve in the browser (personal and work accounts). Files go to `OneDrive/Apps/Overheard/<meeting>/` through the `Files.ReadWrite.AppFolder` permission, so the app cannot see the rest of the drive. Verification uses OneDrive's server-computed QuickXorHash, computed locally with a port of Microsoft's reference code. Files over 10 MB use upload sessions that resume at the offset OneDrive reports; new files are created with `conflictBehavior=fail`. Downloads follow Graph's redirect only to Microsoft hosts, without the bearer token. Deleted files go to the OneDrive recycle bin.
- **iCloud Drive:** no sign-in. Files go to `iCloud Drive/Overheard/<meeting>/`; macOS uploads them. Free up audio space removes a WAV only when macOS reports the copy as uploaded (`ubiquitousItemIsUploaded`), and then also lets the iCloud copy leave the Mac; it downloads again when needed. If iCloud Drive is unavailable (signed out), the pass stops instead of treating files as missing.
- **Synced folder (Aruba Drive, Synology Drive and others):** choose the folder an official sync app keeps in the cloud; Overheard writes into `<folder>/Overheard/<meeting>/` and the app uploads it under its own terms. Folders of File Provider apps (`~/Library/CloudStorage`) are offered as quick picks. Space is freed only when macOS confirms the upload; a folder that cannot confirm it (a classic sync client) is a backup copy only, and the settings say so. Aruba Drive in particular offers no WebDAV access and its terms limit third-party access, so the official Aruba Drive app's folder is the supported route.
- **pCloud, Koofr, kDrive, Nextcloud (WebDAV):** choose the service and enter only the email (or username) and password; Overheard fills the address (pCloud EU `ewebdav.pcloud.com` or US `webdav.pcloud.com`, Koofr `app.koofr.net/dav/Koofr`, kDrive `<number>.connect.kdrive.infomaniak.com`, Nextcloud `<server>/remote.php/dav/files/<user>`). Connect and check creates the Overheard folder (MKCOL) and confirms the credentials (PROPFIND) before saving them. Koofr and Nextcloud need an app password; WebDAV is not available on some free pCloud and kSuite plans.
- **Other WebDAV servers (advanced):** for Nextcloud, ownCloud, Synology/QNAP NAS, pCloud and Koofr. Create the destination folder on the server first, then enter its full HTTPS WebDAV URL, username and app password. Nextcloud URLs look like `https://cloud.example/remote.php/dav/files/USERNAME/Overheard/`. Redirects are rejected; enter the final URL. Passwords are stored only in Keychain.
- **S3-compatible (advanced):** for Amazon S3, Cloudflare R2, Backblaze B2, Wasabi and MinIO. Enter the HTTPS endpoint (for example `https://s3.eu-central-003.backblazeb2.com`, `https://<account>.r2.cloudflarestorage.com`), region (`auto` for R2), an existing bucket, a folder in the bucket (default `Overheard`), and an access key that can read, write, list and delete objects in that bucket (listing lets a missing object answer 404 instead of 403). The secret is stored only in Keychain. Requests use path-style URLs and AWS Signature V4. Each upload is signed with the SHA-256 of its body, so the service rejects any body that does not match; the digest is stored as `x-amz-meta-sha256` and later checks read it with a HEAD. Files over 16 MB use multipart uploads that, after an interruption, list the stored parts and send only the missing ones.

Dropbox and Google Drive connect in one click when the build includes the project's OAuth apps (see below). A build without them shows fields for the user's own Dropbox App key or Google Desktop OAuth client.

### Project OAuth apps (maintainers)

With the project's own OAuth apps in the build, users only click Connect and approve in the browser. Register each app once. The repository is public, so the values never go in it: copy `.env.local.example` to `.env.local` (ignored by git), fill it in, and run `./build.sh`, which reads it and writes the values into the app's Info.plist. Both are public-client credentials by design (Dropbox PKCE App key; Google treats a desktop client secret as non-confidential), so shipping them inside the app is expected. Registration and API use are free for both services; stored files count against each user's own quota.

**Dropbox** → `OVERHEARD_DROPBOX_APP_KEY`

1. At dropbox.com/developers/apps, **Create app**: **Scoped access**, **App folder**, name `Overheard`. The name becomes the folder users see (`Apps/Overheard`); if it is taken, pick another and update the user guide.
2. **Permissions** tab: enable `account_info.read`, `files.metadata.read`, `files.content.read` and `files.content.write`, then **Submit**. Do this before the first connection: a scope added later needs every user to reconnect.
3. **Settings** tab, OAuth 2: add the redirect URI `http://127.0.0.1:53139/oauth2callback` (Dropbox accepts only registered redirects, so the callback uses this fixed loopback port), and set **Allow public clients (Implicit Grant & PKCE)** to Allow.
4. Copy the **App key**. The App secret is not used and must not be shipped.
5. A new app is in development status: up to 500 users can connect. Apply for **production** before release.

**Google Drive** → `OVERHEARD_GOOGLE_CLIENT_ID`, `OVERHEARD_GOOGLE_CLIENT_SECRET`

1. At console.cloud.google.com, create a project `Overheard`.
2. **APIs & Services → Library**: enable **Google Drive API**.
3. **Google Auth Platform**: Branding (app name, support and developer email); Audience **External**, add yourself under **Test users**; Data access: add the scope `https://www.googleapis.com/auth/drive.file` only.
4. **Clients → Create client**: type **Desktop app**. Copy the client ID and secret. Desktop clients need no redirect URI: loopback redirects on any port are allowed.
5. While the app is in **Testing**, refresh tokens expire after 7 days and only test users can connect. Before release, **Publish app**. `drive.file` is non-sensitive, so no security assessment is required, but Google may verify the brand: verified domain (getoverheard.dev), home page and a privacy policy page.

**OneDrive** → `OVERHEARD_ONEDRIVE_CLIENT_ID`

1. At entra.microsoft.com, **App registrations → New registration**: name `Overheard`, supported accounts **any organizational directory and personal Microsoft accounts**.
2. **Authentication → Add a platform → Mobile and desktop applications**, custom redirect URI `http://localhost`. Microsoft ignores the port for localhost redirects, so the loopback callback's random port matches; Overheard also listens on IPv6 because browsers may resolve localhost to `[::1]`.
3. **API permissions → Microsoft Graph → Delegated**: `Files.ReadWrite.AppFolder`, `offline_access`, `User.Read`. No client secret: the app is a public client using PKCE.
4. Copy the **Application (client) ID**. Without a verified publisher, the consent screen shows the app as unverified.

**No registration needed:** iCloud Drive, synced folders, WebDAV services and S3-compatible storage use the user's own account, app or credentials.

**S3 buckets:** Overheard aborts the multipart uploads it abandons, but a crash can still leave one behind. Add a lifecycle rule that aborts incomplete multipart uploads after a few days (AWS, R2, B2 and Wasabi all support it), so orphaned parts are never billed for long. New objects are written create-only (`If-None-Match: *`) where the service supports it, so two Macs sharing a bucket never overwrite each other.

**Credentials and signing:** tokens live in the login Keychain, trusted by the app's code signature. Builds signed with a real identity (Developer ID or Apple Development) are the ones to use with real accounts. The ad-hoc fallback in `build.sh` trusts the bundle identifier only, so another unsigned app claiming the same identifier could read the tokens: fine for a quick local try, not for daily use.

## How syncing works

For remote destinations, Overheard verifies uploaded meeting files before removing the local audio, transcript, summary, bookmarks and meeting metadata. Open a meeting and choose **Download** to work on it locally. A downloaded meeting stays on the Mac for at least 24 hours. Overheard syncs edits while the app is open, then can remove the verified files again. A small local index keeps meetings visible in the library. A legacy synced folder can keep a second copy and uses separate audio cleanup settings.

Audio can use the following formats. New remote uploads use ALAC or the original WAV:

- **Lossless (default): Apple Lossless (ALAC)**, about 4× smaller (a 40-minute call: 509 MB → 125 MB). Before an encoding is ever used, it is decoded once and compared sample by sample with the WAV; only a copy proven to rebuild the original is uploaded. Download decodes it back to a WAV with exactly the original samples. Floating-point WAVs, which ALAC cannot store losslessly, are uploaded as they are.
- **Maximum savings: AAC** (legacy synced folders), about 14× smaller (509 MB → 35 MB), at speech quality (64 kbps per mono channel at 32 kHz and above, 32 kbps below; 1.5× for stereo). A download is not identical to the original.
- **Original WAV**: the file itself.

The manifest records, for each compressed copy, the encoding, the local WAV format and the SHA-256 of the WAV it stands for. Free up audio space removes a WAV only when it is exactly that file and the cloud copy passes the usual verification. After a download, the decoded WAV becomes the recorded source, so it is not uploaded again. Encodings are cached under `~/Library/Caches/Overheard/cloud-audio` by source hash and format, so a resumed upload sends identical bytes; entries go once uploaded or after a week. Audio that cannot be encoded is uploaded as is, and a file keeps the form of its first upload.

Choose what to upload, by kind: recording audio (`recording.wav`, `mic.wav`), transcript (`transcript.md`), summary with decisions and action items (`summary.md`), bookmarks (`bookmarks.txt`), only. Arbitrary Markdown, text and JSON attachments are excluded, even when a legacy Other files setting is enabled. Metadata (`source`, `title`, `engine`, `attendees`) is always included. Turning a kind off stops future uploads and keeps the copies already in the cloud. Notes exported to a notes folder (Obsidian, Logseq, Notion) live outside the meeting folder and are not part of cloud storage. Temporary, hidden, log and symlink files are excluded.

The app reconciles completed meetings every minute and when connectivity returns while it is open, newest meetings first, one meeting at a time. A user action (download and play, retranscribe, export, any library menu item) is queued behind at most the meeting currently transferring, so it is never dropped or blocked behind a long first upload. Automatic passes pause on metered (hotspot) and Low Data networks; Sync now in Settings still runs them. A running pass can be stopped from Settings, and it stops on its own when the destination or file selection changes. Retry state, stable reserved remote IDs and verified content versions are saved atomically in each meeting's `.overheard-cloud.json`. The manifest is written only when something changed, so a library kept in Dropbox, iCloud Drive or Syncthing is not rewritten every minute. That manifest contains no credentials. Keep it with the local meeting. WebDAV can discover published meetings across devices. Other destinations still use the local map for discovery.

Unchanged files are skipped using local modification metadata. Transfers stream from file snapshots; hashes use bounded memory. Drive uploads use resumable sessions and persistent file IDs, sent in 32 MB chunks. After a lost connection or an app restart, Overheard asks Drive which bytes it already stored and sends only the rest, so a long recording does not start over. Open sessions are kept per Mac in `~/Library/Application Support/Overheard/cloud-uploads.json` (mode 600), not in the meeting folder: a session URL is a short-lived upload capability and must not travel through a synced `~/Meetings`. A session expires after six days or when Drive no longer recognises it, and the next attempt opens a new one on the same file ID.

On Drive each meeting gets its own folder inside the destination, named after the local folder plus the meeting title (`2026-11-17_1300 – Weekly sync`), with files under their plain names (`transcript.md`, and `recording.m4a` for compressed audio). The folder ID is reserved and saved before the folder is created, so a retry never creates a second one. Meetings uploaded flat by an earlier build stay flat. Remove cloud copy preserves the containing Drive folder to protect unrelated content. WebDAV uses deterministic object names. Pending content versions recover from a lost response after the server committed an upload.

## Identify a cloud library

Google Drive, Dropbox, OneDrive, iCloud Drive and WebDAV store a random library ID in `.overheard-library.json` in the selected cloud destination. Each Mac remembers the ID. A missing or different ID stops sync on a Mac that has already connected. Access still requires an authorized account.

On Google Drive, a new sign-in searches for an existing Overheard folder before creating one. If there are several folders, a single marked folder resolves the choice. Use the advanced folder setting when the choice is ambiguous. The library ID and the cross-device meeting catalog have separate support. The shared catalog is available on WebDAV.

## Use the same WebDAV library on two Macs

Connect both Macs to the same WebDAV URL with the same account. Overheard creates `.overheard-library.json` on first connection and saves its random library ID on each Mac. If the marker disappears or its ID changes, sync stops. The ID identifies the library. The server account and its permissions control access. While Overheard is open and automatic sync is available, each pass checks the remote catalog for new meetings and file revisions. A new device lists those meetings from a local index. Open a meeting and select **Download** to fetch its files. Cloud-only meetings pick up new revisions on the next pass. A cached local file is preserved if the server publishes a different version.

WebDAV updates compare the expected file digest and send a conditional write using the server's ETag. If the existing server copy has changed, Overheard keeps the local edit and reports the conflict. The catalog is published after file uploads. Simultaneous edits are not merged. Remote deletions do not propagate to local indexes.

## Delete from the cloud, keep on this Mac

Settings → More → **Delete everything from the cloud, keep on this Mac** (or Manage → **Delete from <service>** for one old service) removes a meeting's copies from every service it was ever synced to: the current manifest, a transfer's origin, a pending Move and archived destinations. Each meeting is handled under the coordinator lock, so no sync can upload it between its deletions and its cleanup. A file is deleted only when its remote digest still matches the record; audio, or any other file, that exists only in the cloud is never deleted. Each removal is written to the map as it happens, so an interrupted run leaves an exact record and the next run picks up where it stopped. A service that fails twice in a row (offline, signed out) is set aside for the rest of the run instead of failing every meeting, and the exact error is noted in the map. Google Drive moves deleted files to its trash, Dropbox keeps them in deleted files.

## The recordings map

Each meeting folder carries its manifest (`.overheard-cloud.json`), but a trashed folder or a lost disk takes it along. So every saved manifest is also recorded in a map kept per Mac outside the meeting folders: `~/Library/Application Support/Overheard/Cloud map/<meeting UUID>.json` (included in Time Machine). For each meeting it keeps the folder name, title and recording date, every destination the meeting lived on with each file's remote ID, digest, audio encoding and format, files deliberately removed (Move, Remove cloud copy) marked with a date rather than forgotten, and a history of uploads, frees, downloads and rebuilds (last 300 events). Entries only grow; nothing deletes them. At launch, meetings synced before the map existed, and the destination snapshots in their folders, are recorded once.

Settings → More → **Recover meetings from the cloud** lists meetings in the map whose folder is no longer on the Mac but whose files are still stored somewhere connected. Restore rebuilds the folder: every file is downloaded and checked against its recorded digest, compressed audio is decoded back to the original WAV samples, the folder is assembled hidden and then moved into ~/Meetings with a manifest, so the meeting rejoins sync without uploading anything again. A folder with the same name that belongs to another meeting is never overwritten (the rebuilt one gets "(restored)"). **Show the recordings map** opens the folder, and the ZIP export includes the map.

Each meeting's entry is also written into its folder as `overheard-map.json` and uploaded with the meeting (always, whatever the file toggles). If the Mac itself is lost, every meeting folder in the cloud still lists its files, their digests and formats, and where else copies lived. The copy is written last in each pass, once the other files are recorded, and only when it changed, so it never causes an upload loop; the map never lists its own copy.

## Manage storage

Right-click a meeting in the library:

- **Sync now** retries immediately and resumes a meeting whose cloud copy was explicitly removed.
- **Download** restores missing meeting files through temporary files and verifies them before installation. Download and play is also available in the transcript view. Audio export restores archived tracks before mixing them. Local text search and chat use downloaded transcripts.
- **Free up audio space** removes only local audio whose size and SHA-256 match a fresh remote verification. Both tracks are checked before cleanup. Drive uses its server checksum, with a downloaded-content fallback; WebDAV verifies downloaded bytes rather than trusting ETag or length.
- **Keep on this Mac** pins a meeting and restores missing audio. Unpinning allows later cleanup.
- **Remove cloud copy** is a separate confirmed operation. Archived audio must be downloaded first. Local files are preserved and automatic upload is paused for that meeting. Removal never deletes outright: Drive moves remote files to its Trash, Dropbox to deleted files, OneDrive to its recycle bin, a synced folder to the Mac's Trash, WebDAV moves them into `.overheard-trash/<date>/` on the server and S3 copies them under `<prefix>.trash/<time>/` before removing the original. If the server cannot do that (no MOVE, a copy that fails), nothing is removed. Overheard never empties these trashes: restoring or purging them is up to the person or the service.

**Deleting a meeting on the Mac** moves its folder to the Mac's Trash and queues its cloud copies for the service's trash. The queue (`cloud-trash-queue.json`, beside the cloud map) survives a restart and being offline, and is retried on every pass. A cloud file is moved to the trash only while its bytes still match what this Mac uploaded: a file someone else edited stays. The confirmation dialog says the cloud copies go to the service's trash.

For legacy synced folders, automatic audio cleanup can run after 7, 30 or 90 days. Age counts from the latest of the recording date (folder name), the folder creation date and the last audio download, so audio you just downloaded is not removed again on the next pass. It applies only when audio sync is on and the meeting has a transcript, so a meeting is never left with nothing readable on the Mac. It uses the same verification as manual cleanup.

Legacy synced folders can also cap local audio with a storage limit (5–100 GB). After each pass, if local audio exceeds the limit, Overheard frees verified audio starting from the oldest meeting until it fits, under the same rules as automatic cleanup except age: audio sync on, a transcript present, not pinned, and not downloaded in the last 24 hours. If the limit cannot be met, the library says by how much and why. Active recording, transcription, playback, audio export, pins and unresolved conflict copies block cleanup. Remote disappearance never deletes local data. Changed or missing remote objects produce an error and retain local content.

When cloud storage is enabled, the previous local retention job's "audio only" mode is disabled so it cannot bypass verification: freeing audio belongs to the verified cloud cleanup. Its "delete everything" mode still deletes meetings older than the chosen age, and because that is a deletion, the meeting's cloud copies are queued for the service's trash exactly as when you delete it by hand (recoverable there; Overheard never empties it). Without cloud storage, meetings that already have a cloud manifest are still skipped. Other local-only workflows remain available.

One destination is attached to each meeting. Choosing another destination asks, once per old destination and naming both (with the account when it is connected), whether to **Copy** the meetings (they stay on both), **Move** them, or **Keep** them where they are (they stay tied to the old destination, background passes leave them alone, and user actions such as Download use the old destination). The choice is stored per (new destination, old destination) pair, so a transfer resumes after a restart without asking again; Decide later asks again only after a restart; Settings lists the meetings still elsewhere with Change. A transfer started before choices were remembered continues as a copy, which never deletes. The transfer runs one meeting at a time with the original destination's credentials: files missing on the Mac (including freed audio) are downloaded and verified, every tracked file is uploaded to the new destination and verified there, and audio that was freed before is freed again, so the Mac only needs room for one meeting (checked before downloading). Move is cut and paste: it removes an original only after every copy is verified and only if the original is unchanged, then the meeting's remote folder when it is empty (Drive, Dropbox, OneDrive, synced folders) and the local record of the old destination. If the old destination is unreachable during a Move, the manifest keeps the list of old copies (`pendingRemoval`) and the next pass that can reach it finishes the removal, keeping any old copy edited there in the meantime. Settings → More offers Download all audio to this Mac and Export all meetings to ZIP; meetings left on an older destination have the same actions under Manage. The ZIP export hard-links local files into a staging folder, downloads cloud-only audio into it (verified, as its .m4a cloud copy when compressed) and archives it with `ditto`, after a free-space check; ~/Meetings is not modified. If the old destination can no longer be reached, meetings whose files are all on the Mac are still copied from it; a Move then leaves the old copies in place and says so on the meeting row. One meeting's problem stays on its row and the transfer continues; offline, authorization, quota or no room on the Mac stop it until fixed. A per-meeting record of the previous destination (`.overheard-cloud-destinations/`) makes an interrupted transfer resumable, and choosing the original destination again cancels it without deleting the partial copy.

A repair check confirms, at most once a day per file and folder, that what the manifest records is still in the cloud, and re-uploads a missing file from the Mac; Sync now runs it immediately. It asks only for the size (a HEAD on WebDAV and S3, metadata on Drive and Dropbox) and fetches the full digest only when something looks off. A file changed in the cloud by someone else is never overwritten. Disconnecting credentials does not delete remote content. Per-meeting failures retry with bounded backoff. Problems with the destination itself (offline, expired authorization, full storage, rate limits, server outages) stop the pass, appear as one message, and are not charged to individual meetings, so sync resumes everywhere as soon as the problem clears. Drive's 403 responses are read for their reason, so full storage is distinguished from a permission problem. Sync now in Settings never resumes a meeting whose cloud copy you removed; use Sync now on that meeting. A transfer that is already running finishes before settings can be changed.

## Conflict copies

The library flags Syncthing `.sync-conflict-...` and Dropbox `(…conflicted copy…)` names. Conflict copies of the hidden cloud manifest (`.overheard-cloud.sync-conflict-….json`, `.overheard-cloud (… conflicted copy).json`, `.overheard-cloud 2.json`) are flagged too and block cleanup until you choose one, because two manifests can disagree about which audio is archived. Numeric iCloud-style suffixes are flagged only when an existing original has identical recording/transcript content or the same start time. The start time is read from the first lines of a Markdown file, in the form Overheard writes (`# Transcript — 2026-11-17_121641`) or as ISO `2026-11-17T12:16:41`; only the digits are compared, so an edited copy of the same meeting is still recognised. A numeric filename alone is not evidence. These are likely conflicts, not automatic merge instructions.

**Two Macs editing the same file.** When the cloud holds a version this Mac did not upload and the local file differs too, neither is overwritten: the cloud's version is downloaded next to yours as `name (conflicted copy <host> <date>).ext`, sync of that meeting waits, and the review below lets you use the copy or keep both. Just before any upload that replaces a file, Overheard checks again that the cloud still has the version it saw (a synced folder also re-checks the file right before the swap; Dropbox commits against the exact revision, so Dropbox itself refuses an overwrite). On Drive and OneDrive a version that lands in the last moment before the commit can still be replaced; it then survives only in the service's version history. Google Drive style names (`name (1).ext`) are recognised too, under the same content-or-timestamp rule as numeric suffixes.

**First connection from two Macs.** If two Macs connect to the same empty synced folder before it has synced, each writes a library marker and the folder's client keeps one, setting the other aside as a conflict copy of `.overheard-library.json`. The Mac whose marker was set aside adopts the surviving library, but only when its own identifier is found in such a copy; a different marker with no trace of it stays a conflict.

**iCloud files that are not downloaded.** Before reading or copying an iCloud file that the system offloaded, Overheard asks for the download and waits (three minutes at most, and it can be interrupted) instead of blocking until the network returns.

Root-level conflict folders are offered in a separate review sheet rather than normal meeting rows. Conflicting files inside a meeting add a warning to its row and block automatic upload. Use Review conflict copies to reveal either item in Finder, move an item to Trash, replace the original with the chosen copy, or keep both under separate names. Replacing an original first moves it to Trash. Keeping a cloud folder as a separate meeting requires local audio and gives it a fresh identity; it never shares remote file IDs with the original. Restore remains available for archived conflict copies.

## Verification

Run `swift test` for engine and provider tests and `bash scripts/check-strings.sh` for release compilation and English string coverage. Tests use temporary meeting folders, a fake cloud and simulated HTTP responses. They do not access user meetings, Keychain or real accounts.

Tests cover verified round trips, resumable uploads that continue from the stored byte across a restart, expired sessions, per-meeting Drive folders (including retried folder creation and flat legacy meetings), storage-limit cleanup rules, offline/quota handling that does not penalise meetings, unchanged manifests not being rewritten, bulk sync not resuming removed copies, cleanup age and transcript rules, manifest conflict copies, both audio tracks, offline/restart retry, lost upload responses, local edits during retries, corrupt restore, changed/missing remote objects, pinned/active meetings, duplicate identities, explicit deletion, conflict filename evidence, path traversal and authentication/quota HTTP errors.

Live Google OAuth/Drive and a real WebDAV server still require account-based acceptance testing. No live-provider verification is implied by the automated suite. Multi-device editing and automatic library reconstruction from remote storage are outside this initial scope.

## Status

Implements [#8](https://github.com/anonbeat1/overheard/issues/8) and [#7](https://github.com/anonbeat1/overheard/issues/7) on branch `issue-8-cloud-sync`.

**Done**

- Providers: Dropbox, Google Drive and OneDrive (browser sign-in, PKCE, Keychain); iCloud Drive and synced folders such as Aruba Drive's (upload confirmed by macOS before freeing space); pCloud, Koofr, kDrive and Nextcloud via WebDAV presets with a connection check; S3-compatible storage; all behind one provider interface.
- Sync engine: verified uploads with each service's own digest, resumable uploads (Drive sessions, Dropbox upload sessions, S3 multipart), per-meeting folders, offline queue and restart recovery, destination-wide errors (offline, authorization, quota, outage) kept apart from per-meeting retry, fair queue so user actions never wait behind a long pass, pause on metered networks, manifests written only on change.
- Changing destination: Copy or Move, one meeting at a time, re-freeing audio, disk-space check, works without the old service for meetings fully on the Mac; daily repair check for missing cloud files.
- Storage: free up audio by hand, after 7–90 days or above a storage limit, under the safety rules (verified copy, transcript present, not pinned, not in use, not just downloaded); download, pin, remove cloud copy; per-kind file selection; lossless ALAC by default with sample-by-sample verification before upload, AAC and WAV as options.
- Conflict copies (#7): Syncthing, Dropbox and iCloud-numbered files and folders, including edited iCloud copies (start-time match) and copies of the cloud manifest; review sheet to use, keep or trash.
- Library, transcript view, export and MCP handle archived audio; settings and user guide (`docs/cloud-storage/`); project OAuth keys from git-ignored `.env.local`.
- Automated tests: engine, providers over simulated HTTP, the AWS SigV4 reference example, real-audio compression round trips.

**Verified on this Mac:** app builds and runs; on a real 40-minute call, WAV 509 MB, lossless 125 MB with bit-identical samples after decoding, AAC 35 MB.

**Pending**

- Register the project's Dropbox and Google apps, then acceptance-test on real accounts: connect, upload, free up space, download and play, interrupted upload, revoked access, full account.
- Test S3 on a real bucket (Backblaze B2 or Cloudflare R2) and WebDAV on a real server; iCloud Drive conflict copies on a real iCloud library.
- Before release: Google consent screen published, Dropbox production status, privacy policy page on the site; rename `## Unreleased` in CHANGELOG.md to the version.
- Possible follow-ups: browser sign-in for Nextcloud (Login Flow v2); keeping already-transcribed audio as lossless ALAC on the Mac too; settings window scrolling under the title bar (#10, separate).

Protocol references: [Google desktop OAuth](https://developers.google.com/identity/protocols/oauth2/native-app), [Drive uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads), [Drive file metadata](https://developers.google.com/workspace/drive/api/reference/rest/v3/files).

### Foreign files in cloud folders

Cloud folders are not an import source: restore uses only remote IDs and content fingerprints recorded in the local meeting manifest after upload. Extra remote files are ignored, even if they have familiar names. Restore checks the remote fingerprint before download and checks the downloaded bytes again before audio decoding or installation. A changed or missing object stops restore; changed objects also block removal and local cleanup. A retried upload must not overwrite an unrecognised object occupying a pending ID/path.

Removing a cloud copy deletes only verified, committed file IDs. It leaves the containing folder and uncommitted pending objects in place, because either may contain unrelated user content. The local manifest must be a regular file, not a symbolic link. This relies on the local manifest as the trusted record; it does not authenticate a manifest maliciously rewritten on the Mac. Arbitrary local attachments are excluded from new uploads. App producers record content fingerprints in `.overheard-generated.json`. Upload requires a matching receipt and rechecks the transfer snapshot. Missing or changed receipts block sync with an explicit error; old recordings without receipts must be explicitly reimported. Verified restores create new receipts. Receipts protect against accidental replacement, not an attacker able to rewrite both local files and app records.

## Destination changes and reconciliation

Switching to another destination requires a choice in Cloud storage: **Copy to new destination** keeps original cloud files, **Move to new destination** removes only tracked originals after every tracked file has been verified at the new destination, and Cancel leaves transfers pending. The original account must remain connected. Missing local audio is downloaded and decoded through the verified restore path; missing tracked text is downloaded and fingerprint-checked. Local edits are retained. Transfers include all previously tracked files, even when the new upload filters exclude a kind. Local recording and transcription activity and conflict copies block transfers.

The original manifest is preserved under the hidden `.overheard-cloud-destinations/<destination-hash>.json` directory. An in-progress destination also carries a recovery record, allowing an interrupted copy to resume. Recovered audio gets a fresh cleanup grace period. Move never recursively deletes folders or unrelated remote files; the two providers cannot offer a cross-service transaction, so a failed removal may leave some original copies. Repeating the transfer checks the remaining originals again.

Automatic passes check local changes every minute. Unchanged remote files are checked at most once every 15 minutes per running engine; Sync now forces an immediate check. A remote file that disappeared (deleted or trashed on the cloud side) is respected, not uploaded again: the meeting shows "Deleted from the cloud" and the person chooses **Upload to the cloud again** (menu) or **Remove cloud copy** to keep it only on the Mac. Until then even a local edit of that file waits. Only an upload this Mac itself interrupted is resumed. Changed remote files produce a conflict and are preserved. Missing archived audio is reported as unavailable rather than silently marked safe for cleanup. WebDAV verification may require downloading content because it has no trusted server digest.

The transcript’s circular share and folder menus retain local export and Finder actions. With cloud storage enabled they also offer Copy cloud folder link, Open cloud folder and Sync now. Drive and Dropbox links open the account’s folder view; copying a link does not grant sharing permissions. Other services are opened through their own clients. No live-provider acceptance test is implied by compilation.

## Acceptance evidence

Automated tests use simulated providers and temporary files; no live account acceptance is claimed. Real OAuth revocation, quota exhaustion and genuine iCloud conflict creation still require a dedicated test account/environment. Existing user meetings must not be used for destructive acceptance scenarios.

## Progress and the pending state

The bar and counters come from real numbers, not from the position in the list of meetings.

- **Network providers (Drive, Dropbox, OneDrive, WebDAV, S3).** At the start of a pass `CloudSync.pendingBytes` sums, per meeting, the size of every file that is new, changed since its last upload (stamp differs) or has an unfinished upload, skipping files deleted on the cloud side. The bar is `bytes done / bytes to send`; the meeting in progress contributes in proportion to the bytes sent of its current file. Meetings already in the cloud add nothing, so a new pass does not restart from zero, and when nothing is pending there is no bar. The estimate uses local sizes: audio uploaded as ALAC or AAC weighs less, so a meeting can finish "early"; the bar never exceeds 100%.
- **iCloud Drive and synced folders.** Overheard only copies into the folder; the system uploads. `LocalFolderProvider.uploadState()` walks `<folder>/Overheard` and, for each regular file the system tracks (`isUbiquitousItem`), reads `ubiquitousItemIsUploaded` and the size. While at least one file is not uploaded the activity row stays visible with "iCloud has uploaded N of M files" and the bar is the share of bytes uploaded. The state is re-read every 5 seconds until nothing is pending, after each pass and when the app starts. Files in a folder the system does not track are not counted: nothing is claimed about them. The system exposes no per-file percentage, so the count moves in steps.
- **Account state.** For Drive, Dropbox and OneDrive, "Sync meetings" cannot be switched on and "Sync now" is disabled while no account is connected; if it was already on, a warning explains the pause. Only a rejected grant (`invalid_grant`) is `CloudError.authExpired`: automatic passes stop and a **Reconnect** button appears next to the account until a pass succeeds or the account is reconnected. Other 400 answers from the token endpoint are setup errors that reconnecting cannot fix.

## Transfer progress, stopping and the transfers list

- **Bytes as they arrive.** `CloudHTTP.download(for:)` is the plain `session.download` unless a restore has bound `SyncProgress.downloadBytes`; then `ProgressDownload` (a `URLSessionDownloadDelegate` on a session built from the shared configuration, redirects refused as everywhere else) reports bytes received and the expected size. Drive, Dropbox, OneDrive, WebDAV and S3 downloads use it; a synced folder copies with `copyItem` and shows size only. `restore()` emits `.downloading(file, received, total)`, then `.verifying`, and `.preparing` while an ALAC copy is decoded back to WAV. Uploads already emitted `.uploading(file, sent, total)`.
- **Speed and time left.** `CloudSync` samples the progress at most once a second and smooths the rate (`transferRate`); the row shows `share · speed · ~time left`. No speed is claimed during the first second of a file.
- **Stopping.** Each per-meeting action runs in its own `Task`. `cancelAction(path)` cancels what is queued or running for one meeting, `cancelAllTransfers()` cancels all of them and the background pass. A cancelled download surfaces as `CancellationError` (a `URLError.cancelled` is converted), so the meeting is not charged a retry backoff; the partial `.cloud-*` file is removed. An action cancelled while it waits for its turn returns without doing anything.
- **Transfers list.** `CloudSync.transfers` is the set of queued and running actions with the label of what each is doing, the one in progress first; the popover offers Cancel for each and Stop all.

## Scope

Included: the destinations in "Supported destinations", verified uploads, resumable transfers, keep-both conflict copies, trash-based removal on every provider (Drive Trash, Dropbox deleted files, OneDrive recycle bin, the Mac's Trash for synced folders, `.overheard-trash/<date>/` on WebDAV, `<prefix>.trash/<time>/` on S3), the durable deletion queue, and a "Deleted from the cloud" state that waits for the person's choice.

Not included, or known limits:

- No merging of edits and no live co-editing.
- Overheard never empties any trash.
- Replacing uploads are re-checked just before the commit; only Dropbox (commit against the verified `rev`) and a synced folder (target re-checked before the swap) close the window completely. On Drive and OneDrive a version that lands in the last moment can be replaced; it then survives only in the service's version history. Their server-side preconditions are not used because their behaviour has not been verified against real accounts.
- OneDrive's `name-computer.ext` conflict copies are not recognised; Drive-style `name (1).ext` ones are, under the same content-or-timestamp rule as numeric suffixes.
- Conflict copies that a sync client creates in the remote folder (not in `~/Meetings`) are not listed; a folder duplicated by Finder with the same cloud identity blocks both meetings until one is removed.
- Automatic retention in "audio only" mode stays off while cloud storage is on.
- Real-account acceptance is tracked in [cloud-sync-acceptance.md](cloud-sync-acceptance.md).

## When things go wrong mid-transfer

- **Connection lost, Mac asleep, app quit or crashed:** the reserved remote ID and the resumable session
  survive, so the next pass continues from the last byte the service stored (Drive, Dropbox, OneDrive,
  S3). A response lost after the service already committed the file is detected by checking the file
  before uploading again, so nothing is uploaded twice. WebDAV has no sessions and restarts the file.
- **Network problems are never a meeting's fault:** offline, timeouts, HTTP 408, 5xx, quota, rate limits
  and redirects (a Wi-Fi login page) stop the pass without a retry delay on any meeting. It resumes when
  the network comes back (NWPathMonitor) or at the next minute tick.
- **Stopping is not failing:** "Interrompi", turning sync off, a recording starting or switching to a
  metered network cancel the transfer in flight. URLSession reports that as `URLError.cancelled`, which
  is treated as a stop: no error on the row, no retry delay.
- **Automatic passes pause** during a recording (the call keeps its upload bandwidth) and on metered or
  Low Data networks. "Sincronizza ora" still runs.
- **Low disk space:** encoding audio needs a second copy; when free space would drop below 2 GB the pass
  stops with a message instead of taking the room a recording needs.
- **Two copies of the app on one Mac** (installed and a test build) share `~/Meetings` and the map: a
  `flock` on `~/Library/Application Support/Overheard/cloud.lock` lets only the first one sync.
- **Interrupted Move or purge:** removals are written to the map file by file, so the map always says
  exactly which copies are still on the old service; the next run finishes the job.
- **Interrupted updates in a row:** every version this Mac started uploading for a file is remembered
  (`pushed`) until one is recorded, so a remote copy left by any earlier interrupted attempt is
  recognised as ours instead of blocking the file as "changed in the cloud".
- **Expired or revoked access token:** a 401 marks the OAuth accounts for a forced refresh (reloading the
  Keychain first), so the next pass recovers by itself; only a refused refresh asks to reconnect.
- **Failed cleanup or transfer is not retried every minute:** an automatic cleanup that cannot verify
  waits 6 hours (Sync now retries at once); a failing transfer to another service backs off like a sync.
- **Leftovers of a crash** are removed: upload snapshots (`$TMPDIR/Overheard cloud`), half-made
  encodings in the audio cache, `.rebuild-*` staging in `~/Meetings`, `.overheard-upload-*` in a
  synced folder. Expired or forgotten upload sessions are aborted, so S3 stops billing their parts.

