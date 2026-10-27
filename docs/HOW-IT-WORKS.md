# How it works

tinySA Screen talks to the analyzer the way a terminal would: the tinySA is a USB serial device (CDC ACM), and its
firmware runs a text console, a command line ending in a carriage return, the reply, then the prompt `ch> `. Everything
here comes from that console; the firmware's source is at [erikkaashoek/tinySA](https://github.com/erikkaashoek/tinySA).

## Finding the analyzer

The app looks through the Mac's serial ports (IOKit) for one whose USB device calls itself "tinySA" (the Ultra models
say "tinySA4"), or "NanoVNA-H4", "NanoVNA-H" or "NanoVNA", so it never opens another serial device: the NanoVNAs share
the tinySA's USB vendor and product IDs, and a NanoVNA V2, which speaks binary, calls itself otherwise. A tinySA comes
first when both are there. It opens the port for itself alone (`TIOCEXCL`) and checks with `lsof` that no other program
has it open.

### NanoVNA

A NanoVNA's console is the tinySA's ancestor: the same prompt, `capture`, and with DiSlord's NanoVNA-D firmware `capture
rle`, `refresh on`, `touch` and `release`. The differences the app knows: `version` says only the version ("1.2.52")
and `info` the board on its first line ("Board: NanoVNA-H 4"); the screen's size comes from the USB name (480 × 320
for the -H4, 320 × 240 for the others); each region of the live screen ends with the prompt and a new line
(`ch> \r\n`), the new line being text between regions; and without the live screen there is no `waitscan`, so the
app captures every half second, leaving the sweep alone.

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
`release x y` lifts it. The firmware handles them as touches on its own screen, menus included, and times them as it
does a finger: a touch held half a second (its `BUTTON_DOWN_LONG_TICKS`) is a long press, which on the keypad's erase
key clears the whole entry and on a value in a form menu turns it into a slider. The mouse is the finger: the button
down is a touch, each move while it is down (at most 25 a second) another, and the button up the release. A right-click
holds its touch at least 0.6 s, a long press without holding the button.

While a feeding program has the analyzer, the app writes the same commands to `taps` in the feed folder, each with the
time it was clicked, and the program types them (docs/INTEGRATION.md, Clicks as taps); it keeps each touch down as long
as it was clicked, so a long press stays one when it reads a touch and its release together.

**Where a tap lands** (the tinySA Ultra's firmware, `ui_process_touch`). Over a menu a tap picks the item under it, and
a tap beside a menu closes it (a form menu ignores it). With no menu open the firmware tries, in this order: the SD card
icon on the left, which saves a screenshot to the card when the analyzer is set to; the labels down the left edge
(x under 30), each opening its quick menu or keypad (the Scan label opens SPEED); a marker near the tap, picked up to
drag; the line along the bottom (y over 300), whose left part gives the jog wheel to START and right part to STOP, a
second tap there opening its keypad, while its middle (x from 310 to 410) switches between START/STOP and CENTER/SPAN;
and the strip along the top (y under 25), which gives the jog wheel to the markers. Anywhere else opens the menu where
it was last left: after a quick menu, a tap on the graph opens that quick menu again, not the top menu.

**The keypad.** A number is typed on a keypad that covers the analyzer's screen, and the firmware runs it as a loop of
its own (`ui_process_keypad`): no sweep until it closes. `waitscan`, which waits on the console's own thread for a
sweep to end, then holds the console until the keypad closes (or the jog wheel moves), and a command the sweep runs
(`sweep`, `menu`, `pause`, `data`) gives up after 20 s (four waits of 5 s) with "Command timeout" and no prompt.
Firmware v1.4-255 (2026-10-23) keeps the keypad as it was. The app reads what the screen shows (`ScreenState`: the
graph, a menu, the number keypad, another keypad) from its pixels, and sends no such command while a keypad is open: a
band waits, and older firmware's picture after each sweep becomes a picture every half second. Nothing is drawn until
a key is pressed, so a feeder's picture of the keypad stays live however old it gets, with no "No new picture" note.

**Escape** takes the analyzer back to its graph with the analyzer's own touches, one at a time: on the number keypad
its erase key (`touch 300 252`; a character a press, then, with nothing typed, the keypad, nothing changed), on a menu
a tap on the graph beside it (the firmware closes a menu on a touch outside it). Each waits until the part of the
screen it touched has changed, as through a feeder the next picture may still be a sweep from before the touch was
typed, and it stops at the graph, after 24 touches or after 15 s. A form menu, which ignores a touch outside it, and a
keypad for a name are left to the analyzer's own keys.

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
between them, and sweeps on its own again (`resume`) when the app lets go. `resume` also starts the analyzer's max
holds over (it recomputes the sweep's frequencies); newer firmware, with the live screen, never needs it.

## GIFs

### One frame a sweep

The analyzer draws each sweep in a burst of regions a few milliseconds apart (about 140 regions in a quarter of a
second on a tinySA Ultra with the small waterfall), then sends nothing while it measures the next sweep (about half a
second at its usual speed). The app takes a frame of its copy of the screen once the regions pause for 100 ms, so each
frame is a whole sweep, never one half redrawn. A big waterfall makes the analyzer pause for some tens of milliseconds
inside a burst while it scrolls, which the 100 ms rides over. When the regions never pause, with very fast sweeps, a
frame is taken every half second. Each picture a feeding program writes is a frame, at the time the file is dated
(the app looks for one ten times a second, so a picture replaced sooner than that may not be seen), and so is each
capture when the firmware has no live screen. A frame the same as the one before isn't kept twice.

### Keeping the last minute

Frames are kept in memory packed with LZFSE, a few tens of kilobytes each. A recording keeps them from its start, and
Capture keeps the last minute (or what Settings says), each from the screen as it was when it began. Nothing goes to
the disk until a GIF is saved.

### The file

- **Colours**: the GIF's colour table holds the screen's own colours in the order they first appear, so nothing is
  dithered. A tinySA's screen uses well under the 256 a GIF holds, waterfall included; a colour beyond those (only a
  feeding program's pictures could have one) takes the nearest.
- **Only what changed**: after the first, each image is the rows that changed since the frame before, from the first
  to the last, across the whole width, drawn over it (disposal: keep), every pixel in its own colour. The smallest
  rectangle around the change with its unchanged pixels transparent, as GIFs were made before 1.1.2, is a fifth to a
  half smaller, but a site that shrinks a GIF image by image, fitting each to a width (groups.io does, as ImageMagick
  does resizing to a width without `-coalesce`), scales an image narrower than the GIF more than the rest and puts it
  out of place, and what shows through its transparent pixels piles up frame after frame. Images as wide as the GIF,
  with nothing transparent, come out right.
- **Compression**: GIF's LZW, with codes from one bit more than the colours need up to 12 bits, and a fresh table when
  it fills. Each image's code size is just enough for the colours it uses.
- **Timing**: each image stays up until the next, in hundredths of a second, rounded from the real times so the GIF
  lasts as long as the recording. Moments closer than 30 ms are shown as one, since browsers slow down images shorter
  than 20 ms.
- **The date and time**: a strip under the screen, the text drawn with the Mac's system font in eight greys, white on
  black like the analyzer's. Each second the time ticks over adds an image of the strip's rows that changed, half a
  kilobyte at the screen's size and one and a half at twice that, so the clock runs on while the screen keeps still.
- **A comment** in the file says where the picture came from and when.

Measured on 48 seconds of a tinySA Ultra watching the busy 915 MHz band with its big waterfall on, 63 frames, the date
and time under the screen: 2.0 MB at the screen's own size and 5.0 MB at twice that, the waterfall being most of it (it
changes all over every sweep). The same frames with the waterfall's rows blanked take 178 KB and 442 KB. The smallest
rectangles with transparent pixels took 1.7 MB and 4.3 MB, and 121 KB and 303 KB: whole rows cost a fifth more with the
waterfall and a half more without, the clock's ticks being most of that. Making either GIF takes a quarter of a second
at most.
