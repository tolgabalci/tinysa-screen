# How it works

tinySA Screen talks to the analyzer the way a terminal would: the tinySA is a USB serial device (CDC ACM), and its
firmware runs a text console, a command line ending in a carriage return, the reply, then the prompt `ch> `. Everything
here comes from that console; the firmware's source is at [erikkaashoek/tinySA](https://github.com/erikkaashoek/tinySA).

## Finding the analyzer

The app looks through the Mac's serial ports (IOKit) for one whose USB device calls itself "tinySA" (the Ultra models
say "tinySA4"), so it never opens another serial device, such as a NanoVNA, which shares the tinySA's USB vendor and
product IDs. It opens the port for itself alone (`TIOCEXCL`) and checks with `lsof` that no other program has it open.

## Connecting

```
refresh off        a live screen left on by a viewer that crashed would pour in between replies
(a blank line)     a clean prompt
version            "tinySA4_v1.4-252-g2b4aa51": an Ultra (480 × 320), firmware v1.4-252
info               the model on its first line: "tinySA ULTRA+ ZS406"
capture rle        the whole screen, once
refresh on         from now on, every region the analyzer draws
```

## The screen, whole: `capture` and `capture rle`

`capture` sends the screen raw: width × height pixels, row by row from the top left, each RGB565 in two bytes, high
byte first: 307,200 bytes on the Ultra (480 × 320 × 2).

`capture rle` (firmware v1.4-252 and later, Ultra models) sends it packed, in the RLE8 format of the NanoVNA-D firmware,
about 30 KB instead of 300:

| Bytes | |
| --- | --- |
| 8 | the header: `BM` (0x4D42, little-endian), the width and height (16 bits each, little-endian), 8 (bits a pixel), 1 (compressed) |
| 2 | the palette's size in bytes (little-endian) |
| 2 × colours | the palette, RGB565 each, high byte first |
| per row | the packed size (16 bits, little-endian), then the row's palette indices packed with PackBits |

PackBits: a count byte n, then n + 1 bytes as they are (n < 128), or one byte repeated 257 − n times (n > 128); 128 is
nothing. Older firmware, or a screen with more than 256 colours at once, answers `capture rle` with the raw screen
instead, so a reader tells the two apart by the header. Neither ends in a way you can find by looking for the prompt:
the prompt's four bytes can occur inside the picture. Read the reply by its length (raw: known at once; packed: once
the row sizes have come), then the prompt.

## The screen, live: `refresh on`

After `refresh on`, each time the analyzer draws a region of its screen it also sends it, as it draws it:

| Bytes | |
| --- | --- |
| 6 | `fill\r\n` (one colour) or `bulk\r\n` (pixels) |
| 8 | x, y, width, height: 16 bits each, little-endian |
| 2 or width × height × 2 | the colour (`fill`), or the pixels row by row (`bulk`); RGB565, high byte first |
| 4 | the prompt, `ch> ` |

A sweep sends the graph's 32 × 32 cells that changed, the text it redraws, and, with the waterfall on, each line of it
as the waterfall scrolls: about 150 KB a second with the small waterfall on. The analyzer keeps sweeping as usual.

Commands still work meanwhile: their echoes and replies come between regions. A region the analyzer was sending when a
command's echo went out can arrive with the echo inside it; the app checks that each region ends with the prompt and
skips one that doesn't (that part of the screen is redrawn soon enough). `refresh off` stops the stream.

The stream goes on while no one reads it, so a viewer must turn it off as it lets go of the analyzer: tinySA Screen
does when it quits, before it lends the analyzer, and on `kill`. Only a crash leaves it on, and the next connection
turns it off.

## Keeping the picture right

- **Skipped regions.** A region skipped because a command's echo landed inside it would leave that part of the copy
  stale until the analyzer happens to draw it again, which for a quiet corner may be never. When regions were skipped,
  the app takes one whole capture (live screen off, `capture rle`, on again), at most once a second and never in the
  middle of a tap.
- **A quiet stream.** The analyzer turns its live screen off by itself when the USB link sleeps (the Mac sleeping, say),
  and nothing turns it on again. After 3 seconds without a byte the app sends `refresh on`: it runs beside the sweep
  without cutting it short, turns the live screen on if it was off, and its echo shows the console still answers. No
  echo within 2 seconds, and the app connects to the analyzer again.
- **A tap in progress.** While a touch is down the analyzer waits for its release with its sweep stopped, and a capture
  wouldn't answer. The app sends the release before it lets go of the analyzer (a borrow, quitting), and a bare
  `release` when it connects, in case a program ended mid-tap; with no touch down it does nothing.

## Taps

`touch x y` presses the analyzer's touch screen at a pixel (0, 0 at the top left), again as the finger moves, and
`release x y` lifts it. The firmware handles them as touches on its own screen, menus included.

## Firmware without the live screen

If `refresh on` gets `refresh?` (an unknown command), the app falls back to one picture after each sweep:
`waitscan 1` (one sweep, then the analyzer pauses) and a capture, in turn. The analyzer's own screen shows PAUSED
between them, and sweeps on its own again (`resume`) when the app lets go.
