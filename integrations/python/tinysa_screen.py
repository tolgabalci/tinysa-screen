"""Work alongside tinySA Screen (https://github.com/tolgabalci/tinysa-screen) from Python, standard library only.

- borrow(name): use the tinySA while tinySA Screen is open. tinySA Screen lets go of it for the `with` block and takes
  it back afterwards.
- Feeder(name): your program keeps the tinySA, and its screen shows in tinySA Screen's window while the window is open.
- Console(): the tinySA's USB console for this program alone, with commands, replies and the screen as a PNG.

The protocols are in docs/INTEGRATION.md; example_borrow.py and example_feeder.py use all three.
"""
from __future__ import annotations

import contextlib
import errno
import fcntl
import json
import os
import re
import select
import struct
import subprocess
import termios
import time
import tty
import zlib

BORROW_FILE = os.path.expanduser('~/.tinysa-busy')
FEED_FOLDER = os.path.expanduser('~/Library/Caches/tinySA Screen')
WATCHING = os.path.join(FEED_FOLDER, 'watching')
WATCHING_FOR = 3  # seconds a touch of WATCHING means the window is open
PROMPT = b'ch> '


def _running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


# Borrowing


def _borrower():
    """The process ID and name of a program that has borrowed the tinySA and still runs, or None."""
    try:
        with open(BORROW_FILE) as fh:
            parts = fh.read().split(maxsplit=1)
        pid = int(parts[0])
    except (FileNotFoundError, ValueError, IndexError):
        return None
    if pid == os.getpid() or not _running(pid):
        return None
    return pid, (parts[1].strip() if len(parts) > 1 else f'process {pid}')


