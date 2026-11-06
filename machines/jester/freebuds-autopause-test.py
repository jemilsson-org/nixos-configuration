#!/usr/bin/env python3
"""Hermetic test for freebuds-autopause.py: no Bluetooth, so socket.socket
and select.poll are replaced by fakes before listen_once runs.

Case 1: the live bug. recv always raises socket.timeout (what the RFCOMM
        socket does after the buds drop) and poll reports POLLHUP. The old
        code loops on the timeout forever; listen_once must return within
        the bound.
Case 2: both buds worn (0x5b), then one bud leaves (0x5a) delivered with
        POLLIN|POLLHUP at once. The pause must still be issued before
        listen_once returns.
Case 3: a 0106 push, then a 0108 with no buds (0x58): the pause fires on
        the last frame and the next POLLHUP ends the call.
Case 4: recv returns b"" with POLLIN alone: EOF ends the call.
"""
import importlib.util
import os
import select
import socket
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BOUND = 5.0


class FakePoll:
    """Yields the scripted event lists, one per poll() call."""

    def __init__(self, events):
        self.events = list(events)
        self.registered = []

    def register(self, fd, mask):
        self.registered.append((fd, mask))

    def poll(self, timeout=None):
        if not self.events:
            # A regression would keep polling: fail, never hang.
            raise AssertionError("poll() called more times than scripted")
        ev = self.events.pop(0)
        return [(0, ev)]


class FakeSocket:
    """recv() plays scripted results; send() records packets."""

    def __init__(self, recvs):
        self.recvs = list(recvs)
        self.sent = []

    def settimeout(self, t):
        pass

    def connect(self, addr):
        pass

    def send(self, data):
        self.sent.append(data)
        return len(data)

    def recv(self, n):
        if not self.recvs:
            # Old code retries forever on this path.
            raise socket.timeout()
        r = self.recvs.pop(0)
        if isinstance(r, BaseException):
            raise r
        return r


class FakeSelect:
    def __init__(self, poll):
        self._poll = poll

    def poll(self):
        return self._poll

    def __getattr__(self, name):
        return getattr(select, name)


class FakeSocketModule:
    def __init__(self, sock):
        self._sock = sock

    def socket(self, *args, **kwargs):
        return self._sock

    def __getattr__(self, name):
        return getattr(socket, name)


def load_module():
    spec = importlib.util.spec_from_file_location(
        "freebuds_autopause", os.path.join(HERE, "freebuds-autopause.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def frame(cmd, params):
    body = cmd + b"".join(bytes([t, len(v)]) + v for t, v in params)
    pkt = b"Z" + (len(body) + 1).to_bytes(2, "big") + b"\x00" + body
    crc = mod.crc16_xmodem(pkt)
    return pkt + crc


def run_case(recvs, events):
    """Patch socket/select/playerctl in the module, run listen_once bounded."""
    sock = FakeSocket(recvs)
    poll = FakePoll(events)
    calls = []
    mod.socket = FakeSocketModule(sock)
    mod.select = FakeSelect(poll)
    mod.playerctl = calls.append

    box = {}

    def target():
        try:
            mod.listen_once()
            box["ok"] = True
        except BaseException as e:  # noqa: BLE001 - report to main thread
            box["err"] = e

    t = threading.Thread(target=target, daemon=True)
    t.start()
    t.join(BOUND)
    if t.is_alive():
        raise AssertionError(
            "listen_once did not return within %.1fs" % BOUND)
    if "err" in box:
        raise box["err"]
    assert box.get("ok"), "listen_once returned without reaching its end"
    return sock, calls


mod = load_module()


def main():
    # Case 1: POLLHUP with recv timing out, the live bug.
    run_case([], [select.POLLHUP])

    # Case 2: both worn, then one leaves, arriving with POLLHUP.
    sock, calls = run_case(
        [frame(b"\x01\x08", [(2, b"\x00\x5b")]),
         frame(b"\x01\x08", [(2, b"\x00\x5a")])],
        [select.POLLIN, select.POLLIN | select.POLLHUP, select.POLLHUP])
    assert sock.sent, "expected the priming 0108 request to be sent"
    assert calls == ["pause"], f"expected one pause, got {calls}"

    # Case 3: both worn, a 0106 push, then no buds worn, then hangup.
    sock, calls = run_case(
        [frame(b"\x01\x08", [(2, b"\x00\x5b")]),
         frame(b"\x01\x06", []),
         frame(b"\x01\x08", [(2, b"\x00\x58")])],
        [select.POLLIN, select.POLLIN, select.POLLIN, select.POLLHUP])
    assert len(sock.sent) == 2, \
        f"expected prime plus 0108 re-query, got {len(sock.sent)} sends"
    assert calls == ["pause"], f"expected one pause, got {calls}"

    # Case 4: EOF with POLLIN alone must end the call, not poll again.
    run_case([b""], [select.POLLIN])

    print("freebuds-autopause-test: ok")


if __name__ == "__main__":
    main()
