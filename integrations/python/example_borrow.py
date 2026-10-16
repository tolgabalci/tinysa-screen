"""Borrows the tinySA from tinySA Screen, asks for its firmware version and its sweep, saves its screen, and gives it
back. Run it with tinySA Screen open: its window says the analyzer is lent to this script, then goes on.

    python3 example_borrow.py
"""
from tinysa_screen import Console, borrow

with borrow('example_borrow.py'):
    with Console() as tinysa:
        print('Firmware:', tinysa.cmd('version').splitlines()[0])
        print('Sweep (start, stop, points):', tinysa.cmd('sweep'))
        with open('tinysa-screen.png', 'wb') as fh:
            fh.write(tinysa.screen_png())
        print('Saved its screen as tinysa-screen.png')
