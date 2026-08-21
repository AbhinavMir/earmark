# Earmark

A macOS native audiobook player for an Audible library.

Earmark is a native application. Nothing runs in a browser, and nothing stops
when you quit one.

## What it does

- Signs in once through Amazon's own page. Earmark never sees the password.
- Lists the library, with search across title, author, narrator, and series.
- Downloads titles, two at a time, and writes them to `~/Audiobooks` as M4B
  files with chapters and cover art. Any other player can open them.
- Plays with chapter navigation, speed from 0.75× to 3×, and a sleep timer.
- Answers the media keys, the Now Playing panel, and AirPods controls.
- Reads and writes the position Audible keeps, so a session started on the
  phone continues on the Mac and the other way round.
- Keeps local bookmarks with notes.

## Install

Download the latest release, or build it yourself. The application is signed
and notarised, so it opens without a warning.

## Requirements

- macOS 14 or later
- `ffmpeg`: `brew install ffmpeg`
- An Audible account with titles in it

## Build

```
git clone https://github.com/AbhinavMir/earmark
cd earmark && ./build-app.sh
open build/Earmark.app
```

`AudibleKit` is fetched as a package, so this repository builds on its own.
To work on both at once, check the package out beside it:

```
git clone https://github.com/AbhinavMir/audible-kit ../audible-kit
swift package edit AudibleKit --path ../audible-kit
```

The build signs with a Developer ID when the machine has one, and falls back
to an ad-hoc signature. An ad-hoc signature changes with every build, so macOS
asks again for anything it guards.

## How it holds your data

- Credentials live in the macOS Keychain as one item.
- Library state, positions, and bookmarks live in one JSON file under
  `~/Library/Application Support/Earmark`.
- Audio lives in `~/Audiobooks`, outside the application, so removing Earmark
  never removes your books.

## Position conflicts

The later recording wins, and only when the two sides differ by more than a
minute. A desktop session left open for days cannot rewind your phone. When a
remote position does move the player, Earmark says so and offers an undo.

## Scope

Earmark plays the titles your own Audible account owns, on your own Mac. It
cannot reach anything your account does not already hold.

The files it writes are yours to listen to. They are not yours to hand out.

## Status

Registration, library, downloads, playback, bookmarks, and position reads work
and are covered by tests. Writing positions back to Audible uses an endpoint
that still needs confirmation against a live account.

## License

MIT. See `LICENSE`.
