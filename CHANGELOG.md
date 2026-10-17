# Changelog

All notable changes are listed here, newest first. Versions follow [Semantic Versioning](https://semver.org).

## 1.1.0 (unreleased)

- Animated GIFs of the screen. Record (⌘R, in the title bar) records until it is stopped, at most two minutes, and saves
  to the Desktop. Capture (⇧⌘R) saves the last minute, or the last part of it: the app keeps the latest seconds in
  memory all the time (5 seconds to 2 minutes, or none, in Settings), and a sheet with a slider, a picture of the
  first frame and the file's size chooses how many. Save to the Desktop, or Copy to paste into a chat or an email.
- GIFs show the screen exactly, one frame per sweep at the real time between sweeps, with the date and time ticking in
  a strip under the screen (each can be turned off), at twice the screen's size or its own. The app's own encoder
  keeps them small: only the rectangle that changed, unchanged pixels transparent or not whichever compresses better,
  the screen's own colours.
- Bands: a Band menu (title bar and menu bar) sets the analyzer's span to FM radio, airband, marine VHF, 2 m and 70 cm,
  433, 868 and 915 MHz, 2.4 and 5 GHz Wi-Fi, cellular, ADS-B or GPS in one click; Back to the span before; Save
  Current Span as a Band. Start and stop are set in the order that never makes the analyzer pass through a zero span
  (which would reset its sweep time). A tinySA Ultra on USB.
- Presenting: a red pointer (⌘L) that a call shows even when it doesn't show the cursor, a click making a ring; a pen
  (⌘D) whose strokes fade by themselves after a few seconds and stay on what they mark when the window changes size;
  Esc ends either. Window › Float on Top keeps the window above other apps'.
- Settings (⌘,): the seconds Capture keeps, the date, time and size of GIFs, saved bands, clicks as taps, how long pen
  strokes stay.
- No window tab items in the menus: the app has one window.
- A command line for scripts and AI agents: `tinysa-screen record`, `capture`, `screenshot`, `sweep` and `status`, with
  results as text or JSON; `record --start --stop` records a given band and puts the analyzer's span back. With the app open the app does the work, through a control socket other programs can use too, and
  its window says who is recording; without it, the command line works alone, sharing the analyzer the same way. A
  recording starts only from a live picture.
- Python: `ask()` asks the open app for recordings, captures, screenshots and its status; `example_record.py`.

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
