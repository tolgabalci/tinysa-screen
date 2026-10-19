# Contributing

Thanks for helping. tinySA Screen is small on purpose: a window with the analyzer's screen, and a simple way for
other programs to share the analyzer. Changes that keep it that way are the easiest to take.

## Reporting a problem

[Open an issue](https://github.com/tolgabalci/tinysa-screen/issues/new/choose) with:

- your tinySA model and firmware (the window's title shows both, or `version` on the console),
- your macOS version and Mac (Apple silicon or Intel),
- what you did, what you expected, and what happened; a screenshot (⌘S) helps.

Reports that it works, or doesn't, with a tinySA model or firmware version we haven't tried are very welcome.

## Building and testing

You need Xcode, or its command line tools (`xcode-select --install`), on macOS 13 or later.

```bash
swift build                 # a debug build
swift test                  # the tests: the screen formats, the live stream, the files other programs use
swift run tinysa-screen     # run it from the terminal (without its icon)
scripts/build-app.sh        # build/tinySA Screen.app, universal, signed ad hoc
scripts/install.sh          # the same, put in ~/Applications
```

`Package.swift` opens in Xcode too.

The tests run on recordings from a tinySA Ultra+ (`Tests/TinySAKitTests/Fixtures`), so they need no analyzer. Changes
to how the app talks to the analyzer should also be tried on one; say in the pull request which model and firmware.

## Layout

- `Sources/TinySAKit`: everything about the tinySA. `DeviceFinder`, `SerialPort`: finding and opening it (and a
  NanoVNA). `Capture`: whole-screen captures. `ScreenStream`: the live screen. `Framebuffer`, `Snapshot`: the copy of
  the screen. `Integration`: borrowing and feeding. `Session`: the thread that ties these together. `FrameRecorder`
  and `GIF/`: recordings and the GIF encoder. `Band`: spans. `Graph`, `PeakHold`: the peak hold, read from the screen.
  `Control`, `Automation`: the control socket and what other programs can ask.
- `Sources/TinySAScreen`: the Mac app: the window, the view (`ScreenView`), the menus, the toolbar's controllers
  (`GIFController`, `BandController`, `PeakOverlay`), Settings, and the command line (`CommandLineTool`).
- `integrations/python`: helpers for other programs.
- `packaging/homebrew`: the Homebrew cask, as the tap starts from.
- `docs`: how it works, how to work with it, the command line, and the README's pictures.

## Pull requests

- One change per pull request, with a line in `CHANGELOG.md` under a heading for the next version.
- `swift test` passes, and the app builds (`scripts/build-app.sh`).
- Match the code around you: Swift's standard style, two spaces, lines up to 120 characters, a doc comment on what
  isn't obvious.
- New behavior in the app goes in the README; new formats or commands in `docs/HOW-IT-WORKS.md`; changes to the files
  other programs use in `docs/INTEGRATION.md`, kept compatible (other programs rely on them).

## Releasing (maintainers)

1. Set `VERSION`, date the version's heading in `CHANGELOG.md`, commit, push, and see the CI pass.
2. Push a tag `v<VERSION>`: the Release workflow tests, builds the app (signed ad hoc) and publishes the release with
   the changelog's section as its notes.
3. On a Mac with a "Developer ID Application" certificate and an App Store Connect API key
   (`~/.config/tinysa-screen/notary.env`: `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `NOTARY_KEY`), run
   `scripts/release.sh`: it builds the same version signed with the Developer ID and the hardened runtime, has Apple
   notarize it, staples the ticket, replaces the release's zip with it, and updates the Homebrew cask in
   [tolgabalci/homebrew-tap](https://github.com/tolgabalci/homebrew-tap) (creating the tap the first time). Apple
   usually answers in minutes, sometimes in over an hour; if the wait is cut off, `NOTARY_SUBMISSION=<id>
   scripts/release.sh` carries on with the submission it printed.

By contributing you agree that your work is released under the [MIT License](LICENSE), and to follow the
[code of conduct](CODE_OF_CONDUCT.md).
