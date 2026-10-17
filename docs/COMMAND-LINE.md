# The command line

tinySA Screen's app is also a command-line tool, for scripts, test benches and AI agents: record the analyzer's screen
for some seconds as an animated GIF, save the seconds the open app keeps, save a screenshot, or ask what the app sees.

```bash
tinysa-screen record --seconds 30 --output ~/Desktop/band.gif
tinysa-screen record --seconds 20 --start 2.4G --stop 2.4835G --output wifi.gif
tinysa-screen capture --seconds 15 --output last15.gif
tinysa-screen screenshot --output screen.png
tinysa-screen sweep --start 902M --stop 928M
tinysa-screen peaks --seconds 30
tinysa-screen status
```

## Setting it up

The tool is the app's own program, inside the app. Link it into a folder on your `PATH` once:

```bash
ln -s "/Applications/tinySA Screen.app/Contents/MacOS/tinysa-screen" /usr/local/bin/tinysa-screen
```

(Use `~/Applications/...` if the app is there, and `sudo` if `/usr/local/bin` isn't yours. A program can also run it by
its full path without the link.)

## Commands

| Command | What it does |
| --- | --- |
| `record --seconds N --output FILE.gif` | Records the screen from now, for N seconds (1 to 120), as an animated GIF. |
| `capture [--seconds N] --output FILE.gif` | Saves the last N seconds the open app keeps (Settings › Keep the latest seconds), all of them without `--seconds`. For when something has just happened. Needs the app open. |
| `screenshot --output FILE.png` | Saves the screen as it is now, at its own size (`--sharp`: twice that). |
| `sweep [--start F --stop F]` | Says the span the analyzer sweeps, or sets it. Needs the analyzer on USB, a tinySA Ultra. |
| `peaks [--seconds N] [--count N]` | The highest peaks of the live trace over N seconds (10 by default, at most 600), held from the screen as the app's [peak hold](../README.md#peak-hold) does: the analyzer is asked nothing, so it works on fed pictures too. Up to `--count` peaks (5; at most 9), each at least 6 dB above its valleys and the noise. |
| `status` | Says what tinySA Screen sees: whether the app is open, where its picture comes from, the seconds it keeps, the tinySAs on USB, a program feeding pictures or borrowing the analyzer. |
| `help`, `--help` | The usage. `--version`: the version. |

Options for the GIFs, the same as in the app:

| Option | |
| --- | --- |
| `--small` | The GIF at the screen's own size (480 × 320 for a tinySA Ultra, plus the date strip); without it, twice that, every pixel kept sharp. |
| `--no-date`, `--no-time` | No date, or no time, in the strip under the screen. With both, no strip. |
| `--start F --stop F` | With `record`: sweep this span while recording, then put the analyzer's own span back. With `sweep`: set it. Frequencies as `902M`, `2.4G`, `433.92MHz`, `100k` or `915000000`. |
| `--keep-span` | With `record --start --stop`: leave the analyzer on that span afterwards. |
| `--name NAME` | Who is asking: the app's window says "recording for NAME" while it records. |
| `--json` | The result as one line of JSON (below), for programs. |

`--seconds` is also `-s`, and `--output` `-o`; `record 30 -o band.gif` works too. An existing output file is replaced.
Relative paths are relative to the current folder.

## Who does the work

