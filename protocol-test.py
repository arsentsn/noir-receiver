#!/usr/bin/env python3
"""Impersonates the phone against a real noir-receiver and asserts what it logs.

Exists because the interesting half of the Cast protocol is the half that *doesn't*
change: every case here is a pairing where one end is older than the other, and the
only correct behaviour is to fall back to the raw v1 stream. Those paths are the ones
a phone-side test can never reach, because the phone always speaks the newest version
it knows.

    ./protocol-test.py            # builds nothing; expects ./noir-receiver to exist

Audio is a 440Hz tone, so a failing case is audible as well as asserted.
"""

import math
import re
import socket
import struct
import subprocess
import sys
import time

PORT = 40561  # not the default: never fight a receiver the user is actually running
ASK_PORT = 40562  # a second receiver, with approval on, for the cases that need it
RATE, CHANNELS = 44100, 2
CAP_CONTROL = 1
AUDIO, FLUSH, VOLUME, NOWPLAYING, ARTWORK, DEVICE, POSITION = 1, 2, 3, 4, 5, 6, 7
# receiver → phone
TRANSPORT, SEEK, STATUS = 1, 2, 3
DECLINED, PENDING, APPROVED, DISCONNECTED = 0, 1, 2, 3


def nowplaying(playing, title, artist, album, year=None):
    """`year=None` appends no year field at all — the exact payload shape a phone that
    predates the field sends, which a current receiver still has to read."""
    out = bytes([1 if playing else 0])
    for text in (title, artist, album):
        b = text.encode()
        out += struct.pack("<H", len(b)) + b
    if year is not None:
        out += struct.pack("<H", year)
    return out


# Smallest thing NSImage will accept as a JPEG, so the artwork path is exercised
# without a binary fixture in the repo.
TINY_JPEG = bytes.fromhex(
    "ffd8ffe000104a46494600010100000100010000ffdb004300ffffffffffffffffffffffffffff"
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    "ffffffffffffffffffffffffffffffffffffffc00011080001000103012200021101031101ffc4"
    "001f0000010501010101010100000000000000000102030405060708090a0bffc400b510000201"
    "0303020403050504040000017d01020300041105122131410613516107227114328191a1082342"
    "b1c11552d1f02433627282090a161718191a25262728292a3435363738393a434445464748494a"
    "535455565758595a636465666768696a737475767778797a838485868788898a92939495969798"
    "999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1"
    "e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9faffda0008010100003f00fbfe8a28a2803fffd9")

failures = []


