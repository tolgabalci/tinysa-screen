# Working with other programs

A tinySA's USB console takes one program at a time: two programs sending commands at once would get each other's
replies. tinySA Screen keeps the console while its window is open, and gives other programs two ways in, both a few
lines of code in any language. The files involved are plain text and JSON in your home folder; nothing goes over the
network.

| | You want to | Your program |
| --- | --- | --- |
| [Borrowing](#borrowing) | use the analyzer for a while: a measurement, a script, another app | writes `~/.tinysa-busy`, uses the analyzer, removes the file |
| [Feeding](#feeding) | keep the analyzer in your program all the time, and still show its screen | writes pictures to `~/Library/Caches/tinySA Screen/` while the window is open |
| [Asking](#asking) | a GIF of the screen, the last seconds the app kept, a screenshot, what the app sees | runs `tinysa-screen record …`, or sends a line of JSON to the app's control socket |

Python helpers for all three are in [integrations/python](../integrations/python): `tinysa_screen.py` (standard library
only) and three examples that run as they are.

## Borrowing

A program that needs the analyzer writes one line to `~/.tinysa-busy`: its process ID, a space, and a name to show.

```
48211 sweep-logger.py
```

Within half a second (a second or two if it was just connecting) tinySA Screen releases any tap in progress, turns the
analyzer's live screen off, closes its USB port and says in its window who has the analyzer. Open the port once it is free (opening fails with "Resource busy" until then: try again every
few tenths of a second). When you're done, close the port and remove the file: tinySA Screen takes the analyzer back
within half a second. If your program ends without removing the file, tinySA Screen notices that the process is gone
and takes the analyzer back anyway.

```python
from tinysa_screen import borrow

with borrow('sweep-logger.py'):
    # tinySA Screen has let go of the tinySA: open its port, measure, close the port.
    ...
```

```bash
echo "$$ my-script" > ~/.tinysa-busy   # tinySA Screen lets go within half a second
sleep 2
my-tinysa-tool /dev/cu.usbmodem4001     # whatever needs the analyzer
rm ~/.tinysa-busy                      # tinySA Screen takes it back
```

Rules of the road:

- One borrower at a time: the file holds one line. Check it isn't someone else's (its process still running) before
  you write it.
- The analyzer is as tinySA Screen found it, sweeping on its own. Put back anything you change that the next program
  wouldn't expect.
- When you open the port, send `refresh off` first and drop what comes back. tinySA Screen turns the live screen off
  before it lets go, but a viewer that crashed may have left it on; the analyzer would then send its screen between
  your replies.

## Feeding

A program that keeps the analyzer itself, a monitor or logger running all day, can still have its screen in tinySA
Screen's window. tinySA Screen and the program meet in one folder, `~/Library/Caches/tinySA Screen/`:

| File | Written by | What it is |
| --- | --- | --- |
| `watching` | tinySA Screen | Touched every second while the window is open; removed when it closes. |
| `screen.png` | your program | The analyzer's screen, any size (480 × 320 for the Ultra models). |
| `state.json` | your program | What your program is doing, with its process ID (below). |

Replace both files in one step: write another file in the folder, then rename it over the old one, so tinySA Screen
never reads half of one.

`state.json`:

```json
{ "state": "holding", "pid": 48211, "name": "Band Monitor", "program": "", "since": 1792121828.13 }
```

| Field | |
| --- | --- |
| `state` | `holding`: you have the analyzer, and pictures come while someone watches. `lent`: you lent it to `program` for a while. `waiting`: you're waiting for the analyzer (switched off or unplugged). `stopped`: you're done (write it as you exit). |
| `pid` | Your process ID. tinySA Screen uses your pictures only while this process runs, so a crash can't leave the window showing an old picture as if live. |
| `name` | Your program's name, for the window ("Pictures from Band Monitor"). |
| `program` | Who has the analyzer, when `state` is `lent`. |
| `since` | When the state began (seconds since 1970); optional. |

While a feeder runs (its `state.json` isn't `stopped` and its process is alive), tinySA Screen shows its pictures and
never opens the analyzer, even when the analyzer's port is free for a moment. Your program:

1. Writes `state.json` when it starts and whenever its state changes.
2. While `watching` is less than 3 seconds old, puts a new `screen.png` after each sweep. Otherwise it needn't make
   pictures at all: no one is looking. tinySA Screen shows a picture as live for three times the usual interval
   between your pictures (at least 6 seconds); after that its note says "No new picture since …".
3. Writes `"state": "stopped"` as it exits.

Getting the analyzer's screen is one command: `capture` sends it raw, two bytes a pixel (RGB565, high byte first);
from firmware v1.4-252 on, `capture rle` sends it packed into about 30 KB ([HOW-IT-WORKS.md](HOW-IT-WORKS.md)).
With the Python helpers, `integrations/python/example_feeder.py` does all of this in about thirty lines.

## Asking

A program that wants the screen recorded doesn't need the analyzer at all: it asks tinySA Screen. The command line does
it in one command, with the app open or not:

```bash
tinysa-screen record --seconds 30 --output /tmp/band.gif --name my-script --json
```

With the app open, the command line asks the app through its control socket, `~/Library/Caches/tinySA Screen/control.sock`
(this user only): one line of JSON in, one line of JSON back. Recordings work on whatever the window shows, the analyzer
over USB or a feeding program's pictures, and the window's title says who is recording. Requests, replies and the rest
are in [COMMAND-LINE.md](COMMAND-LINE.md); in Python, `ask('record', seconds=30, output='/tmp/band.gif')`.

## Which program has the analyzer

Your program can tell what tinySA Screen is doing from the same files: its `watching` file is fresh while its window
is open. To see which process has the port open, `lsof /dev/cu.usbmodem*`.