- **The app is open**: the command asks it, through its [control socket](#the-control-socket), and the app records from
  the picture it shows, whether that comes from the analyzer over USB or from a program feeding pictures. The window's
  title says "recording for NAME" meanwhile, so a recording is never hidden from whoever watches the window, in a call
  say. Stopping the command (Control-C) cancels the recording.
- **The app isn't open**: the command does it alone, without a window, sharing the analyzer as the app would: it shows
  a feeding program's pictures rather than taking the analyzer from it, lets go of the analyzer when another program
  [borrows](INTEGRATION.md#borrowing) it, and turns the analyzer's live screen off when it's done (also on Control-C).
  `capture` needs the app: only the open app keeps seconds.

A recording or screenshot starts only from a live picture. When the picture isn't coming (no tinySA on USB, another
program has it, a feeding program has gone quiet), the command waits up to 15 seconds for it, then fails with the reason
the window would show. It never records an old picture as if it were live. If the picture stops while recording, the
GIF holds the last screen, and the result's `notes` say when the picture stopped and came back.

Exit status: 0 when done, 1 when it failed (the reason on standard error, or in the JSON), 2 for wrong usage.

## The result

Without `--json`, one line for people:

```
Saved /Users/me/Desktop/band.gif: 30.0 s of tinySA ULTRA+ ZS406 · v1.4-252, 39 frames, 960 × 672, 1.2 MB
```

With `--json`, one line of JSON:

```json
{"bytes":1258291,"end":"2026-10-17T10:15:32.104-04:00","file":"/Users/me/Desktop/band.gif","frames":39,"height":672,"images":70,"ok":true,"seconds":30,"source":"tinySA ULTRA+ ZS406 · v1.4-252","start":"2026-10-17T10:15:02.104-04:00","width":960}
```

| Field | |
| --- | --- |
| `ok` | `true` when done; otherwise `error` says why. |
| `file`, `bytes`, `width`, `height` | The file written. |
| `seconds`, `start`, `end` | How long the GIF runs, and the moments it starts and ends (ISO 8601, the Mac's time zone). For a screenshot, `start` is when its picture came. |
| `frames`, `images` | Frames of the screen in the GIF (one a sweep), and images in the file (frames, and the time ticking on). |
| `source` | Where the picture came from: the analyzer and its firmware, or "Pictures from" the feeding program. |
| `notes` | What a viewer should know about the recording: the span it swept, the picture stopping and coming back, with times. |
| `sweep`, `previousSweep` | For `sweep`: the span now, and before a change, as `{"start": 902000000, "stop": 928000000, "points": 450}` (hertz). For `peaks`: the span read from the screen. |
| `peaks`, `resolution` | For `peaks`: the peaks, highest first, as `{"frequency": 906169000, "level": -23.1}` (hertz, dBm), and how finely the screen resolves them, `{"hertz": 57906, "decibels": 0.42}` (a column and a row of the graph). |

`status --json` answers with `app` (whether the app answered), `version`, `devices` (tinySAs on USB), `feeder` and
`borrower` (programs feeding pictures, or that borrowed the analyzer), and from the open app `source`, `picture`
(whether a picture is coming), `usb` (whether it comes from the analyzer itself), `note` (why not, as the window says
it), `keptSeconds`, `availableSeconds` and `recordings` (recordings running).

## For AI agents and scripts

The command line is meant to be easy to drive: one command per action, a result you can read, a non-zero exit status
on failure with the reason. An agent with a shell can, for example:

```bash
tinysa-screen status --json                               # is there a live picture?
tinysa-screen record -s 20 -o run-42.gif --name "bench agent" --json
```

and keep the GIF beside its other results. Things worth knowing:

- A recording takes as long as asked: `record -s 120` returns after two minutes.
- To record a given band, give it: `record -s 20 --start 902M --stop 928M`. The span is set, a whole sweep of it is
  drawn before the recording begins, and the analyzer's own span is put back afterwards (the notes say so). For other
  settings (markers, levels), use the analyzer's own commands while you [borrow](INTEGRATION.md#borrowing) it.
- `capture` is the one to use after the fact: with the app open, it has the last minute (by default) at any moment.
- `peaks` answers "what's on the band?" in numbers, without a picture: `peaks -s 60 --json` lists the strongest
  signals seen in a minute. Its levels and frequencies are read from the screen, so they're as fine as its pixels
  (`resolution` says how fine); for exact values, borrow the analyzer and ask it (`data`, markers).

## The control socket

The command line talks to the open app through a Unix-domain socket in the app's folder,
`~/Library/Caches/tinySA Screen/control.sock`, which only your user can open. Any language can use it the same way:
connect, send one request as a line of JSON, read one reply line, and the app closes the connection. A request runs as
long as it takes (a recording, its seconds); closing the connection before the reply cancels it. Nothing answering at
the socket means the app isn't open.

```json
{"command": "record", "seconds": 30, "output": "/Users/me/band.gif", "scale": 2, "date": true, "time": true, "name": "my-script"}
```

| Field | |
| --- | --- |
| `command` | `record`, `capture`, `screenshot`, `sweep`, `peaks` or `status`. |
| `seconds` | How long to record; for `capture`, how many of the kept seconds (all when left out). |
| `output` | Where to write the file: an absolute path, in a folder that exists. |
| `scale` | 1, or 2 (the default for GIFs; screenshots default to 1). |
| `date`, `time` | The date and time under the screen in a GIF (both by default). |
| `name` | Who asks, for the window. |
| `start`, `stop` | A span in hertz: for `sweep`, to set; for `record`, to sweep while recording. |
| `restore` | For `record` with a span: `false` leaves it set afterwards. |
| `count` | For `peaks`: how many (5 by default, at most 9). |

The reply is the same JSON as `--json` above. In Python, `integrations/python/tinysa_screen.py` has `ask()`:

```python
from tinysa_screen import ask

reply = ask('record', seconds=10, output='/tmp/band.gif', name='my-script')
if reply is None:
    print('tinySA Screen is not open')
elif not reply['ok']:
    print('Failed:', reply['error'])
```
