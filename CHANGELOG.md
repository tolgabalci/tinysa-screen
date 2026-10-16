# Changelog

All notable changes are listed here, newest first. Versions follow [Semantic Versioning](https://semver.org).

## 1.0.0 (2026-10-16)

The first release.

- The tinySA's screen, live in a Mac window: the firmware's live screen (`refresh on`), painted region by region as the
  analyzer draws it, after one capture of the whole screen (`capture rle`, or the raw screen on older firmware). On
  firmware without the live screen, a capture after every sweep.
- Clicks on the picture are taps on the analyzer's screen (`touch`, `release`); View › Control the tinySA by Clicking
  turns that off.
- Screenshots to the Desktop (⌘S) or the clipboard (⌘C); the window at one, two or three points per pixel (⌘1–⌘3) or
  full screen, its pixels sharp.
- Finds the tinySA by its USB name; says when there is none, another program has it, or it doesn't answer.
- Working with other programs: borrowing (`~/.tinysa-busy`) and feeding (`~/Library/Caches/tinySA Screen/`), with
  Python helpers and examples.
- Turns the analyzer's live screen off when it quits (also on `kill`), lends the analyzer or loses it, and turns off one
  left on by a crash when it connects. Releases a tap in progress before letting go of the analyzer, and on connecting.
- Keeps the picture right: a whole capture after regions were skipped, and a check of a stream gone quiet (the analyzer
  turns its live screen off when the Mac sleeps) that turns it on again without cutting a sweep short.
- A click on the picture taps the analyzer even while another window (a call's) is the active one.
- Keeps updating while the window is behind others (no App Nap), as when it's shared in a call.
- Universal: Apple silicon and Intel, macOS 13 Ventura or later.
