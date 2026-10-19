"""Tests for tinysa_screen.py that need no tinySA: a socket pair stands in for its console.

    python3 -m unittest discover -s integrations/python
"""
import contextlib
import os
import select
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest
import zlib
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tinysa_screen  # noqa: E402
from tinysa_screen import Feeder, LiveScreen, sweep_on  # noqa: E402

WIDTH, HEIGHT = 480, 320


def region(kind, x, y, w, h, body):
    return kind + struct.pack('<hhhh', x, y, w, h) + body + b'ch> '


class FakeConsole:
    """The parts of Console that LiveScreen uses, answering as a sweeping tinySA Ultra with a black screen."""

    def __init__(self, fd, replies=None):
        self.fd = fd
        self.replies = replies or {}
        self.sent = []

    def screen_size(self):
        return WIDTH, HEIGHT

    def cmd(self, line, timeout=10):
        self.sent.append(line)
        answer = self.replies.get(line, 'Resumed' if line == 'status' else '')
        return answer.pop(0) if isinstance(answer, list) else answer

    def capture(self, timeout=10):
        return bytes(WIDTH * HEIGHT * 2)

    def resync(self):
        pass


def answer(analyzer, line, extra=b''):
    """Answers one command on the analyzer's side of the socket pair: its echo, `extra`, the prompt."""
    got = b''
    while not got.endswith(b'\r'):
        got += analyzer.recv(100)
    assert got == (line + '\r').encode(), got
    analyzer.sendall((line + '\r\n').encode() + extra + b'ch> ')


