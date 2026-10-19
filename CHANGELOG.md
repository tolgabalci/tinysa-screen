# Changelog

All notable changes are listed here, newest first. Versions follow [Semantic Versioning](https://semver.org).

## 1.1.1 (2026-10-19)

- Peak hold: View › Hold Peaks For sets how long it keeps each level (10 or 30 seconds, a minute, 5 minutes, or until
  cleared); a minute by default now, as a monitoring hold keeps the last minute. Its line is cyan by default (it was
  magenta, one of the analyzer's own trace colours, as green, red and yellow are), and Settings › Peak hold › Color
  chooses another. Its peaks keep their numbers while they're held, as an analyzer's markers stay on their peaks (a
  peak moved a few columns is the same one, a new peak takes the lowest number free), and the box lists them by number;
  before, they were renumbered by height after every sweep.
- Peak hold, fixed: a band chosen (or other levels) starts the hold over from the first sweep on it, and the old
  span's levels never show over the new one meanwhile (they could, until its labels were read, and its first seconds
  were then lost); a menu over the labels for a while still keeps what was held. Its readouts came back slowly or not
  at all on busy bands: the dots of a waterfall at its strongest touched the labels' fingerprint (2.4 GHz Wi-Fi, say),
  labels that couldn't be read once weren't tried again, and a level read without its minus sign ("30" for "−30")
  spoiled the fit; and a change of the reference level went unseen.
- Where files go: Settings › Saving › Save to chooses the folder GIFs and screenshots are saved in (the Desktop until
  then), with Show in Finder; the menu and buttons name it. A folder that's moved or renamed is followed; while it
  can't be found or written to, a file goes to the Desktop and the window says so.
- A feeding program's pictures are looked for ten times a second instead of four: they show sooner, and pictures put
  a tenth of a second apart or more are each a frame in a GIF (one replaced sooner than that may not be seen).
- Feeding a picture of every sweep: the Python helpers' `LiveScreen` keeps a copy of the analyzer's screen from its
  live screen while it sweeps on its own, with commands typed only between sweeps, and `example_feeder.py` uses it (a
  picture every 0.8 s on a tinySA Ultra, where a capture after each sweep made one every 1.1 s or more). It leaves
  the analyzer sweeping when it ends, without `resume`, which starts the analyzer's max holds over: `sweep_on` uses
  the top menu's PAUSE instead. `Feeder.picture` takes the time the screen was drawn, which the app and its GIFs use.
  The helpers have tests, run by CI.
- [INTEGRATION.md](docs/INTEGRATION.md) says how a feeder gets a picture of every sweep, and keeps the analyzer's
  traces.

## 1.1.0 (2026-10-17)

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
- Peak hold (⌥⌘P): the highest level of the live trace held as a magenta line over the picture, its highest peaks
  numbered with their frequency and level in a box that finds an empty spot. Read from the screen after each sweep
  (the labels with the Mac's text recognition), so the analyzer's settings are left alone and fed pictures work too;
  on a test sweep it read 902.23 MHz, −23 dBm where the analyzer's marker said 902.231 MHz, −23.2 dBm. Clear Peak Hold
  (⌥⌘⌫); Settings: hold for 10 s to 5 min or until cleared, up to 9 peaks.
- Settings (⌘,): the seconds Capture keeps, the date, time and size of GIFs, saved bands, clicks as taps, how long pen
  strokes stay, the peak hold.
- NanoVNA (experimental): a NanoVNA-H or -H4 shows live with DiSlord's NanoVNA-D firmware (the same console and live
  screen as the tinySA's, regions ending with a new line), or a picture every half second with older firmware; clicks,
  screenshots, GIFs and the presenter's tools work. Built from NanoVNA-D's source, not yet tried on a NanoVNA.
- No window tab items in the menus: the app has one window; closing it quits the app. Edit has Undo, Cut, Paste and
  Select All for text fields.
- A GIF never shows a picture that stopped coming as if it were live: Record starts only from a live picture, a
  recording or capture ends where the picture stopped, and a fed picture left on the disk by an earlier run isn't
  recorded. Screenshots are named after when their picture came. Quitting while recording saves the GIF first.
- Fixed from 1.0.0: a touch held while the app polls an analyzer without the live screen no longer stalls it, and the
  live screen is paused cleanly (up to the prompt) before a whole capture.
- A command line for scripts and AI agents: `tinysa-screen record`, `capture`, `screenshot`, `sweep` and `status`, with
  results as text or JSON; `record --start --stop` records a given band and puts the analyzer's span back; `peaks`
  lists the highest peaks over some seconds, read from the screen. With the app open the app does the work, through a control socket other programs can use too, and
  its window says who is recording; without it, the command line works alone, sharing the analyzer the same way. A
  recording starts only from a live picture.
- Python: `ask()` asks the open app for recordings, captures, screenshots and its status; `example_record.py`.
- Signed with a Developer ID and notarized by Apple: the download opens like any app. Homebrew:
  `brew install --cask tolgabalci/tap/tinysa-screen`, which also puts `tinysa-screen` on the `PATH`.

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
