# Changelog

All notable changes are listed here, newest first. Versions follow [Semantic Versioning](https://semver.org).

## 1.4.0 (2026-11-27)

- Record starts before it's pressed, and Stop opens an editor. The app keeps the last minute of the screen in memory
  (Settings › Recording: 15 seconds to 5 minutes, or nothing), and a recording's GIF starts 5 seconds before Record was
  pressed (Settings: from when it's pressed, as far back as what's kept goes); the button shows the GIF's length so
  far. Stop opens the editor: the whole recording on a filmstrip, with the GIF between two yellow handles to trim it or
  to take in more of the seconds kept from before Record (dimmed, Record marked above them). The picture shows the
  frame at the playhead as the GIF will, date and time included, and follows a handle while it's dragged (⌥ for finer
  steps); Play loops the GIF. The keys are QuickTime Player's: Space, ← and → a frame (⇧ a second), ⌥← and ⌥→ to the
  GIF's start and end, I and O to set them at the playhead, and ⌘Z. Then Save (Return) or Copy (⌘C), with the date,
  time and size chosen and the file's size shown; Cancel asks before it deletes the recording.
- With ⌥ held, Stop is Stop & Save (⌥⌘R): the GIF is saved as it is, without the editor. Quitting saves a recording
  running, or the GIF in the editor, as it is.
- Capture (⇧⌘R) is gone: Record does what it did, and from further back if wanted. The command line's `capture` stays.
- A recording runs two minutes at most after Record, as before, or up to five (Settings › Recording), so a GIF can be up
  to ten minutes long; at the limit it stops and opens the editor. The command line's `record` takes up to 300 seconds.
- A quick click on the analyzer's screen, and the window's Escape, are noticed now: the analyzer sees a touch only
  when it next looks, up to a few tenths of a second with its screen shown live, and lost one released before then. On
  firmware v1.4-333, taps typed back to back, as Escape typed them, were noticed 0 times in 6. Each touch is now held at
  least 0.4 s before its release, over USB and through a feeding program alike (22 of 24 noticed), still short of a
  long press (0.5 s), and the next touch goes down 0.1 s after a release at least, so two quick clicks stay two clicks.
  The Python helpers' `Feeder.pass_taps` keeps the clicks as far apart as the app dates them.
- After Record makes a GIF, a "Last recording" link appears right of it, and opens that GIF to watch: in the app the
  Mac opens GIFs with, or in the browser when that app would show it still (Preview, the Mac's own choice for GIFs, and
  image editors such as Pixelmator, Photoshop or GIMP) or none does.

## 1.3.3 (2026-11-27)

- The peak hold no longer takes the analyzer's marker readout ("1: 166.4MHz -55.4dBm", written in the trace's yellow
  at the top of the graph) for the trace: with a marker on, it showed bogus peaks at the top of the graph's left side,
  all at the top level. Now it holds only the trace, which can still reach up into the readout's rows.
- Nor does it take a marker's symbol, the numbered flag the analyzer draws in the same yellow just above the marker's
  point, for the trace. With the marker on a peak, the hold held that peak a flag's height too high (about 4 dB at
  10 dB a division, more with the waterfall on), and a marker away from a peak made a peak of its own. The trace now
  counts from its highest pixel above or below the flag.
- The peak hold's frequencies and levels show on macOS 27 too, for spans where they didn't: its text recognition
  reads some of the levels at the graph's right upside down ("09-" for "−60"), a zero as "Ö", or a point as a comma,
  and those readings are now taken for what they are.
- `tinysa-screen peaks` gives frequencies and levels after a macOS update too. The first time tinySA Screen reads the
  screen's labels on a new macOS version, the Mac's text recognition prepares itself for it, which takes most of a
  minute (42 s on an M2, minutes on a busy Mac). `peaks` gave up on the labels 10 s after its seconds and quit before
  that was done, so every short run started it over and answered without frequencies or levels. Now it waits for a
  reading under way, up to 90 s after its seconds (its notes say when that took longer), and reads the labels once
  more from the latest picture when the last reading failed.

## 1.3.2 (2026-10-27)

- The window's title has the app's version, "tinySA Screen v1.3.2", which the app reads from its own Info.plist (the
  build writes the repository's VERSION there), and the subtitle under it is the app's tagline, "The big screen your
  tinySA deserves". While another program records the screen, the subtitle says which. The analyzer and its firmware,
  or the program feeding the pictures, which the subtitle showed before, are in `tinysa-screen status` and in each
  GIF's comment.

## 1.3.1 (2026-10-27)

- While the analyzer's keypad is open, the window no longer says "No new picture from …" over a feeder's pictures. The
  analyzer doesn't sweep while its keypad is open and draws nothing until a key is pressed, so no new picture comes,
  but the last one is still what it shows; the note also covered part of the line under the keys. The time spent on
  the keypad no longer counts toward the feeder's usual pace either, which made a real pause after it take longer to
  show.

## 1.3.0 (2026-10-27)

- Escape takes the tinySA back to its main screen, with its own touches: a number being typed is cancelled with the
  keypad's erase key (nothing changes), and a menu is closed with a tap on the graph beside it, one touch at a time,
  each once the screen shows what the last one did (View › Back to the tinySA's Main Screen). With the pointer or the
  pen on, Escape ends it, as before.
- While the analyzer's keypad is open it doesn't sweep, and a command waiting for a sweep held its console until the
  keypad closed on the analyzer itself. tinySA Screen now reads what the analyzer's screen shows and sends none then:
  a band waits, and on firmware without the live screen the picture comes every half second. docs/INTEGRATION.md tells
  feeders the same (Clicks as taps).

## 1.2.0 (2026-10-27)

- Clicks reach the tinySA while a program feeds the pictures too, when it says it passes them on: tinySA Screen writes
  each click to `taps` in the feed folder, and the program types it on the analyzer as a tap (docs/INTEGRATION.md,
  Clicks as taps). Before, clicks did nothing while a feeder had the analyzer. A small ring shows where a click went
  until the feeder's next picture shows the analyzer's answer, and a click that can't reach the analyzer says why for a
  moment. The Python helpers pass taps on (`Feeder(name, taps=True)`, `pass_taps`, and `LiveScreen.picture`'s
  `between`), and so does example_feeder.py.
- A right-click (a two-finger click, or Control-click) is a long press on the analyzer's screen: its touch stays down
  at least 0.6 s, and the analyzer takes half a second as a long press (on its keypad the erase key clears the whole
  entry; a value in a form menu slides while held). Holding the button down does the same.

## 1.1.2 (2026-10-19)

- GIFs show rightly where a site shrinks them image by image. Posted to groups.io, a GIF's frames piled up on each
  other: it fits each image of a GIF to its width, so an image narrower than the GIF came out larger than the rest and
  out of place, and the old screen showing through its transparent pixels stayed. Each image is now the rows that
  changed, across the whole width, every pixel in its own colour, which makes GIFs a fifth to a half larger.

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
  labels that couldn't be read once weren't tried again, and a level read without its minus sign ("30" for "−30"),
  or with it taken for a letter where a trace crosses it ("H20", as macOS 15 reads it), spoiled the fit; and a change
  of the reference level went unseen.
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
