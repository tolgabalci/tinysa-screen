"""Work alongside tinySA Screen (https://github.com/tolgabalci/tinysa-screen) from Python, standard library only.

- borrow(name): use the tinySA while tinySA Screen is open. tinySA Screen lets go of it for the `with` block and takes
  it back afterwards.
- Feeder(name): your program keeps the tinySA, and its screen shows in tinySA Screen's window while the window is open.
- Console(): the tinySA's USB console for this program alone, with commands, replies and the screen as a PNG.
- LiveScreen(console): the analyzer's screen as it is drawn while it sweeps on its own, for a picture of every sweep
  (a feeder's, say), with commands between sweeps; sweep_on(console) starts it sweeping with its traces kept.
- ask(command, ...): asks the open app to record a GIF, save the seconds it keeps, save a screenshot, or say what it
  sees.

The protocols are in docs/INTEGRATION.md and docs/COMMAND-LINE.md; example_borrow.py and example_feeder.py use the first
four, example_record.py the last.
"""
from __future__ import annotations

import collections
import contextlib
import errno
import fcntl
import json
import os
import re
import select
import socket
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
CONTROL = os.path.join(FEED_FOLDER, 'control.sock')
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

    def picture(self, png: bytes, made: float | None = None) -> None:
        """The analyzer's screen, as a PNG (LiveScreen.png() or Console.screen_png()), dated `made` (seconds since 1970)
        when given: the app takes a picture's date for when the screen was so, in GIFs too."""
        self._put('screen.png', png, made)

    def state(self, state: str, program: str = '') -> None:
        """'holding', 'lent' (to `program`), 'waiting' (for the analyzer) or 'stopped'."""
        body = {'state': state, 'program': program, 'pid': os.getpid(), 'name': self.name, 'since': time.time()}
        self._put('state.json', json.dumps(body).encode())

    def _put(self, name: str, data: bytes, made: float | None = None) -> None:
        part = os.path.join(FEED_FOLDER, f'.{name}.{os.getpid()}.part')
        with open(part, 'wb') as fh:
            fh.write(data)
        if made is not None:
            os.utime(part, (made, made))
        os.replace(part, os.path.join(FEED_FOLDER, name))  # in one step: never half a file


# Asking the open app


def ask(command: str, **fields) -> dict | None:
    """Asks the open tinySA Screen: 'record' (seconds=, output=, and start=, stop= in hertz for a given band),
    'capture' (output=, seconds=), 'screenshot' (output=), 'sweep' (start=, stop= to set the span), 'peaks' (seconds=,
    count=) or 'status'; also
    scale=1 or 2, date=, time=, name=. Its reply as a dict ('ok', and 'error' or 'file', 'seconds'...), or None when the
    app isn't open. Waits as long as the request takes; output paths must be absolute."""
    request = {'command': command, **fields}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        try:
            connection.connect(CONTROL)
        except (FileNotFoundError, ConnectionRefusedError):
            return None
        connection.sendall((json.dumps(request) + '\n').encode())
        connection.settimeout(float(fields.get('seconds') or 0) + 120)
        reply = b''
        while not reply.endswith(b'\n'):
            chunk = connection.recv(65536)
            if not chunk:
                raise ConnectionError('tinySA Screen closed before answering')
            reply += chunk
    return json.loads(reply)


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

    def resync(self) -> None:
        """After a reply that never came whole: what's pending dropped, and a fresh prompt."""
        termios.tcflush(self.fd, termios.TCIOFLUSH)
        os.write(self.fd, b'\r')
        self._read(lambda buf: buf.endswith(PROMPT), 3)

    def screen_size(self) -> tuple[int, int]:
        """The screen's width and height: 480 x 320 on the Ultra models, 320 x 240 on the original."""
        if not hasattr(self, '_size'):
            self._size = (480, 320) if self.cmd('version').lower().startswith('tinysa4') else (320, 240)
        return self._size

    def capture(self, timeout: float = 10) -> bytes:
        """The screen as `capture rle` sends it (firmware v1.4-252 on: "BM", the size, then a palette and packed rows),
        or the raw screen it sends instead on older firmware (RGB565, high byte first). Read by its length: the
        prompt's bytes can occur inside a picture."""
        width, height = self.screen_size()
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
        return data[: size(data)]

    def screen_png(self, timeout: float = 10) -> bytes:
        """The analyzer's screen as a PNG (`capture`)."""
        width, height = self.screen_size()
        data = self.capture(timeout)
        if data[:8] != struct.pack('<HHHBB', 0x4D42, width, height, 8, 1):
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