@contextlib.contextmanager
def borrow(name: str):
    """Borrows the tinySA from tinySA Screen for the `with` block: it lets go within half a second (open the port with
    Console(), which waits for it) and takes the analyzer back when the block ends. Fails if another program has
    borrowed it."""
    while True:
        try:  # created only if it isn't there: two programs can't both think they have it
            fd = os.open(BORROW_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            os.write(fd, f'{os.getpid()} {name}\n'.encode())
            os.close(fd)
            break
        except FileExistsError:
            other = _borrower()
            if other:
                raise RuntimeError(f'{other[1]} (process {other[0]}) has borrowed the tinySA') from None
            with contextlib.suppress(FileNotFoundError):
                os.remove(BORROW_FILE)  # left by a program that has ended
    try:
        yield
    finally:
        try:
            with open(BORROW_FILE) as fh:
                if fh.read().split()[0] == str(os.getpid()):
                    os.remove(BORROW_FILE)
        except (OSError, IndexError):
            pass


# Feeding


class Feeder:
    """Feeds tinySA Screen the analyzer's screen while your program keeps the analyzer. As a context manager it says
    "holding" when it starts and "stopped" when it ends; in between, put a picture with `picture()` whenever
    `watched()` (the window is open), and say what you're doing with `state()`."""

    def __init__(self, name: str):
        self.name = name
        os.makedirs(FEED_FOLDER, exist_ok=True)

    def __enter__(self) -> 'Feeder':
        self.state('holding')
        return self

    def __exit__(self, *_) -> None:
        self.state('stopped')

    def watched(self) -> bool:
        """Whether tinySA Screen's window is open: worth making pictures."""
        try:
            return time.time() - os.path.getmtime(WATCHING) < WATCHING_FOR
        except OSError:
            return False

    def picture(self, png: bytes) -> None:
        """The analyzer's screen, as a PNG (Console.screen_png())."""
        self._put('screen.png', png)

    def state(self, state: str, program: str = '') -> None:
        """'holding', 'lent' (to `program`), 'waiting' (for the analyzer) or 'stopped'."""
        body = {'state': state, 'program': program, 'pid': os.getpid(), 'name': self.name, 'since': time.time()}
        self._put('state.json', json.dumps(body).encode())

    def _put(self, name: str, data: bytes) -> None:
        part = os.path.join(FEED_FOLDER, f'.{name}.{os.getpid()}.part')
        with open(part, 'wb') as fh:
            fh.write(data)
        os.replace(part, os.path.join(FEED_FOLDER, name))  # in one step: never half a file


# The console


def find_tinysa() -> str:
    """The tinySA's serial port, found by its USB name ("tinySA4" for the Ultra models, "tinySA" for the original)."""
    for product in ('tinySA4', 'tinySA'):
        listing = subprocess.run(['ioreg', '-r', '-n', product, '-l', '-w0'], capture_output=True, text=True).stdout
        found = re.search(r'"IOCalloutDevice" = "([^"]+)"', listing)
        if found:
            return found.group(1)
    raise FileNotFoundError('No tinySA on USB: connect it and switch it on')


class Console:
    """The tinySA's USB console for this program alone. Opening waits for the port to be free (tinySA Screen lets go
    within half a second of a borrow), then turns off a live screen a viewer may have left on."""

    def __init__(self, path: str | None = None, wait: float = 10):
        self.path = path or find_tinysa()
        end = time.time() + wait
        while True:
            try:
                self.fd = os.open(self.path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
                fcntl.ioctl(self.fd, termios.TIOCEXCL)
                break
            except OSError as error:
                if error.errno != errno.EBUSY or time.time() > end:
                    raise
                time.sleep(0.2)
        try:
            tty.setraw(self.fd)
            os.write(self.fd, b'refresh off\r')
            time.sleep(0.2)
            termios.tcflush(self.fd, termios.TCIOFLUSH)
            os.write(self.fd, b'\r')
            self._read(lambda buf: buf.endswith(PROMPT), 2)
        except BaseException:
            os.close(self.fd)  # held for this program alone: never left open
            raise

    def __enter__(self) -> 'Console':
        return self

    def __exit__(self, *_) -> None:
        self.close()

    def close(self) -> None:
        os.close(self.fd)

    def _read(self, done, timeout: float) -> bytes:
        buf = b''
        end = time.time() + timeout
        while not done(buf):
            if time.time() > end:
                raise TimeoutError(f'No complete reply after {timeout} s')
            ready, _, _ = select.select([self.fd], [], [], 0.1)
            if ready:
                buf += os.read(self.fd, 1 << 16)
        return buf

    def cmd(self, line: str, timeout: float = 10) -> str:
        """A command's reply as text, without its echo and the prompt."""
        os.write(self.fd, (line + '\r').encode())
        reply = self._read(lambda buf: buf.endswith(PROMPT), timeout)[: -len(PROMPT)]
        echo = (line + '\r\n').encode()
        return (reply[len(echo) :] if reply.startswith(echo) else reply).decode(errors='replace').strip()

    def screen_png(self, timeout: float = 10) -> bytes:
        """The analyzer's screen as a PNG: `capture rle` (firmware v1.4-252 on, about 30 KB), or the raw screen it sends
        instead on older firmware. Read by its length: the prompt's bytes can occur inside a picture."""
        width, height = (480, 320) if self.cmd('version').lower().startswith('tinysa4') else (320, 240)
        header = struct.pack('<HHHBB', 0x4D42, width, height, 8, 1)
        echo = b'capture rle\r\n'
        os.write(self.fd, b'capture rle\r')

        def size(data: bytes):
            if len(data) < 8:
                return None
            if data[:8] != header:
                return width * height * 2
            at = 10
            if len(data) < at:
                return None
            at += int.from_bytes(data[8:10], 'little')
            for _ in range(height):
                if len(data) < at + 2:
                    return None
                at += 2 + int.from_bytes(data[at : at + 2], 'little')
            return at

        def done(buf: bytes) -> bool:
            n = size(buf[len(echo) :])
            return n is not None and len(buf) >= len(echo) + n + len(PROMPT)

        data = self._read(done, timeout)[len(echo) :]
        data = data[: size(data)]
        if data[:8] != header:
            rows = b''.join(
                b'\x00' + b''.join(_rgb(data[i] << 8 | data[i + 1]) for i in range(2 * y * width, 2 * (y + 1) * width, 2))
                for y in range(height)
            )
            return _png(width, height, 2, rows)
        colors = int.from_bytes(data[8:10], 'little') // 2
        palette = b''.join(_rgb(data[10 + 2 * i] << 8 | data[11 + 2 * i]) for i in range(colors))
        at = 10 + 2 * colors
        rows = bytearray()
        for _ in range(height):
            n = int.from_bytes(data[at : at + 2], 'little')
            rows += b'\x00' + _unpackbits(data[at + 2 : at + 2 + n])
            at += 2 + n
        return _png(width, height, 3, bytes(rows), palette)


def _rgb(pixel: int) -> bytes:
    return bytes(((pixel >> 11 & 0x1F) * 255 // 31, (pixel >> 5 & 0x3F) * 255 // 63, (pixel & 0x1F) * 255 // 31))


def _unpackbits(packed: bytes) -> bytes:
    out = bytearray()
    i = 0
    while i < len(packed):
        n = packed[i]
        if n < 128:
            out += packed[i + 1 : i + 2 + n]
            i += 2 + n
        elif n > 128:
            out += packed[i + 1 : i + 2] * (257 - n)
            i += 2
        else:
            i += 1
    return bytes(out)


def _png(width: int, height: int, color_type: int, rows: bytes, palette: bytes = b'') -> bytes:
    def chunk(kind: bytes, body: bytes) -> bytes:
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))

    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, color_type, 0, 0, 0))
    if palette:
        png += chunk(b'PLTE', palette)
    return png + chunk(b'IDAT', zlib.compress(rows, 6)) + chunk(b'IEND', b'')
