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

## Bands

A band is two commands, `sweep start <Hz>` and `sweep stop <Hz>`, sent with the live screen paused for a moment (`refresh
off`, the commands, a whole capture, `refresh on`), and `sweep` before and after to read the span. They go one at a time
in the order that keeps start below stop: the analyzer takes a start above the old stop as a zero span (start and stop
meet), and switching to a zero span resets its sweep time. The firmware's own two-number form, `sweep <start> <stop>`,
always sets start first, so it can do that when going up in frequency. `sweep` itself makes the analyzer cut its
current sweep short, so the app reads the span only when a band is chosen, never to keep the menu up to date.

## Peak hold

The peak hold reads the analyzer's screen, not the analyzer: `data`, which would give the trace's values, makes the
analyzer cut its sweep short, and a feeding program's pictures are all there is when it has the analyzer.

- **The graph**: the horizontal grid lines are the rows where much of the width is the grid's grey, dotted; the
  evenly spaced run of them is the graph's grid (24 rows a division with the small waterfall, 18 with the big one),
  and its left edge is the first column with a grid line down it.
- **The trace**: in each column of the graph, the highest pixel of trace 1's yellow, alone or where it's ORed with the
  grid or another trace (red and green full, blue not). One column a sweep point on a tinySA Ultra.
- **The labels**: the level labels at the graph's right and the span under it, enlarged eight times with square pixels
  and read with the Mac's text recognition (Vision). Look-alike letters are taken for what they look like ("$TART", a
  Cyrillic "М"), each level label belongs to the grid line at its top, and the labels that agree on one step a
  division win (a misread "30" for "−30" is outvoted). They are read again only when the white pixels around the
  graph change, and a span or levels that changed start the hold over.
- **Peaks**: a top of the held trace that stands at least 6 dB above the valleys on either side (before the next
  higher ground) and above the trace's median, its noise.

## Firmware without the live screen

If `refresh on` gets `refresh?` (an unknown command), the app falls back to one picture after each sweep:
`waitscan 1` (one sweep, then the analyzer pauses) and a capture, in turn. The analyzer's own screen shows PAUSED
between them, and sweeps on its own again (`resume`) when the app lets go.

## GIFs

### One frame a sweep

The analyzer draws each sweep in a burst of regions a few milliseconds apart (about 140 regions in a quarter of a
second on a tinySA Ultra with the small waterfall), then sends nothing while it measures the next sweep (about half a
second at its usual speed). The app takes a frame of its copy of the screen once the regions pause for 100 ms, so each
frame is a whole sweep, never one half redrawn. A big waterfall makes the analyzer pause for some tens of milliseconds
inside a burst while it scrolls, which the 100 ms rides over. When the regions never pause, with very fast sweeps, a
frame is taken every half second. Each picture a feeding program writes is a frame, and so is each capture when the
firmware has no live screen. A frame the same as the one before isn't kept twice.

### Keeping the last minute

Frames are kept in memory packed with LZFSE, a few tens of kilobytes each. A recording keeps them from its start, and
Capture keeps the last minute (or what Settings says), each from the screen as it was when it began. Nothing goes to
the disk until a GIF is saved.

### The file

- **Colours**: the GIF's colour table holds the screen's own colours in the order they first appear, so nothing is
  dithered. A tinySA's screen uses well under the 256 a GIF holds, waterfall included; a colour beyond those (only a
  feeding program's pictures could have one) takes the nearest.
- **Only what changed**: after the first, each image is the smallest rectangle around the pixels that changed since
  the frame before, drawn over it (disposal: keep). In that rectangle a pixel that didn't change can be transparent,
  showing the one beneath, or its own colour, and both look the same; the encoder chooses pixel by pixel whichever
  continues the run it is compressing. It also tries the rectangle with every pixel in its own colour, and keeps the
  smaller of the two.
- **Compression**: GIF's LZW, with codes from one bit more than the colours need up to 12 bits, and a fresh table when
  it fills. Each image's code size is just enough for the colours it uses.
- **Timing**: each image stays up until the next, in hundredths of a second, rounded from the real times so the GIF
  lasts as long as the recording. Moments closer than 30 ms are shown as one, since browsers slow down images shorter
  than 20 ms.
- **The date and time**: a strip under the screen, the text drawn with the Mac's system font in eight greys, white on
  black like the analyzer's. Each second the time ticks over adds an image of just the digits that changed, about a
  hundred bytes, so the clock runs on while the screen keeps still.
- **A comment** in the file says where the picture came from and when.

Measured on 39 seconds of a tinySA Ultra watching the busy 915 MHz band with its big waterfall on, 51 frames: 578 KB at
the screen's own size and 1.5 MB at twice that, the waterfall being most of it (it changes all over every sweep). The
same frames with the waterfall's rows blanked take 81 KB and 202 KB. Making either GIF takes a fifth of a second.
