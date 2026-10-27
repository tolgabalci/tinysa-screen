# Working with other programs

A tinySA's USB console takes one program at a time: two programs sending commands at once would get each other's
replies. tinySA Screen keeps the console while its window is open, and gives other programs two ways in, both a few
lines of code in any language. The files involved are plain text and JSON in your home folder; nothing goes over the
network.

| | You want to | Your program |
| --- | --- | --- |
| [Borrowing](#borrowing) | use the analyzer for a while: a measurement, a script, another app | writes `~/.tinysa-busy`, uses the analyzer, removes the file |
| [Feeding](#feeding) | keep the analyzer in your program all the time, and still show its screen | writes pictures to `~/Library/Caches/tinySA Screen/` while the window is open, and can type its clicks as taps |
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
| `taps` | tinySA Screen | The window's clicks, when your program passes them on ([Clicks as taps](#clicks-as-taps)). |

Replace both files in one step: write another file in the folder, then rename it over the old one, so tinySA Screen
never reads half of one.

`state.json`:

```json
{ "state": "holding", "pid": 48211, "name": "Band Monitor", "program": "", "since": 1792121828.13, "taps": true }
```

| Field | |
| --- | --- |
| `state` | `holding`: you have the analyzer, and pictures come while someone watches. `lent`: you lent it to `program` for a while. `waiting`: you're waiting for the analyzer (switched off or unplugged). `stopped`: you're done (write it as you exit). |
| `pid` | Your process ID. tinySA Screen uses your pictures only while this process runs, so a crash can't leave the window showing an old picture as if live. |
| `name` | Your program's name, for the window's notes ("No new picture from Band Monitor since …") and `tinysa-screen status` ("Pictures from Band Monitor"). |
| `program` | Who has the analyzer, when `state` is `lent`. |
| `since` | When the state began (seconds since 1970); optional. |
| `taps` | `true` when you pass the window's clicks on to the analyzer as taps ([below](#clicks-as-taps)); optional. |

While a feeder runs (its `state.json` isn't `stopped` and its process is alive), tinySA Screen shows its pictures and
never opens the analyzer, even when the analyzer's port is free for a moment. Your program:

1. Writes `state.json` when it starts and whenever its state changes.
2. While `watching` is less than 3 seconds old, puts a new `screen.png` after each sweep, dated when the analyzer drew
   it (the file's modification time: the app and its GIFs take a picture's time from it). Otherwise it needn't make
   pictures at all: no one is looking. tinySA Screen looks for a new picture ten times a second and shows one as live
   for three times the usual interval between your pictures (at least 6 seconds); after that its note says "No new
   picture since …". A picture of the analyzer's keypad stays live however old it gets: the analyzer doesn't sweep
   while its keypad is open and draws nothing until a key is pressed, so no picture comes after it.
3. Writes `"state": "stopped"` as it exits.

**A picture of every sweep.** The analyzer's live screen gives one: let the analyzer sweep on its own and turn it on
(`refresh on`), and the analyzer sends every region of its screen as it draws it, a burst of them for each sweep, then
nothing while it measures the next ([HOW-IT-WORKS.md](HOW-IT-WORKS.md)). Keep a copy of the screen from a capture and
the regions, and write it out when a burst ends. Your program's commands share the console with the regions, and one
typed while the analyzer draws can land inside a region, so type them only when it draws nothing: just after a burst
(a command that reads the analyzer then cuts the next sweep short) or just after another reply. A capture after each
sweep instead (`capture rle`, about 30 KB from firmware v1.4-252 on, `capture` raw on older firmware) is simpler but
slower: the analyzer reads its screen back for it, about 0.4 s, so with a half-second sweep there is a picture about
every 1.1 s, not every sweep.

With the Python helpers, `LiveScreen` does the live screen's part and `integrations/python/example_feeder.py` feeds a
picture of every sweep in about forty lines.

**Keep the analyzer's traces.** Don't send `resume` to start the analyzer sweeping again: it recomputes the sweep's
frequencies, which marks the settings changed, and its next sweep starts every max hold over (a max hold trace loses
what it held). The top menu's PAUSE only switches the sweep on or off: send `menu 1` when `status` says `Paused`
(`sweep_on` in the Python helpers). `waitscan` sweeps without starting anything over, but leaves the analyzer paused.

### Clicks as taps

Say `"taps": true` in `state.json` and tinySA Screen passes on the clicks on its picture, as it does over USB: the
pointer becomes a hand over the picture, and each click goes in `taps`, a line for each, the console command to type
and when it was clicked (seconds since 1970):

```
touch 240 160 1792452000.125
touch 244 160 1792452000.205
release 244 160 1792452000.610
```

`touch x y` while the button is down, again as it moves; `release x y` when it comes up. x and y are pixels of the
analyzer's screen from its top left, as the console takes them. Type each command without the time and the analyzer
acts as on its glass: a tap opens the menu or picks an item, a touch held drags a marker or slides a value, and a touch
held half a second is a long press (a right-click in the window is one). Your program:

1. Reads `taps` like a log that starts over: at first from its end (clicks from before are old), then on from where it
   was, whole lines only (the last one may still be on its way). When the file is another one (its inode changed: the
   app starts a new one when it opens, and when it has grown large) or shorter than where you were, from its start.
2. Types the commands while the analyzer draws nothing, as any command, each touch held as long as it was clicked: when
   a touch and its release come together (your program was busy), wait the difference before the release, or a long
   press becomes a tap.
3. Doesn't wait for a sweep while a touch is down: the analyzer stops sweeping until the release.
4. Leaves out a touch clicked more than 5 seconds ago (it came while you couldn't pass it on), but never the release of
   a touch it typed. A touch down 10 seconds with nothing new is released by your program (the app quit mid-click), and
   so is a touch down when you lend the analyzer or stop.
5. Holds back its own changes while someone clicks, and for a few seconds after: a command that redraws the screen, or
   `menu` (which closes an open menu first), pulls the menu from under them.
6. Minds the keypad. While the analyzer's keypad is open (a number being typed, light keys over its whole screen) it
   doesn't sweep: `waitscan` then holds the analyzer's console, taps included, until someone closes the keypad on the
   analyzer itself (or moves its jog wheel), and a command the sweep has to run (`sweep`, `menu`, `pause`, `data`)
   gives up after 20 s with "Command timeout" and no prompt. `touch`, `release`, `status` and `capture` still answer.
   So don't take the missing sweeps for a failure while a keypad is open: keep the live screen on and keep passing
   taps (the window's Escape cancels a number keypad with its erase key).

A click in the window shows a small ring where it went, since the analyzer's answer comes with your next picture. With
the Python helpers, `Feeder(name, taps=True)` says so in `state.json`, `feeder.pass_taps(live)` types the clicks, made
to be `LiveScreen.picture`'s `between` (it runs while the analyzer draws nothing, and holds the wait open while a touch
is down), and `feeder.release_touch(live)` goes before you let go of the analyzer:

```python
with Feeder('Band Monitor', taps=True) as feeder:
    ...
    if live.picture(5, between=lambda: feeder.pass_taps(live)):
        feeder.picture(live.png(), live.drawn)
```

`example_feeder.py` passes them on.

## Asking

A program that wants the screen recorded doesn't need the analyzer at all: it asks tinySA Screen. The command line does
it in one command, with the app open or not:

```bash
tinysa-screen record --seconds 30 --output /tmp/band.gif --name my-script --json
```

With the app open, the command line asks the app through its control socket, `~/Library/Caches/tinySA Screen/control.sock`
(this user only): one line of JSON in, one line of JSON back. Recordings work on whatever the window shows, the analyzer
over USB or a feeding program's pictures, and the window's subtitle says who is recording. Requests, replies and the rest
are in [COMMAND-LINE.md](COMMAND-LINE.md); in Python, `ask('record', seconds=30, output='/tmp/band.gif')`.

## Which program has the analyzer

Your program can tell what tinySA Screen is doing from the same files: its `watching` file is fresh while its window
is open. To see which process has the port open, `lsof /dev/cu.usbmodem*`.
