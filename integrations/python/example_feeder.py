"""A program that keeps the tinySA and feeds its screen to tinySA Screen. Here it only runs the sweeps; a monitor or a
logger would read its measurements where the comment says. Run it, then open tinySA Screen: the window shows "Pictures
from example_feeder.py". Control-C stops it, and tinySA Screen takes the analyzer itself.

    python3 example_feeder.py
"""
import signal
import time

from tinysa_screen import Console, Feeder

stopping = False


def stop(*_):
    global stopping
    stopping = True


signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)

# The feeder first: seeing it, tinySA Screen lets go of the analyzer, and Console() waits until it has.
with Feeder('example_feeder.py') as feeder, Console() as tinysa:
    print('Feeding tinySA Screen; Control-C stops.')
    while not stopping:
        if feeder.watched():
            tinysa.cmd('waitscan 1', timeout=30)  # one sweep, then the analyzer waits for the next command
            # ... read your measurements here: tinysa.cmd('data 2') lists the last sweep's levels ...
            feeder.picture(tinysa.screen_png())
        else:
            tinysa.cmd('waitscan 1', timeout=30)  # no one watching: just sweep
    tinysa.cmd('resume')  # the analyzer sweeps on its own again
print('Stopped.')
