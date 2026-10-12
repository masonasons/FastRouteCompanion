#!/usr/bin/env python3
"""
A stand-in for a FastRoute PC, for trying the Mac app without Windows.

    fake_fastroute.py send [--name Stream1] [--group 239.255.77.21 | --host 192.168.1.5 | --wait]
                           [--port 6982] [--codec pcm16|pcm24|f32] [--ms 10] [--seconds 10]
        Announces itself on the beacon group twice a second and streams a
        440 Hz tone, to a multicast group, to one host, or to whoever asks.

    fake_fastroute.py receive --host <mac> [--port 6982] [--name ""] [--seconds 10]
        Asks a sender on the Mac for its audio once a second, the way a
        FastRoute Net Receive block does, and reports what arrives.

    fake_fastroute.py receive --passive [--port 6982] [--seconds 10]
        Just listens on the port, like a FastRoute Net Receive block that
        was given no address: joins the usual group and takes anything
        pushed at it.

    fake_fastroute.py listen [--seconds 10]
        Prints the beacons heard on 239.255.77.20:6981.

Only the FastRoute protocol is covered; VBAN is served by VoiceMeeter and
the VBAN apps themselves.
"""

import argparse
import math
import socket
import struct
import sys
import time

BEACON_GROUP = "239.255.77.20"
BEACON_PORT = 6981
DEFAULT_GROUP = "239.255.77.21"
DEFAULT_PORT = 6982
RATE = 48000
CODECS = {"pcm16": 0, "pcm24": 1, "f32": 2}


def ascii32(s):
    b = bytes(c if 0x20 <= c <= 0x7E else 0x3F for c in s.encode("ascii", "replace"))
    return b[:32].ljust(32, b"\0")


def beacon(codec, stream_id, group, port, frames, rate, name, host):
    return (b"FRNB" + struct.pack("<BBBB", 1, codec, 2, 0)
            + struct.pack("<IIHHI", stream_id, group, port, frames, rate)
            + ascii32(name) + ascii32(host) + b"\0" * 8)


def parse_beacon(d):
    if len(d) < 96 or d[:4] != b"FRNB" or d[4] != 1:
        return None
    codec, ch = d[5], d[6]
    stream_id, group, port, frames, rate = struct.unpack_from("<IIHHI", d, 8)
    name = d[24:56].split(b"\0")[0].decode("ascii", "replace")
    host = d[56:88].split(b"\0")[0].decode("ascii", "replace")
    return dict(codec=codec, channels=ch, stream_id=stream_id, group=group, port=port,
                frames=frames, rate=rate, name=name, host=host)


def data_packet(codec, rate, stream_id, seq, pos, frames, payload):
    return (b"FRND" + struct.pack("<BBBB", 1, codec, 2, 0)
            + struct.pack("<IIIQHH", rate, stream_id, seq, pos, frames, len(payload)) + payload)


def parse_data(d):
    if len(d) < 32 or d[:4] != b"FRND" or d[4] != 1:
        return None
    rate, stream_id, seq, pos, frames, length = struct.unpack_from("<IIIQHH", d, 8)
    return dict(codec=d[5], channels=d[6], rate=rate, stream_id=stream_id, seq=seq, pos=pos,
                frames=frames, payload=d[32:32 + length])


def subscribe(stream_id, name, wants_beacon=True):
    return b"FRNS" + struct.pack("<BBH", 1, 1 if wants_beacon else 0, 0) + struct.pack("<I", stream_id) + ascii32(name) + b"\0" * 4


def parse_subscribe(d):
    if len(d) < 48 or d[:4] != b"FRNS" or d[4] != 1:
        return None
    return dict(wants_beacon=d[5] != 0, stream_id=struct.unpack_from("<I", d, 8)[0],
                name=d[12:44].split(b"\0")[0].decode("ascii", "replace"))


def ip_int(s):
    return struct.unpack("!I", socket.inet_aton(s))[0]


def tone_payload(codec, frames, pos):
    out = bytearray()
    for i in range(frames):
        t = (pos + i) / RATE
        l = 0.3 * math.sin(2 * math.pi * 440 * t)
        r = 0.3 * math.sin(2 * math.pi * 660 * t)
        for v in (l, r):
            if codec == 0:
                out += struct.pack("<h", int(v * 32767))
            elif codec == 1:
                out += struct.pack("<i", int(v * 8388607))[:3]
            else:
                out += struct.pack("<f", v)
    return bytes(out)


