"""Auto-pause media when a FreeBud leaves the ear, resume when back.

Protocol (reverse-engineered from the FreeBuds 6, model BTFT0020):
- the buds push command 0106 (no params) on any wear-state change;
- reading command 0108 returns a state blob whose param 2 middle byte
  carries per-bud in-ear flags in bits 0 and 1 (observed: 0x5b = both
  worn, 0x5a / 0x59 = one worn, 0x58 = none).
On each 0106 push this daemon reads 0108 and drives playerctl.
Reconnects when the buds drop.
"""
import socket
import subprocess
import time

MAC = "C0:DA:5E:08:D4:4C"
RFCOMM_PORT = 1


def crc16_xmodem(data):
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021 if crc & 0x8000 else crc << 1) & 0xFFFF
    return crc.to_bytes(2, "big")


def read_rq(service, cmd, params=(1,)):
    body = bytes([service, cmd])
    for p in params:
        body += bytes([p, 0])
    pkt = b"Z" + (len(body) + 1).to_bytes(2, "big") + b"\x00" + body
    return pkt + crc16_xmodem(pkt)


def parse_packages(buf):
    """Split concatenated 5a-framed packages.

    Returns (packages, remainder) where packages is a list of
    (cmd, params) and remainder holds a trailing partial frame.
    """
    packages = []
    while len(buf) >= 6:
        if buf[0] != 0x5A:
            # Jump to the next frame start in one slice; dropping one
            # byte per iteration copies the buffer each time (quadratic).
            start = buf.find(b"Z")
            buf = buf[start:] if start != -1 else b""
            continue
        length = int.from_bytes(buf[1:3], "big")
        total = 3 + 1 + length + 1  # header + body(len incl cmd) + crc16
        if len(buf) < total:
            break
        body = buf[4:4 + length - 1]
        buf = buf[total:]
        if len(body) < 2:
            continue
        cmd, rest, params = body[:2], body[2:], {}
        while len(rest) >= 2:
            p_type, p_len = rest[0], rest[1]
            params[p_type] = rest[2:2 + p_len]
            rest = rest[2 + p_len:]
        packages.append((cmd, params))
    return packages, buf


def playerctl(cmd):
    subprocess.run(["playerctl", cmd], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def listen_once():
    s = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_STREAM,
                      socket.BTPROTO_RFCOMM)
    s.settimeout(10)
    s.connect((MAC, RFCOMM_PORT))
    s.settimeout(2)
    worn = None
    buf = b""
    s.send(read_rq(0x01, 0x08))  # prime initial state
    while True:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            return
        buf += chunk
        packages, buf = parse_packages(buf)
        for cmd, params in packages:
            if cmd == b"\x01\x06":  # wear state changed: query details
                s.send(read_rq(0x01, 0x08))
            elif cmd == b"\x01\x08":
                state = params.get(2)
                if not state or len(state) < 2:
                    continue
                now_worn = bin(state[1] & 0x03).count("1")
                if worn is not None and now_worn != worn:
                    playerctl("pause" if now_worn < worn else "play")
                worn = now_worn


def main():
    while True:
        try:
            listen_once()
        except OSError:
            pass
        time.sleep(5)


if __name__ == "__main__":
    main()
