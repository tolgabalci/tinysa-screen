# tinySA Screen

[![Build](https://github.com/tolgabalci/tinysa-screen/actions/workflows/ci.yml/badge.svg)](https://github.com/tolgabalci/tinysa-screen/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/tolgabalci/tinysa-screen)](https://github.com/tolgabalci/tinysa-screen/releases/latest)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

The screen of your [tinySA](https://tinysa.org) spectrum analyzer, live in a window on your Mac. Share that window in
Teams, Zoom or Meet and everyone sees the band as you do. Click the picture and the analyzer takes it as a tap on its
own screen.

![tinySA Screen on a Mac, showing a tinySA Ultra+ with a UHF RFID reader hopping across 902–928 MHz](docs/images/window-live.jpg)

_tinySA Screen with a tinySA Ultra+ watching a UHF RFID reader hop across the 902–928 MHz band: the green line holds
the channels it used, four markers read them out, and each hop is a dash in the waterfall._

## Why

The tinySA is a small, capable spectrum analyzer with a 4-inch screen. Pointing a webcam at it during a call doesn't
show much. tinySA Screen puts its screen in a Mac window, pixel for pixel, as it changes:

- **Live**: the analyzer keeps sweeping as usual and sends what it draws over USB as it draws it, so the window shows
  each sweep, the markers, menus and the waterfall a moment after the analyzer does.
- **Sharp at any size**: twice the analyzer's size to start with, larger or full screen if you like, its pixels kept
  sharp.
- **Control from the Mac**: a click on the picture is a tap on the analyzer's screen, to open its menus, change the
  span or move a marker while you talk.
- **Screenshots**: ⌘S saves the screen to the Desktop, ⌘C copies it.
- **Works alongside your own programs**: a script that needs the analyzer borrows it and gives it back, and a program
  that keeps the analyzer all day can feed its pictures to the window instead ([Working with other programs](#working-with-other-programs)).

![The tinySA's screen in tinySA Screen, live: the reader hopping, sweep after sweep](docs/images/live-915mhz.gif)

_Live: each sweep (yellow) as it comes, the green line holding the recent maximum, the waterfall filling with hops._

## What it looks like

| | |
| --- | --- |
| ![902–928 MHz with a reader hopping](docs/images/screen-915mhz-reader.png) | ![2.4 GHz with Wi-Fi](docs/images/screen-2400mhz-wifi.png) |
| **902–928 MHz**: a UHF RFID reader hops among 50 channels; the green line holds where it went, with markers on four channels. | **2.4 GHz**: a Wi-Fi channel's 20 MHz hump at 2.44 GHz, its bursts in the waterfall, and a narrow signal at 2.48 GHz. |
| ![The cellular 850 MHz downlink](docs/images/screen-850mhz-cellular.png) | ![700 to 1000 MHz](docs/images/screen-700-1000mhz.png) |
| **869–894 MHz**: the cellular downlink, LTE carriers as wide plateaus. | **700–1000 MHz**: cellular bands at 700 and 850 MHz, and a strong burst in the 915 MHz band. |

All of these were taken with a tinySA Ultra+ (ZS406) on firmware v1.4-252, through a 20 dB attenuator and a 915 MHz
antenna.

## What you need

- A Mac with macOS 13 Ventura or later (Apple silicon or Intel).
- A tinySA connected by USB. Made and tested with a **tinySA Ultra+ (ZS406)**; the other tinySA Ultra models share its
  firmware and should work the same. The original tinySA (320 × 240 screen) should work too, but hasn't been tried:
  [tell us](https://github.com/tolgabalci/tinysa-screen/issues) how it goes.
- Recent firmware. The live screen (`refresh on`) has been in the firmware since 2021; v1.4-252 (September 2026) or
  later also captures the whole screen quickly and fixes a console hang of earlier versions. Firmware without the live
  screen gets a picture after every sweep instead (not yet tried on such firmware). See
  [Updating the firmware](#updating-the-firmware).

## Install

**Download**: get `tinySA-Screen-<version>.zip` from the [latest release](https://github.com/tolgabalci/tinysa-screen/releases/latest),
unzip it and move **tinySA Screen** to your Applications folder. The app isn't signed with an Apple Developer ID, so the
first time, open it with right-click (or Control-click) › **Open**, then **Open** again; macOS remembers that. On recent
macOS versions you may need System Settings › Privacy & Security › **Open Anyway** instead.

**Or build it yourself** (Xcode or its command line tools):

```bash
git clone https://github.com/tolgabalci/tinysa-screen.git
cd tinysa-screen
scripts/install.sh
```

That builds the app and puts it in `~/Applications`, where Spotlight finds it.

## Use

1. Connect the tinySA by USB and switch it on.
2. Open **tinySA Screen**. It finds the analyzer by itself (by its USB name, so no other serial device is touched), and
   the window's title names it and its firmware: "tinySA Screen – tinySA ULTRA+ ZS406 · v1.4-252".
3. In a call, share the window: in Teams, **Share › Window › tinySA Screen**; in Zoom, **Share Screen** and pick the
   window; in Meet, **Present › A window**. The window keeps updating when it's behind the call's own window.

| Menu | Keys | What it does |
| --- | --- | --- |
| File › Save Screenshot to Desktop | ⌘S | The analyzer's screen at its own size, as a PNG named `tinySA <date> at <time>.png` |
| Edit › Copy Screenshot | ⌘C | The same, to paste anywhere |
| View › Actual Size, Double Size, Triple Size | ⌘1, ⌘2, ⌘3 | The window at one, two or three of the Mac's points per analyzer pixel |
| View › Control the tinySA by Clicking | ⌘K | Clicks become taps on the analyzer (on by default) |
| View › Enter Full Screen | ⌃⌘F | The picture as large as the screen allows |

A click on the picture is a tap on the analyzer's screen, even while the call's window is the active one: here the
analyzer's DISPLAY menu, opened from the Mac.

![The analyzer's DISPLAY menu, opened by a click in tinySA Screen](docs/images/window-menu.jpg)

When no live picture can come, a note over the picture says why: no tinySA on USB, another program using it, or the
analyzer lent to a program for a while.

Quit tinySA Screen before you unplug the analyzer or hand it to another program by hand: it turns the analyzer's live
screen off as it quits.

## Working with other programs

A tinySA's USB console takes one program at a time. tinySA Screen shares it in two ways, both a few lines in any
language; [docs/INTEGRATION.md](docs/INTEGRATION.md) has the details and Python helpers in
[integrations/python](integrations/python):

- **Borrowing.** A script that needs the analyzer for a while writes its process ID and name to `~/.tinysa-busy`.
  tinySA Screen lets go within about half a second, shows who has the analyzer, and takes it back when the file is
  gone.

  ```bash
  echo "$$ my-script" > ~/.tinysa-busy   # tinySA Screen lets go of the tinySA
  # ... use the tinySA ...
  rm ~/.tinysa-busy                      # and takes it back
  ```

  ![tinySA Screen while a script has borrowed the analyzer](docs/images/window-lent.jpg)

- **Feeding.** A program that keeps the analyzer itself (a monitor or logger running all day) can put the analyzer's
  screen in the window: while tinySA Screen is open it touches a file, and the program writes the screen as a PNG and
  a few words about what it is doing to a folder the app watches. While that program runs, tinySA Screen shows its
  pictures and never touches the analyzer.

## How it works

tinySA Screen speaks the analyzer's USB console, as a terminal would. When it connects it turns off any live screen a
crashed viewer may have left on, asks for the firmware version and the model, captures the whole screen (`capture rle`:
the screen packed into about 30 KB), then sends `refresh on`. From then on the analyzer sends every region it draws, as
it draws it, and the app paints the regions onto its copy of the screen. Clicks go back as `touch x y` and
`release x y`. [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) describes the formats.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| "Connect a tinySA by USB and switch it on." | Check the cable (a charging-only cable doesn't carry data) and the switch on the analyzer. |
| "The tinySA is in use by another program" | Quit that program (another viewer, a terminal, NanoVNA-Saver or QtTinySA), or make it [borrow](docs/INTEGRATION.md#borrowing) the analyzer. |
| "The tinySA doesn't answer over USB." | Switch the analyzer off and on. Firmware before v1.4-223 could leave its console unable to answer after hours of use; [update it](#updating-the-firmware). |
| The analyzer's own screen froze after tinySA Screen crashed | Open tinySA Screen again (it turns the analyzer's live screen off as it connects), or switch the analyzer off and on. |
| macOS says the app "can't be opened" | Right-click › Open the first time, or System Settings › Privacy & Security › Open Anyway. |

### Updating the firmware

The tinySA's maker publishes each firmware release in the [tinySA4 download folder](https://athome.kaashoek.com/tinySA4/DFU/)
(the Ultra models) with its changelog, and explains how to install it on the [tinySA wiki](https://tinysa.org/wiki/).
From v1.4-252 on the analyzer can also update itself from its SD card (STORAGE › MORE › UPDATE FIRMWARE).

## Contributing

Bug reports, ideas and pull requests are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md). Reports about tinySA models
and firmware versions this hasn't been tried with are especially useful.

## Acknowledgments

- The [tinySA](https://tinysa.org) is designed by Erik Kaashoek; its firmware ([on GitHub](https://github.com/erikkaashoek/tinySA))
  has the live screen and touch commands this app uses, made for the Windows app tinySA-App.
- `capture rle` sends the screen in the RLE8 format of DiSlord's NanoVNA-D firmware.

tinySA Screen is an independent project, not made or endorsed by the makers of the tinySA.

## License

[MIT](LICENSE) © 2026 Tolga Balci
