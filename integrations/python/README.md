# Python helpers

`tinysa_screen.py` works alongside tinySA Screen from Python 3.9 or later on macOS (the Mac's own `python3` will do), with the standard library only. Copy it
next to your script, or add this folder to `PYTHONPATH`.

- `borrow(name)`: use the tinySA for a `with` block while tinySA Screen is open.
- `Feeder(name)`: keep the tinySA in your program and show its screen in tinySA Screen's window.
- `Console()`: the tinySA's USB console (found by its USB name), with `cmd()` and `screen_png()`.
- `LiveScreen(console)`: the analyzer's screen as it is drawn while it sweeps on its own, for a picture of every sweep
  (`picture()`, `png()`), with commands between sweeps (`cmd()`); `sweep_on(console)` starts the analyzer sweeping
  with its traces kept (`resume` would start its max holds over).
- `ask(command, ...)`: asks the open app to record a GIF (`'record'`), save the seconds it keeps (`'capture'`), save a
  screenshot, or say what it sees (`'status'`).

`example_borrow.py`, `example_feeder.py` and `example_record.py` show them, and run as they are.
`test_tinysa_screen.py` tests them without a tinySA: `python3 -m unittest discover -s integrations/python`. The protocols
themselves are in [docs/INTEGRATION.md](../../docs/INTEGRATION.md) and [docs/COMMAND-LINE.md](../../docs/COMMAND-LINE.md),
for other languages.