def wav_header(rate=RATE, channels=CHANNELS, bits=16):
    byte_rate = (rate * channels * bits // 8) & 0xFFFFFFFF  # wraps for the impossible rates
    return (b"RIFF" + struct.pack("<I", 0xFFFFFFFF) + b"WAVEfmt "
            + struct.pack("<IHHIIHH", 16, 1, channels, rate, byte_rate,
                          channels * bits // 8, bits)
            + b"data" + struct.pack("<I", 0xFFFFFFFF))


def tone(ms, freq=440.0, rate=RATE, channels=CHANNELS):
    frames = int(rate * ms / 1000)
    out = bytearray()
    for n in range(frames):
        v = int(20000 * math.sin(2 * math.pi * freq * n / rate))
        out += struct.pack("<" + "h" * channels, *([v] * channels))
    return bytes(out)


def frame(kind, payload=b""):
    return bytes([kind]) + struct.pack("<I", len(payload)) + payload


class Receiver:
    """The receiver under test, with its stderr captured."""

    def __init__(self, port=PORT, extra=()):
        self.port = port
        self.proc = subprocess.Popen(
            ["./noir-receiver", str(port), *extra],
            stderr=subprocess.PIPE, stdout=subprocess.DEVNULL, text=True,
            bufsize=1)
        self.lines = []
        import threading
        threading.Thread(target=self._drain, daemon=True).start()
        time.sleep(1.0)  # let the listener bind

    def _drain(self):
        for line in self.proc.stderr:
            self.lines.append(line.rstrip())

    def connect(self):
        s = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        s.settimeout(2)
        return s

    def since(self, mark):
        return self.lines[mark:]

    def settle(self, quiet=0.4, timeout=8.0):
        """Waits until the log stops growing, then returns.

        Every assertion here used to run after a fixed sleep, which made the whole suite
        hostage to one slow call: `player.start()` opens the audio device on the feed
        thread, and a contended device (another receiver running, a build hogging the CPU)
        has been measured stalling it long enough to swallow *every* line after the WAV
        header — reported as four unrelated failures. Waiting for quiescence turns that
        into a slower pass instead of a false failure."""
        deadline = time.time() + timeout
        last = len(self.lines)
        idle_since = time.time()
        while time.time() < deadline:
            time.sleep(0.05)
            if len(self.lines) != last:
                last = len(self.lines)
                idle_since = time.time()
            elif time.time() - idle_since >= quiet:
                return

    @property
    def mark(self):
        return len(self.lines)

    def stop(self):
        self.proc.terminate()
        self.proc.wait(timeout=5)


def check(name, condition, detail=""):
    if condition:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name} {detail}")
        failures.append(name)


def expect_log(rx, name, lines):
    hit = any(re.search(rx, l) for l in lines)
    check(name, hit, f"— no /{rx}/ in {lines}")


# --- cases ---------------------------------------------------------------

def case_control(r):
    """New phone, new receiver: capability agreed, audio framed, flush + volume land."""
    print("control channel (new ↔ new)")
    mark = r.mark
    s = r.connect()
    s.sendall(b"NOIR" + bytes([1, 0, 0, 0]))
    reply = s.recv(8)
    check("reply is a NOIR preamble", reply[:4] == b"NOIR", f"— got {reply!r}")
    check("receiver offers CONTROL", reply[5] & CAP_CONTROL, f"— caps {reply[5]:#04x}")

    s.sendall(b"NOIR" + bytes([1, CAP_CONTROL, 0, 0]))
    s.sendall(wav_header())
    audio = tone(200)
    for i in range(0, len(audio), 4096):
        s.sendall(frame(AUDIO, audio[i:i + 4096]))
    time.sleep(0.5)
    s.sendall(frame(VOLUME, bytes([40])))
    s.sendall(frame(FLUSH))
    # An unknown type must be skipped, not fatal — audio after it still has to play.
    s.sendall(frame(99, b"whatever this is"))
    for i in range(0, len(audio), 4096):
        s.sendall(frame(AUDIO, audio[i:i + 4096]))
    time.sleep(0.8)
    s.close()
    time.sleep(0.3)

    r.settle()
    lines = r.since(mark)
    expect_log(r"control channel up", "logs 'control channel up'", lines)
    expect_log(r"playing 44100Hz 2ch", "plays 44100Hz 2ch", lines)
    expect_log(r"volume 40%", "applies volume", lines)
    expect_log(r"^flush$|flush", "applies flush", lines)
    expect_log(r"unknown frame type 99", "skips an unknown frame type", lines)
    check("survives the unknown frame", not any("dropping" in l for l in lines),
          f"— {lines}")


def case_metadata(r):
    """nowPlaying and artwork: the frames the popover's mini player reads."""
    print("now playing + artwork")
    mark = r.mark
    s = r.connect()
    s.sendall(b"NOIR" + bytes([1, 0, 0, 0]))
    s.recv(8)
    s.sendall(b"NOIR" + bytes([1, CAP_CONTROL, 0, 0]))
    s.sendall(wav_header())
    s.sendall(frame(NOWPLAYING,
                    nowplaying(True, "Blue Monday", "New Order", "Power", year=1983)))
    s.sendall(frame(ARTWORK, TINY_JPEG))
    time.sleep(0.4)
    # No year field at all: the payload a phone older than the field sends. It has to
    # read as "no year", not as a malformed frame — this is the whole reason the year is
    # appended after the strings rather than spliced in among them.
    s.sendall(frame(NOWPLAYING, nowplaying(True, "Ceremony", "Joy Division", "Still")))
    time.sleep(0.4)
    # A year of 0 is "unknown" on the wire, and must read the same as sending none.
    s.sendall(frame(NOWPLAYING, nowplaying(True, "Atmosphere", "Joy Division", "Substance",
                                           year=0)))
    time.sleep(0.4)
    # Paused, no art: both must be expressible, and an empty artwork payload has to
    # read as "this track has none" rather than "nothing sent yet".
    s.sendall(frame(NOWPLAYING, nowplaying(False, "Untitled", "", "", year=2024)))
    s.sendall(frame(ARTWORK, b""))
    time.sleep(0.4)
    # Truncated: a malformed frame must be reported, not crash the session.
    s.sendall(frame(NOWPLAYING, b"\x01\xff\xff"))
    time.sleep(0.3)
    s.sendall(frame(AUDIO, tone(120)))
    time.sleep(0.6)
    s.close()
    time.sleep(0.3)

    r.settle()
    lines = r.since(mark)
    expect_log(r"now playing: Blue Monday — New Order — Power · 1983 \[playing\]",
               "parses a full track, with the year on the album line", lines)
    expect_log(r"artwork \d+ bytes", "accepts artwork", lines)
    expect_log(r"now playing: Ceremony — Joy Division — Still \[playing\]",
               "reads a payload with no year field (older phone)", lines)
    expect_log(r"now playing: Atmosphere — Joy Division — Substance \[playing\]",
               "treats year 0 as unknown", lines)
    expect_log(r"now playing: Untitled —  \[paused\]", "parses empty fields and paused", lines)
    expect_log(r"artwork 0 bytes", "accepts 'no artwork'", lines)
    expect_log(r"malformed nowPlaying", "reports a truncated frame", lines)
    check("survives the malformed frame", not any("dropping" in l for l in lines),
          f"— {lines}")


def case_device_and_position(r):
    """The frames behind the popover's caption and scrubber."""
    print("device name + position")
    mark = r.mark
    s = r.connect()
    s.sendall(b"NOIR" + bytes([1, 0, 0, 0]))
    s.recv(8)
    s.sendall(b"NOIR" + bytes([1, CAP_CONTROL, 0, 0]))
    s.sendall(wav_header())
    s.sendall(frame(DEVICE, "Sam’s Galaxy".encode()))
    s.sendall(frame(POSITION, struct.pack("<II", 42_000, 215_000)))
    time.sleep(0.4)
    # duration 0 is "no scrubber": an unprepared item, or a length the phone can't know.
    s.sendall(frame(POSITION, struct.pack("<II", 0, 0)))
    # Truncated position must be reported, not read as garbage.
    s.sendall(frame(POSITION, b"\x01\x02"))
    time.sleep(0.4)
    s.sendall(frame(AUDIO, tone(120)))
    time.sleep(0.6)
    s.close()
    time.sleep(0.3)

    r.settle()
    lines = r.since(mark)
    expect_log(r"device: Sam’s Galaxy", "parses a UTF-8 device name", lines)
    expect_log(r"position 42000/215000ms", "parses a position", lines)
    expect_log(r"position 0/0ms", "accepts 'no duration'", lines)
    expect_log(r"malformed position", "reports a truncated position", lines)
    check("survives the malformed frame", not any("dropping" in l for l in lines),
          f"— {lines}")


def case_downlink(r):
    """Receiver → phone frames are well-formed: transport, then seek."""
    print("downlink shape")
    mark = r.mark
    s = r.connect()
    s.sendall(b"NOIR" + bytes([1, 0, 0, 0]))
    reply = s.recv(8)
    check("offers CONTROL so downlink is legal", reply[5] & CAP_CONTROL)
    s.sendall(b"NOIR" + bytes([1, CAP_CONTROL, 0, 0]))
    s.sendall(wav_header())
    s.sendall(frame(AUDIO, tone(100)))
    time.sleep(0.5)
    # Nothing clicks the popover from here, so this asserts only that the receiver
    # sends nothing unbidden — a stray downlink byte would desync the phone's reader.
    s.settimeout(0.8)
    try:
        stray = s.recv(64)
        check("stays quiet unless asked", not stray, f"— sent {stray!r}")
    except socket.timeout:
        check("stays quiet unless asked", True)
    s.close()
    time.sleep(0.3)


def case_v1_phone(r):
    """Old phone (preamble, but ignores the reply): raw stream, no control."""
    print("v1 phone → new receiver (raw fallback)")
    mark = r.mark
    s = r.connect()
    s.sendall(b"NOIR" + bytes([1, 0, 0, 0]))
    s.recv(8)                      # read and ignore, exactly as the v1 phone does
    s.sendall(wav_header())
    # Unframed, and in pieces whose size is NOT a multiple of the 4-byte frame — 1447 is
    # one short of a common segment size. The receiver used to truncate each read to
    # whole frames, which on a boundary like this drops a byte and shifts every later
    # sample; it only ever sounded right because real segment sizes divide by four. The
    # log cannot hear misalignment, so this asserts only that the path survives it — the
    # carry itself is source-verified in `Session.enqueueRaw`.
    audio = tone(300)
    for i in range(0, len(audio), 1447):
        s.sendall(audio[i:i + 1447])
    time.sleep(0.8)
    s.close()
    time.sleep(0.3)

    r.settle()
    lines = r.since(mark)
    expect_log(r"playing 44100Hz 2ch", "plays the raw stream", lines)
    check("does not claim a control channel",
          not any("control channel up" in l for l in lines), f"— {lines}")
    check("survives odd-sized reads", not any("dropping" in l for l in lines), f"— {lines}")


def closed_by_peer(s, timeout=2.0):
    """True if the receiver closed the connection: recv returns EOF within `timeout`."""
    s.settimeout(timeout)
    try:
        return s.recv(16) == b""
    except socket.timeout:
        return False
    except OSError:
        return True


def case_replaced(r):
    """A second connection takes over and the first is closed — not left playing beside it.

    Every cast start used to open two sessions a second apart (the phone's header race), and
    both engines ran; a second *phone* would have done the same for as long as both stayed
    connected. The replaced end is told with a status frame before the FIN, so a phone does
    not read it as a network fault and retry.
    """
    print("newest connection replaces the previous")
    mark = r.mark
    first = r.connect()
    first.sendall(b"NOIR" + bytes([1, 0, 0, 0]))
    first.recv(8)
    first.sendall(b"NOIR" + bytes([1, CAP_CONTROL, 0, 0]))
    first.sendall(wav_header())
    first.sendall(frame(AUDIO, tone(100)))
    time.sleep(0.4)

    second = r.connect()
    second.sendall(b"NOIR" + bytes([1, 0, 0, 0]))
    second.recv(8)
    second.sendall(b"NOIR" + bytes([1, CAP_CONTROL, 0, 0]))
    second.sendall(wav_header())
    second.sendall(frame(AUDIO, tone(100)))
    time.sleep(0.4)

    # The first gets [STATUS][len=1][disconnected=3] and then EOF.
    first.settimeout(2)
    try:
        told = first.recv(6)
    except socket.timeout:
        told = b""
    check("the replaced connection is told 'disconnected'",
          told[:1] == bytes([STATUS]) and told[5:6] == bytes([DISCONNECTED]), f"— got {told!r}")
    check("and then closed", closed_by_peer(first), "— still open after the replacement")
    check("the newer connection stays open", not closed_by_peer(second, timeout=0.5))
    second.close()
    time.sleep(0.3)
    r.settle()
    expect_log(r"replaced by", "logs the replacement", r.since(mark))


def case_v0_phone(r):
    """Pre-preamble sender (bare RIFF), e.g. an old build or a hand-rolled pipe."""
    print("v0 sender (bare RIFF)")
    mark = r.mark
    s = r.connect()
    s.sendall(wav_header())
    s.sendall(tone(300))
    time.sleep(0.8)
    s.close()
    time.sleep(0.3)

    r.settle()
    lines = r.since(mark)
    expect_log(r"playing 44100Hz 2ch", "plays the raw stream", lines)
    check("does not claim a control channel",
          not any("control channel up" in l for l in lines), f"— {lines}")


def case_future_version(r):
    """A phone from the future is refused, not misread."""
    print("future protocol version")
    mark = r.mark
    s = r.connect()
    s.sendall(b"NOIR" + bytes([9, 0, 0, 0]))
    # "Dropping" used to mean the receiver stopped *reading* and left the socket open, so
    # a refused sender sat in the popover as "Streaming from …" until it hung up itself.
    check("and closes the connection", closed_by_peer(s), "— still open after refusing")
    s.close()
    time.sleep(0.3)
    r.settle()
    expect_log(r"tops out at", "refuses a newer sender", r.since(mark))


def case_desync(r):
    """A bogus frame length must kill the session, not the heap."""
    print("desynced frame length")
    mark = r.mark
    s = r.connect()
    s.sendall(b"NOIR" + bytes([1, 0, 0, 0]))
    s.recv(8)
    s.sendall(b"NOIR" + bytes([1, CAP_CONTROL, 0, 0]))
    s.sendall(wav_header())
    s.sendall(bytes([AUDIO]) + struct.pack("<I", 0x7FFFFFFF))
    check("and closes the connection", closed_by_peer(s), "— still open after the desync")
    s.close()
    time.sleep(0.3)
    expect_log(r"desynced", "drops a desynced stream", r.since(mark))


def case_silent_connection(r):
    """A connection that never reaches its WAV header is closed, not held forever.

    Nothing closed one until 2026-10-13: connect and send nothing, and the receiver kept the
    socket and a session for it for as long as the other end liked, as many times over as it
    liked. A real phone reaches its header in ~3.5 s at most; the deadline is 10 s."""
    print("silent connection")
    mark = r.mark
    s = r.connect()
    s.sendall(b"NOIR" + bytes([1, 0, 0, 0]))  # a preamble, then nothing
    s.recv(8)
    check("is closed by the handshake deadline", closed_by_peer(s, timeout=13),
          "— still open 13 s after connecting")
    s.close()
    time.sleep(0.3)
    expect_log(r"no WAV header", "logs why", r.since(mark))


def case_bad_format(r):
    """A header no audio device can open is refused at the parse, not handed to the engine.

    Until 2026-10-20 any rate and channel count went through: a rate of 0 or 4 GHz reached
    `engine.connect`, whose Objective-C exception Swift cannot catch, and 0 channels divided by
    zero on the raw path. The receiver has to refuse each one and still be there afterwards."""
    print("impossible WAV formats")
    for rate, channels in ((0, 2), (4_000_000_000, 2), (44100, 0), (44100, 64)):
        mark = r.mark
        s = r.connect()
        s.sendall(wav_header(rate=rate, channels=channels))
        check(f"closes {rate}Hz {channels}ch", closed_by_peer(s), "— still open")
        s.close()
        time.sleep(0.2)
        r.settle()
        expect_log(r"not a PCM WAV stream", f"refuses {rate}Hz {channels}ch", r.since(mark))
    check("is still running", r.proc.poll() is None, "— the process died")


def framed_session(r):
    """Handshake as a current phone, up to the first frame."""
    s = r.connect()
    s.sendall(b"NOIR" + bytes([1, 0, 0, 0]))
    s.recv(8)
    s.sendall(b"NOIR" + bytes([1, CAP_CONTROL, 0, 0]))
    s.sendall(wav_header())
    return s


def case_hostile_frames(r):
    """What anything on the network can send once it is through the handshake."""
    print("hostile frames")
    mark = r.mark
    s = framed_session(r)
    # A name far past the cap: shown in the Allow prompt and remembered for good, so it is cut.
    s.sendall(frame(DEVICE, ("x" * 5000).encode()))
    # Not a JPEG: NSImage would have parsed this on the main thread; now it is refused.
    s.sendall(frame(ARTWORK, b"\x89PNG\r\n\x1a\n" + bytes(2000)))
    time.sleep(0.4)
    # A flood of empty frames of a type nobody knows: each one used to copy the whole buffer
    # behind it and write a log line. 64 KB of them is ~13k frames.
    flood = frame(99) * (65536 // 5)
    started = time.time()
    for _ in range(8):
        s.sendall(flood)
    s.sendall(frame(AUDIO, tone(120)))
    time.sleep(0.6)
    alive = not closed_by_peer(s, timeout=0.3)
    s.close()
    elapsed = time.time() - started
    r.settle()
    lines = r.since(mark)
    expect_log(r"device: x{64}$", "cuts a long device name to 64 characters", lines)
    expect_log(r"unreadable artwork", "refuses artwork that is not a JPEG", lines)
    expect_log(r"frame log lines suppressed", "rate-limits per-frame log lines", lines)
    check("keeps the session through the flood", alive, "— closed")
    unknown = sum("unknown frame type 99" in l for l in lines)
    check("logs a bounded number of flood lines", unknown <= 40, f"— {unknown} lines")
    check("takes the flood in stride", elapsed < 3, f"— {elapsed:.1f}s")


def case_no_leaks(r):
    """Every case above opened and closed sessions; none of them may outlive its socket.

    Until 2026-10-20 every one did: `ifLive` held its session strongly through the callbacks
    stored on that session, and `leaks` reported a `ROOT CYCLE: <Session>` per connection, each
    holding a player, a read buffer and the last cover. Runs last, so it covers every case."""
    print("leaks")
    time.sleep(1)
    out = subprocess.run(["leaks", str(r.proc.pid)], capture_output=True, text=True).stdout
    summary = next((l for l in out.splitlines() if "leaks for" in l), "")
    if not summary:
        print("  skip  `leaks` could not inspect the process")
        return
    check("no Session outlives its connection", "Session" not in out,
          f"— {summary.strip()}")


def case_connection_cap(r):
    """At most 8 connections hold a session; the next is refused at once.

    Needs approval on (`--ask`): with it off, each connection replaces the last and the count
    never builds. Silent connections are held until the 10 s handshake deadline, which is what
    anything trying to exhaust the receiver would open."""
    print("connection cap (asking receiver)")
    mark = r.mark
    held = [r.connect() for _ in range(8)]
    time.sleep(0.3)
    extra = r.connect()
    check("refuses a ninth connection", closed_by_peer(extra, timeout=1), "— still open")
    extra.close()
    check("keeps the eight", not any(closed_by_peer(s, timeout=0.05) for s in held),
          "— one of them was closed")
    for s in held:
        s.close()
    time.sleep(0.5)
    again = r.connect()
    check("accepts again once they close", not closed_by_peer(again, timeout=0.5),
          "— refused after the eight closed")
    again.close()
    r.settle()
    lines = r.since(mark)
    expect_log(r"8 connections already open; refusing more", "logs the refusal", lines)
    check("logs it once, not per connection",
          sum("refusing more" in l for l in lines) == 1, f"— {lines}")


def case_pending_expiry(r):
    """A request nobody answers is closed after the timeout (2 s here, 60 s in the app), and the
    phone is told 'disconnected' so it does not retry."""
    print("unanswered request expires (asking receiver)")
    mark = r.mark
    s = framed_session(r)
    s.sendall(frame(DEVICE, b"Asker"))
    s.settimeout(1)
    try:
        pending = s.recv(6)
    except socket.timeout:
        pending = b""
    check("is told 'pending'", pending[5:6] == bytes([PENDING]), f"— got {pending!r}")
    s.settimeout(4)
    try:
        told = s.recv(6)
    except socket.timeout:
        told = b""
    check("is told 'disconnected' when the request expires",
          told[:1] == bytes([STATUS]) and told[5:6] == bytes([DISCONNECTED]), f"— got {told!r}")
    check("and then closed", closed_by_peer(s), "— still open after expiry")
    s.close()
    r.settle()
    expect_log(r"Asker was not answered in 2s", "logs the expiry", r.since(mark))


if __name__ == "__main__":
    r = Receiver()
    try:
        for case in (case_control, case_metadata, case_device_and_position,
                     case_downlink, case_v1_phone, case_v0_phone,
                     case_future_version, case_desync, case_replaced,
                     case_silent_connection, case_bad_format, case_hostile_frames,
                     case_no_leaks):
            case(r)
    finally:
        r.stop()

    asking = Receiver(ASK_PORT, ["--ask", "--pending-timeout", "2"])
    try:
        for case in (case_connection_cap, case_pending_expiry):
            case(asking)
    finally:
        asking.stop()

    print()
    if failures:
        print(f"{len(failures)} failed: {', '.join(failures)}")
        sys.exit(1)
    print("all protocol cases passed")
