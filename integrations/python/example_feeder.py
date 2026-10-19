"""A program that keeps the tinySA and feeds its screen to tinySA Screen, a picture of every sweep. Here it only watches;
a monitor or a logger would read its measurements where the comment says. Run it, then open tinySA Screen: the window
shows "Pictures from example_feeder.py". Control-C stops it, and tinySA Screen takes the analyzer itself.

    python3 example_feeder.py
"""
import signal
import time

from tinysa_screen import Console, Feeder, LiveScreen, sweep_on

stopping = False


def stop(*_):
    global stopping
    stopping = True


signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)

# The feeder first: seeing it, tinySA Screen lets go of the analyzer, and Console() waits until it has.
with Feeder('example_feeder.py') as feeder, Console() as tinysa:
    print('Feeding tinySA Screen; Control-C stops.')
    sweep_on(tinysa)  # sweeping on its own, whatever it was left doing
    live = None
    try:
        while not stopping:
            if not feeder.watched():  # no one watching: no pictures, and the analyzer's screen needn't stream
                if live:
                    live.stop()
                    live = None
                time.sleep(0.5)
                continue
            if live is None:
                live = LiveScreen(tinysa)  # its screen streaming in, from a capture
                feeder.picture(live.png(), live.drawn)
            if not live.picture(timeout=5):
                print('No sweep drawn in 5 s: paused on the analyzer?')
                continue
            if live.damaged:  # a command's echo landed inside a region: part of the screen is stale
                live.reload()
            feeder.picture(live.png(), live.drawn)
            # ... read your measurements here, right after a sweep: live.cmd('data 2') lists its levels (and cuts the
            # next sweep short); with no window open, tinysa.cmd('data 2') does ...
    finally:
        if live:
            live.stop()  # the analyzer goes on sweeping on its own
print('Stopped.')
