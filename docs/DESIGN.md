# Earmark — Design

Date: 2026-08-19
Repo: `earmark`
License: MIT
Platform: macOS 14+, Swift 6.2, SwiftUI

## Purpose

Earmark is a macOS audiobook player for an Audible library. It downloads owned
titles, stores them as plain M4B files, plays them, and keeps the playback
position in step with the Audible mobile application.

Earmark is a native application. No browser is involved after the one-time
sign-in, and nothing stops when a browser quits.

## Dependencies

- `AudibleKit` — the Swift Audible client. Separate repository, MIT.
- `ffmpeg` — external process, used once per title to decrypt.

## Architecture

Three layers. Each layer depends only on the layer below it.

1. `AudibleKit` — protocol, network, decrypt.
2. `Library`, `Downloads`, `Playback`, `Sync` — application state. Observable
   model objects. No SwiftUI types.
3. SwiftUI views — render state, send intents. No business logic.

The application starts nothing until the model layer reports a registered
device, so an unregistered launch has one possible screen.

### Store

One SQLite database at `~/Library/Application Support/Earmark/library.db`,
through GRDB. Tables: `book`, `chapter`, `download`, `position`, `bookmark`.

The database holds metadata only. Audio lives at
`~/Audiobooks/<Author>/<Title>.m4b`, outside the container, so any other
player can open the files. The path is user-configurable.

## Screens

**Sign in.** A `WKWebView` showing the Amazon sign-in page. Earmark watches for
the redirect, hands the authorization code to `AudibleKit`, and registers the
device as "Earmark on <computer name>". Shown once.

**Library.** A cover grid with a sidebar: All, Downloaded, In Progress,
Finished, and one row per series. Search filters by title, author, narrator,
and series as the user types. Each cover shows a download state badge and a
progress ring for partially heard titles.

**Player.** Cover, title, narrator, chapter list, scrubber, speed control,
sleep timer, and skip controls. Chapter list marks the current chapter and
allows a jump.

**Downloads.** The queue with per-item progress, pause, resume, retry, and
cancel. Failures show the reason and a retry button rather than disappearing.

## Playback

`AVAudioPlayer` over the local M4B file. Chapters come from the file's own
chapter metadata, read with `AVAsset`.

- Speed: 0.5x to 3.0x in 0.05 steps, with pitch correction.
- Skip: 30 seconds forward, 15 seconds back, both configurable.
- Sleep timer: fixed durations, end of chapter, and a shake-to-extend
  equivalent bound to a keyboard shortcut.
- Media keys, the Now Playing panel, AirPods controls, and Control Center all
  work through `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`.
- Audio continues when the window closes. Closing the window does not quit the
  application while audio plays.

## Downloads

A queue with a concurrency limit of two, backed by a background `URLSession`.
Transfers survive application relaunch and resume after network loss.

Per item the state machine is: queued, licensing, downloading, decrypting,
verifying, done, or failed with a reason. State is persisted, so a crash during
decrypt resumes at decrypt rather than at the start.

Bulk selection in the library grid enqueues many titles at once.

## Position sync

Two-way, through `AudibleKit.PositionService`.

- On library refresh, pull positions for every title.
- During playback, push every 30 seconds, on pause, and on chapter change.
- On resume, pull first. When the remote position leads the local one by more
  than 60 seconds, Earmark adopts the remote position and shows an undo control
  for ten seconds.
- With no network, positions queue locally and flush on reconnect. The queue
  keeps only the newest position per title.

The conflict rule always favours the position that is further ahead in time of
writing, not further ahead in the book. A phone session that ended later wins.

## Bookmarks

Local bookmarks with an optional note, stored in SQLite and listed per title
and across the library. Audible bookmark sync is deferred: the endpoint needs
confirmation by capture, and local bookmarks have no dependency on it.

## Errors

Errors appear in the place that caused them, never as a modal alert. A failed
download shows on its queue row. A rejected license shows on the book. A
missing ffmpeg shows one banner with the install command.

## Testing

- Model layer against a stub `AudibleKit`, including sync conflicts, queue
  state transitions, and crash-resume.
- Playback engine against a short fixture M4B with known chapters.
- Views are not unit tested. Verification is by running the application.

## Build order

Each step ends with something observable.

1. `AudibleKit` registration and signing. Verified by a list of the library
   printed to the console.
2. License, download, decrypt. Verified by an M4B that plays in QuickTime.
3. Store and library screen. Verified by the grid showing the real library.
4. Player. Verified by playing a downloaded title with working media keys.
5. Download queue with bulk selection.
6. Position sync. Verified against the phone in both directions.
7. Bookmarks.

Steps 1 and 2 belong to the `audible-kit` repository. Steps 3 onward belong
here.

## Out of scope for v1

iOS or iPadOS, Audible Plus streaming, podcasts, purchases, statistics, and
any form of library sharing.