def sweep_on(console: Console, timeout: float = 10) -> None:
    """The analyzer sweeping on its own again, every trace as it was. Not `resume`: it recomputes the sweep's
    frequencies, which marks the settings changed, and the next sweep starts every max hold over. The top menu's PAUSE
    (`menu 1`) only switches the sweep on or off, so it is sent when `status` says Paused, and checked. Firmware without
    `status` is left as it is."""
    if console.cmd('status', timeout) != 'Paused':
        return
    console.cmd('menu 1', timeout)
    if console.cmd('status', timeout) != 'Resumed':
        raise RuntimeError("the top menu's PAUSE (menu 1) didn't start the tinySA sweeping")


class LiveScreen:
    """The analyzer's screen as it is drawn, for a picture of every sweep. While it sweeps on its own, its live screen
    (`refresh on`) sends every region it draws as it draws it: a sweep is a burst of them, then nothing while it
    measures the next. `picture()` waits for a burst to end, and `png()` is the screen then (`drawn` says when).

    The regions share the console with the replies to commands, and a command typed while the analyzer draws can land
    inside a region, damaging both, so `cmd()` types one only when it draws nothing: right after `picture()` (a reading
    there cuts the next sweep short) or after another reply. A region that doesn't end as it should is skipped and
    counted (`damaged`): its part of the screen is stale until `reload()`. Opening it starts the analyzer sweeping
    (`sweep_on`), and the analyzer must go on sweeping: paused after a whole sweep it redraws its graph without end, and a
    sweep of a second or more draws its progress bar while it measures, so neither leaves a quiet moment. `stop()` turns
    the live screen off and leaves the analyzer sweeping. Needs firmware with the live screen."""

    HEADERS = (b'fill\r\n', b'bulk\r\n')
    AFTER_REPLY = 0.02  # a reply's last byte, then quiet this soon

    def __init__(self, console: Console, timeout: float = 10):
        self.console = console
        self.width, self.height = console.screen_size()
        self.pixels = bytearray(self.width * self.height * 2)  # RGB565, high byte first, row by row
        self.damaged = 0
        self.drawn = 0.0  # when the screen was last drawn (seconds since 1970)
        self._buf = bytearray()
        self._text = bytearray()
        self._skipping = False
        self._last_byte = time.monotonic()
        self._last_region = 0.0
        self._new = False
        # A burst pauses a few milliseconds between regions; it has ended after three times the longest pause of the
        # last few, 50 to 120 ms.
        self.settle = 0.05
        self._pause = 0.0
        self._pauses: collections.deque = collections.deque(maxlen=16)
        sweep_on(console, timeout)
        self.reload(timeout, on=False)
        self.cmd('refresh on', timeout)

    def reload(self, timeout: float = 10, on: bool = True) -> None:
        """The whole screen again, from a capture (with the live screen off meanwhile)."""
        if on:
            self.stop(timeout)
        data = self.console.capture(timeout)
        if data[:8] == struct.pack('<HHHBB', 0x4D42, self.width, self.height, 8, 1):
            colors = int.from_bytes(data[8:10], 'little') // 2
            palette = [bytes(data[10 + 2 * i : 12 + 2 * i]) for i in range(colors)]
            at = 10 + 2 * colors
            rows = bytearray()
            for _ in range(self.height):
                n = int.from_bytes(data[at : at + 2], 'little')
                rows += b''.join(map(palette.__getitem__, _unpackbits(data[at + 2 : at + 2 + n])))
                at += 2 + n
            data = bytes(rows)
        if len(data) != len(self.pixels):
            raise ValueError(f'a capture of {len(data)} bytes for a {self.width} x {self.height} screen')
        self.pixels[:] = data
        self.drawn = time.time()
        self.damaged = 0
        # The capture cut a sweep short or came between two; the analyzer may redraw its graph once, unseen, then
        # measures: the live screen goes on while it does.
        time.sleep(0.1)
        if on:
            self.cmd('refresh on', timeout)

    def stop(self, timeout: float = 10) -> None:
        """The live screen off, the console as `Console.cmd` expects it; the analyzer goes on sweeping."""
        try:
            self.cmd('refresh off', timeout)
            self._quiet()
        except TimeoutError:  # the reply lost inside a region: off without one, and a fresh prompt
            for _ in range(2):
                os.write(self.console.fd, b'refresh off\r')
                time.sleep(0.3)
                termios.tcflush(self.console.fd, termios.TCIFLUSH)
            self.console.resync()
        self._buf.clear()

    def picture(self, timeout: float = 5) -> bool:
        """Waits for the analyzer to draw something (a sweep) and then pause: True with the screen up to date, False when
        it drew nothing in `timeout` seconds (paused, say)."""
        end = time.monotonic() + timeout
        self._new = False
        while time.monotonic() < end:
            self._read(min(0.02, max(0.0, end - time.monotonic())))
            if self._new and self._idle():
                self._pauses.append(self._pause)
                self._pause = 0.0
                self.settle = min(0.12, max(0.05, 3 * max(self._pauses)))
                self.drawn = time.time() - (time.monotonic() - self._last_region)
                return True
        return False

    def png(self) -> bytes:
        """The screen as a PNG."""
        if not _RGB565:
            _RGB565.extend(_rgb((v & 0xFF) << 8 | v >> 8) for v in range(1 << 16))
        pixels = memoryview(bytes(self.pixels)).cast('H')  # read little-endian, so _RGB565 swaps the two bytes
        rows = b''.join(
            b'\x00' + b''.join(map(_RGB565.__getitem__, pixels[y * self.width : (y + 1) * self.width]))
            for y in range(self.height)
        )
        return _png(self.width, self.height, 2, rows)

    def cmd(self, line: str, timeout: float = 10) -> str:
        """A command's reply, as `Console.cmd`, typed while the analyzer draws nothing."""
        self._quiet()
        self._text.clear()
        self._skipping = False
        os.write(self.console.fd, (line + '\r').encode())
        end = time.monotonic() + timeout
        while PROMPT not in self._text:
            if time.monotonic() > end:
                raise TimeoutError(f'{line!r}: no reply in {timeout} s')
            self._read(min(0.05, max(0.0, end - time.monotonic())))
        reply, _, rest = bytes(self._text).partition(PROMPT)
        self._text = bytearray(rest)
        echo = (line + '\r\n').encode()
        if reply.startswith(echo):
            reply = reply[len(echo) :]
        return reply.decode(errors='replace').replace('\r', '').strip()

    def _quiet(self, limit: float = 3) -> None:
        end = time.monotonic() + limit
        while not self._idle():
            if time.monotonic() > end:
                raise TimeoutError(f'the tinySA never stopped drawing in {limit} s')
            self._read(max(0.0, max(self._last_region + self.settle, self._last_byte + self.AFTER_REPLY) - time.monotonic()))

    def _idle(self) -> bool:
        """Nothing drawn for `settle`, nothing at all for a moment, and nothing come meanwhile still to be read."""
        now = time.monotonic()
        if now - self._last_region < self.settle or now - self._last_byte < self.AFTER_REPLY:
            return False
        ready, _, _ = select.select([self.console.fd], [], [], 0)
        return not ready

    def _read(self, wait: float) -> None:
        asked = time.monotonic()
        ready, _, _ = select.select([self.console.fd], [], [], wait)
        if not ready:
            return
        try:
            chunk = os.read(self.console.fd, 1 << 16)
        except BlockingIOError:
            return
        if not chunk:
            raise OSError(errno.EIO, 'the tinySA went away')
        self._buf += chunk
        self._last_byte = time.monotonic()
        # A pause between regions is the analyzer's only when this waited for them: bytes already waiting were late
        # because this program was.
        self._parse(waited=self._last_byte - asked > 0.002)

    def _parse(self, waited: bool) -> None:
        buf = self._buf
        first = True
        while buf:
            if buf[:6] in self.HEADERS:
                at = 0
            else:
                found = [i for i in (buf.find(self.HEADERS[0]), buf.find(self.HEADERS[1])) if i >= 0]
                if not found:
                    # Text, but its last bytes may start a region still on its way.
                    keep = next((n for n in range(min(5, len(buf)), 0, -1)
                                 if any(h.startswith(bytes(buf[-n:])) for h in self.HEADERS)), 0)
                    self._take_text(len(buf) - keep)
                    return
                at = min(found)
                if at:
                    self._take_text(at)
                    continue
            if len(buf) < 14:
                return
            x, y, w, h = struct.unpack_from('<hhhh', buf, 6)
            fill = buf[0] == ord('f')
            end = 14 + (2 if fill else w * h * 2)
            if x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > self.width or y + h > self.height:
                self._skip()
                continue
            if len(buf) < end + len(PROMPT):
                return
            if buf[end : end + len(PROMPT)] != PROMPT:
                self._skip()
                continue
            body = bytes(buf[14:end])
            stride = self.width * 2
            for row in range(h):
                at = (y + row) * stride + 2 * x
                self.pixels[at : at + 2 * w] = body * w if fill else body[2 * w * row : 2 * w * (row + 1)]
            del buf[: end + len(PROMPT)]
            now = time.monotonic()
            if first and waited and now - self._last_region < 0.25:
                self._pause = max(self._pause, now - self._last_region)
            first = False
            self._last_region = now
            self._new = True
            self._skipping = False

    def _take_text(self, end: int) -> None:
        if end <= 0:
            return
        if not self._skipping:
            self._text += self._buf[:end]
        del self._buf[:end]

    def _skip(self) -> None:
        if not self._skipping:
            self.damaged += 1
        self._skipping = True
        del self._buf[:1]


_RGB565: list = []  # each RGB565 pixel, its two bytes read little-endian, as RGB; made when first needed


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