class LiveScreenTests(unittest.TestCase):
    def setUp(self):
        self.ours, self.analyzer = socket.socketpair()
        self.ours.setblocking(False)
        helper = threading.Thread(target=answer, args=(self.analyzer, 'refresh on'))
        helper.start()
        self.live = LiveScreen(FakeConsole(self.ours.fileno()))
        helper.join()

    def tearDown(self):
        self.ours.close()
        self.analyzer.close()

    def pixel(self, x, y):
        at = (y * WIDTH + x) * 2
        return bytes(self.live.pixels[at : at + 2])

    @contextlib.contextmanager
    def console_clock(self, due, start=1000.0):
        """Runs the block on a clock of the test's own, the regions in `due` ((when, bytes), in order) coming when it
        says. Timed for real, the moments these tests are about move on a busy machine (a CI runner), where this
        program can be held up for tens of milliseconds."""
        clock = [start]
        wall = time.time()
        real_select = select.select

        def console_select(readers, writers, errors, timeout=None):
            """Waits as a console does: until the next region comes (sent then), else the whole timeout."""
            ready, _, _ = real_select(readers, [], [], 0)
            if ready:
                return ready, [], []
            if due and due[0][0] <= clock[0] + (timeout or 0):
                clock[0] = max(clock[0], due[0][0])
                self.analyzer.sendall(due.pop(0)[1])
                return real_select(readers, [], [], 1)
            clock[0] += timeout or 0
            return [], [], []

        with mock.patch.object(tinysa_screen.time, 'monotonic', lambda: clock[0]), \
                mock.patch.object(tinysa_screen.time, 'time', lambda: wall + clock[0] - start), \
                mock.patch.object(tinysa_screen.select, 'select', console_select):
            yield clock

    def feed(self, data, piece=None):
        piece = piece or len(data)
        for i in range(0, len(data), piece):
            self.analyzer.sendall(data[i : i + piece])
            end = time.monotonic() + 0.01
            while time.monotonic() < end:
                self.live._read(0.002)

    def test_regions_in_pieces_of_any_size(self):
        stream = region(b'bulk\r\n', 10, 20, 2, 2, bytes(range(8))) + region(b'fill\r\n', 0, 0, 3, 1, b'\xab\xcd')
        for piece in (1, 2, 3, 5, 7, 13, 64):
            with self.subTest(piece=piece):
                self.live.pixels[:] = bytes(len(self.live.pixels))
                self.feed(stream, piece)
                self.assertEqual([self.pixel(10, 20), self.pixel(11, 20), self.pixel(10, 21), self.pixel(11, 21)],
                                 [b'\x00\x01', b'\x02\x03', b'\x04\x05', b'\x06\x07'])
                self.assertEqual([self.pixel(x, 0) for x in range(4)], [b'\xab\xcd'] * 3 + [b'\x00\x00'])
                self.assertEqual(self.live.damaged, 0)

    def test_a_reply_between_regions(self):
        extra = region(b'fill\r\n', 0, 0, 1, 1, b'\x01\x02') + b'-7.0e+01\r\n' + region(b'fill\r\n', 1, 0, 1, 1,
                                                                                          b'\x03\x04') + b'-6.5e+01\r\n'
        helper = threading.Thread(target=answer, args=(self.analyzer, 'data 2', extra))
        helper.start()
        self.assertEqual(self.live.cmd('data 2', timeout=2), '-7.0e+01\n-6.5e+01')
        helper.join()
        self.assertEqual(self.pixel(1, 0), b'\x03\x04')

    def test_an_echo_inside_a_region_is_skipped_and_counted(self):
        hit = region(b'bulk\r\n', 4, 5, 2, 1, b'\x55\x66\x77\x88')
        self.feed(region(b'bulk\r\n', 0, 5, 2, 1, b'\x11\x22\x33\x44') + hit[:16] + b'data 1\r\n' + hit[16:]
                  + region(b'fill\r\n', 8, 5, 1, 1, b'\x99\xaa'), 4)
        self.assertEqual([self.pixel(0, 5), self.pixel(4, 5), self.pixel(8, 5)],
                         [b'\x11\x22', b'\x00\x00', b'\x99\xaa'])
        self.assertEqual(self.live.damaged, 1)
        self.assertEqual(bytes(self.live._text), b'')  # the rest of the damaged region isn't taken for a reply

    def test_a_reply_after_a_damaged_region_is_kept(self):
        hit = region(b'bulk\r\n', 4, 5, 2, 1, b'\x55\x66\x77\x88')
        self.feed(hit[:16] + b'xx' + hit[16:])
        helper = threading.Thread(target=answer, args=(self.analyzer, 'marker 1 off'))
        helper.start()
        self.assertEqual(self.live.cmd('marker 1 off', timeout=2), '')
        helper.join()

    def test_a_picture_once_the_burst_pauses(self):
        burst = b''.join(region(b'fill\r\n', x, 0, 1, 1, b'\x01\x01') for x in range(20))
        with self.console_clock([(1000.05, burst)]) as clock:
            asked = time.time()
            self.assertTrue(self.live.picture(2))
            self.assertGreaterEqual(clock[0] - 1000.0, 0.05 + 0.05)  # the burst, then a pause as long as `settle`
            self.assertAlmostEqual(self.live.drawn, asked + 0.05, delta=0.001)  # when its last region came
            self.assertFalse(self.live.picture(0.2))  # nothing more drawn

    def test_bytes_waiting_after_a_delay_are_read_before_the_burst_ends(self):
        self.feed(region(b'fill\r\n', 0, 9, 1, 1, b'\x01\x01'))
        self.analyzer.sendall(region(b'fill\r\n', 1, 9, 1, 1, b'\x02\x02'))  # came while this program was busy
        time.sleep(0.08)
        self.assertTrue(self.live.picture(1))
        self.assertEqual(self.pixel(1, 9), b'\x02\x02')

    def test_a_pause_inside_a_burst_lengthens_the_wait_for_its_end(self):
        due = [(1000.2, region(b'fill\r\n', 0, 8, 1, 1, b'\x01\x01')),
               (1000.23, region(b'fill\r\n', 1, 8, 1, 1, b'\x02\x02'))]
        with self.console_clock(due):
            self.assertTrue(self.live.picture(3))
        self.assertEqual(self.pixel(1, 8), b'\x02\x02')
        self.assertGreater(self.live.settle, 0.07)  # three times the 30 ms pause
        self.assertLessEqual(self.live.settle, 0.12)

    def test_a_header_off_the_screen_is_skipped(self):
        self.feed(b'bulk\r\n' + struct.pack('<hhhh', 470, 0, 32, 32) + region(b'fill\r\n', 2, 2, 1, 1, b'\x07\x08'))
        self.assertEqual(self.pixel(2, 2), b'\x07\x08')
        self.assertEqual(self.live.damaged, 1)

    def test_the_png_has_the_screens_colours(self):
        self.feed(region(b'fill\r\n', 0, 0, 1, 1, b'\xf8\x00') + region(b'fill\r\n', 1, 0, 1, 1, b'\x07\xe0'))
        png = self.live.png()
        self.assertEqual(png[:8], b'\x89PNG\r\n\x1a\n')
        width, height = struct.unpack('>II', png[16:24])
        self.assertEqual((width, height), (WIDTH, HEIGHT))
        at, idat = 8, b''
        while at < len(png):
            n, kind = struct.unpack('>I4s', png[at : at + 8])
            if kind == b'IDAT':
                idat += png[at + 8 : at + 8 + n]
            at += 12 + n
        first_row = zlib.decompress(idat)[: 1 + 3 * WIDTH]
        self.assertEqual(first_row[1:7], bytes([255, 0, 0, 0, 255, 0]))  # pure red, then pure green


class SweepOnTests(unittest.TestCase):
    def test_a_paused_analyzer_is_started_by_its_menu(self):
        console = FakeConsole(-1, {'status': ['Paused', 'Resumed']})
        sweep_on(console)
        self.assertEqual(console.sent, ['status', 'menu 1', 'status'])

    def test_a_sweeping_analyzer_is_left_alone(self):
        console = FakeConsole(-1, {'status': ['Resumed']})
        sweep_on(console)
        self.assertEqual(console.sent, ['status'])

    def test_firmware_without_status_is_left_alone(self):
        console = FakeConsole(-1, {'status': ['status?']})
        sweep_on(console)
        self.assertEqual(console.sent, ['status'])

    def test_a_menu_that_doesnt_start_it_is_an_error(self):
        console = FakeConsole(-1, {'status': ['Paused', 'Paused']})
        with self.assertRaises(RuntimeError):
            sweep_on(console)


class FeederTests(unittest.TestCase):
    def test_a_picture_is_dated_when_its_screen_was_drawn(self):
        with tempfile.TemporaryDirectory() as folder:
            original = tinysa_screen.FEED_FOLDER
            tinysa_screen.FEED_FOLDER = folder
            try:
                Feeder('tests').picture(b'png', made=1792000000.25)
                self.assertAlmostEqual(os.path.getmtime(os.path.join(folder, 'screen.png')), 1792000000.25, places=3)
            finally:
                tinysa_screen.FEED_FOLDER = original


if __name__ == '__main__':
    unittest.main()