def cmd_send(a):
    codec = CODECS[a.codec]
    bytes_per_frame = {0: 4, 1: 6, 2: 8}[codec]
    frames = min(int(RATE * a.ms / 1000), (1400 - 32) // bytes_per_frame)
    stream_id = 0x1234ABCD
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    sock.bind(("", a.port))
    sock.setblocking(False)
    group = 0
    dest = None
    if a.wait:
        mode = "waiting for receivers to ask on port %d" % a.port
    elif a.host:
        dest = (socket.gethostbyname(a.host), a.port)
        mode = "to %s:%d" % dest
    else:
        group = ip_int(a.group)
        dest = (a.group, a.port)
        mode = "to the group %s:%d" % dest
    print("sending %s, %s, %d frames a packet" % (a.name, mode, frames))
    subscribers = {}
    seq = pos = 0
    start = time.time()
    last_beacon = 0
    interval = frames / RATE
    while time.time() - start < a.seconds:
        now = time.time()
        if now - last_beacon >= 0.5:
            last_beacon = now
            b = beacon(codec, stream_id, group, a.port, frames, RATE, a.name, socket.gethostname())
            sock.sendto(b, (BEACON_GROUP, BEACON_PORT))
        while True:
            try:
                d, addr = sock.recvfrom(2048)
            except BlockingIOError:
                break
            s = parse_subscribe(d)
            if s and (s["stream_id"] in (0, stream_id)) and s["name"] in ("", a.name):
                if addr not in subscribers:
                    print("subscriber", addr)
                subscribers[addr] = now
                if s["wants_beacon"]:
                    sock.sendto(beacon(codec, stream_id, group, a.port, frames, RATE, a.name, socket.gethostname()), addr)
        for addr, seen in list(subscribers.items()):
            if now - seen > 6:
                print("subscriber gone", addr)
                del subscribers[addr]
        due = int((now - start) / interval)
        while seq < due:
            pkt = data_packet(codec, RATE, stream_id, seq, pos, frames, tone_payload(codec, frames, pos))
            targets = [dest] if dest else list(subscribers.keys())
            for t in targets:
                sock.sendto(pkt, t)
            seq += 1
            pos += frames
        time.sleep(0.002)
    print("sent %d packets" % seq)


def cmd_receive(a):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.settimeout(0.2)
    if a.passive:
        sock.bind(("", a.port))
        mreq = struct.pack("4sl", socket.inet_aton(DEFAULT_GROUP), socket.INADDR_ANY)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
        dest = None
        print("listening on port %d and on the group %s" % (a.port, DEFAULT_GROUP))
    else:
        if not a.host:
            sys.exit("receive needs --host, or --passive")
        sock.bind(("", 0))
        dest = (socket.gethostbyname(a.host), a.port)
        print("asking %s:%d for %s" % (dest[0], dest[1], a.name or "whatever it has"))
    start = time.time()
    last_ask = 0
    expected = None
    got = lost = 0
    codec = None
    while time.time() - start < a.seconds:
        if dest and time.time() - last_ask >= 1:
            last_ask = time.time()
            sock.sendto(subscribe(0, a.name), dest)
        try:
            d, addr = sock.recvfrom(4096)
        except socket.timeout:
            continue
        b = parse_beacon(d)
        if b:
            print("sender answered:", b)
            continue
        p = parse_data(d)
        if p:
            if codec != p["codec"]:
                codec = p["codec"]
                print("data: codec %d rate %d frames %d bytes %d" % (p["codec"], p["rate"], p["frames"], len(p["payload"])))
            if expected is not None and p["seq"] != expected:
                lost += (p["seq"] - expected) & 0xFFFFFFFF
            expected = (p["seq"] + 1) & 0xFFFFFFFF
            got += 1
    print("received %d packets, %d missing" % (got, lost))


def cmd_listen(a):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(("", BEACON_PORT))
    mreq = struct.pack("4sl", socket.inet_aton(BEACON_GROUP), socket.INADDR_ANY)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    sock.settimeout(0.5)
    seen = set()
    start = time.time()
    while time.time() - start < a.seconds:
        try:
            d, addr = sock.recvfrom(2048)
        except socket.timeout:
            continue
        b = parse_beacon(d)
        if b and (addr[0], b["stream_id"]) not in seen:
            seen.add((addr[0], b["stream_id"]))
            print(addr[0], b)
    print("%d senders heard" % len(seen))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("send")
    s.add_argument("--name", default="Stream1")
    s.add_argument("--group", default=DEFAULT_GROUP)
    s.add_argument("--host")
    s.add_argument("--wait", action="store_true")
    s.add_argument("--port", type=int, default=DEFAULT_PORT)
    s.add_argument("--codec", choices=CODECS, default="pcm16")
    s.add_argument("--ms", type=float, default=10)
    s.add_argument("--seconds", type=float, default=10)
    r = sub.add_parser("receive")
    r.add_argument("--host")
    r.add_argument("--passive", action="store_true")
    r.add_argument("--port", type=int, default=DEFAULT_PORT)
    r.add_argument("--name", default="")
    r.add_argument("--seconds", type=float, default=10)
    l = sub.add_parser("listen")
    l.add_argument("--seconds", type=float, default=10)
    a = ap.parse_args()
    {"send": cmd_send, "receive": cmd_receive, "listen": cmd_listen}[a.cmd](a)


if __name__ == "__main__":
    main()
