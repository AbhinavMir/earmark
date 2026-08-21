<img src="icon.png" width="120" alt="Earmarky">

# Earmarky

A macOS native audiobook player for an Audible library.

Earmarky is a native application. Nothing runs in a browser, and nothing stops
when you quit one.

## What it does

- Signs in once through Amazon's own page. Earmarky never sees the password.
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
open build/Earmarky.app
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
  `~/Library/Application Support/Earmarky`.
- Audio lives in `~/Audiobooks`, outside the application, so removing Earmarky
  never removes your books.

## Position conflicts

The later recording wins, and only when the two sides differ by more than a
minute. A desktop session left open for days cannot rewind your phone. When a
remote position does move the player, Earmarky says so and offers an undo.

## Scope

Earmarky plays the titles your own Audible account owns, on your own Mac. It
cannot reach anything your account does not already hold.

The files it writes are yours to listen to. They are not yours to hand out.

## Updates

Earmarky asks the releases page what exists and compares those versions with
its own. There is no update server, and nothing is sent about what is
installed: a download address is worked out from a version rather than read
from a list, so there is nothing to keep in step.

The numbers carry the meaning. The first moves when the shape of the
application changes, the middle for a finished release, and the last for a
night's work. So 1.3.0 is finished and 1.3.1 is the day's. The channel is
decided by the version and never by whether a release is marked as a
prerelease: a finished release marked that way while it is tried out still
reaches everybody.

Looking is off by default, and installing without asking is off as well.
Nothing is requested while looking is off. Check Now works whether or not it
is on, because asking once by hand is not the same as agreeing to be asked
every day.

Installing fetches the disk image, checks every byte arrived, mounts it, and
checks the application inside is this application, signed by this developer,
under a certificate Apple issued. That check is a refusal: a download that
fails it is deleted and nothing is replaced. What passes is copied beside the
installed application and only then exchanged with it, so an install that
fails leaves a working application rather than none. An install nobody asked
for that goes wrong says so and offers itself by hand.

Separately there is a list of faulty builds, read from this site on launch.
That one is on by default, because a withdrawn build can lose data and a
warning nobody switched on warns nobody. A build named as critical says so on
every launch; one named as serious can be set aside against that exact
version. The list is the same for everybody and the matching happens here.

## Status

Registration, library, downloads, playback, bookmarks, and position reads work
and are covered by tests. Writing positions back to Audible uses an endpoint
that still needs confirmation against a live account.

## License

MIT. See `LICENSE`.
