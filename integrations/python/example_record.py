"""Asks the open tinySA Screen what it sees, then records 10 seconds of the analyzer's screen as an animated GIF.
Run it with tinySA Screen open:

    python3 example_record.py

(Without the app, the command line does the same alone: tinysa-screen record --seconds 10 --output band.gif.)
"""
import os

from tinysa_screen import ask

status = ask('status')
if status is None:
    raise SystemExit('tinySA Screen is not open')
print('Picture from:', status.get('source') or 'nowhere yet', '' if status.get('picture') else f"({status.get('note')})")

output = os.path.abspath('band.gif')
reply = ask('record', seconds=10, output=output, name='example_record.py')
if reply['ok']:
    print(f"Saved {reply['file']}: {reply['seconds']} s, {reply['frames']} frames, {reply['bytes'] // 1024} KB")
    for note in reply.get('notes', []):
        print('Note:', note)
else:
    raise SystemExit('Failed: ' + reply['error'])
