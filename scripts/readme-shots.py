#!/usr/bin/env python3
"""Takes the README's screenshots from the real, running menu bar app.

    ./scripts/readme-shots.py        # writes assets/popover.png and assets/menubar.png

**Why real captures and not the `preview` harness:** offscreen, `ImageRenderer` draws AppKit-backed
controls as yellow no-entry placeholders (see `Preview.measure`), which is fine for measuring
layout and useless for showing anyone the app.

What it does, in order, and puts back:
  1. Backs up the app's preferences, quits it, and marks a made-up phone id as allowed, so no
     Allow prompt gets in the way. The backup is restored at the end, even on failure.
  2. Relaunches it and connects as a phone with a made-up track and a generated cover: no real
     artist or artwork in a public README.
  3. Streams a music-like signal **at volume 0**: the menu bar mark is driven by a tap ahead of the
     mixer, so it dances while the speakers stay silent.
  4. Captures the menu bar item, clicks it open, captures the popover window, and quits.

Needs: the app installed in /Applications, and Screen Recording + Accessibility for the terminal
running this (System Settings asks the first time). It drives the real menu bar for ~15 s.
"""
import math
import os
import random
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

APP = "/Applications/Noir Receiver.app"
DOMAIN = "me.arsentsn.NoirReceiver"
PORT = 40551
HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(os.path.dirname(HERE), "assets")

PHONE_ID = bytes.fromhex("5ee0c0de5ee0c0de5ee0c0de5ee0c0de")
PHONE_NAME = "Pixel 9"
TRACK = ("Night Drive", "Lumen Coast", "Afterglow", 2025)
POSITION_MS, DURATION_MS = 83_000, 224_000

RATE, CHANNELS = 44100, 2
AUDIO, VOLUME, NOWPLAYING, ARTWORK, DEVICE, POSITION, PHONEID = 1, 3, 4, 5, 6, 7, 8
CAP_CONTROL = 1


def run(*cmd, check=True):
    return subprocess.run(cmd, capture_output=True, text=True, check=check).stdout.strip()


def frame(kind, payload=b""):
    return bytes([kind]) + struct.pack("<I", len(payload)) + payload


def nowplaying(playing, title, artist, album, year):
    out = bytes([1 if playing else 0])
    for text in (title, artist, album):
        b = text.encode()
        out += struct.pack("<H", len(b)) + b
    return out + struct.pack("<H", year)


def wav_header():
    return (b"RIFF" + struct.pack("<I", 0xFFFFFFFF) + b"WAVEfmt "
            + struct.pack("<IHHIIHH", 16, 1, CHANNELS, RATE, RATE * CHANNELS * 2, CHANNELS * 2, 16)
            + b"data" + struct.pack("<I", 0xFFFFFFFF))


def cover_jpeg(work):
    """A night-drive gradient with a low sun and the brand's slats across it, 600 px square."""
    n = 600
    px = bytearray()
    for y in range(n):
        for x in range(n):
            t = y / n
            # deep indigo at the top to a warm magenta at the horizon
            r, g, b = 20 + 150 * t ** 2, 14 + 30 * t, 60 + 60 * t
            d = math.hypot(x - n * 0.5, y - n * 0.66) / (n * 0.22)
            if d < 1:
                k = 1 - d ** 2
                r, g, b = r + (255 - r) * k, g + (170 - g) * k * 0.9, b + (110 - b) * k * 0.6
            if y > n * 0.66 and int(y / 9) % 2 == 0:
                r, g, b = r * 0.35, g * 0.35, b * 0.45
            px += bytes((min(255, int(r)), min(255, int(g)), min(255, int(b))))
    ppm = os.path.join(work, "cover.ppm")
    with open(ppm, "wb") as f:
        f.write(b"P6 %d %d 255\n" % (n, n) + bytes(px))
    jpg = os.path.join(work, "cover.jpg")
    run("sips", "-s", "format", "jpeg", ppm, "--out", jpg)
    return open(jpg, "rb").read()


def music(seconds_from, frames):
    """Kick, offbeat hat and a slow chord: enough motion across the bands to make the mark dance."""
    out = bytearray()
    for i in range(frames):
        t = seconds_from + i / RATE
        beat = t % 0.5
        kick = math.sin(2 * math.pi * (50 + 60 * math.exp(-beat * 30)) * beat) * math.exp(-beat * 9)
        hat = (random.random() * 2 - 1) * math.exp(-((t + 0.25) % 0.5) * 60) * 0.4
        chord = sum(math.sin(2 * math.pi * f * t) for f in (220, 277.2, 329.6, 880)) * 0.08
        chord *= 0.6 + 0.4 * math.sin(2 * math.pi * 0.7 * t)
        v = int(max(-1, min(1, kick * 0.8 + hat + chord)) * 26000)
        out += struct.pack("<hh", v, v)
    return bytes(out)


def window_id(pid, work):
    """The popover's CGWindowID, for `screencapture -l` (rounded corners intact).

    The popover is the app's only on-screen window taller than the menu bar; its layer is the
    status item's (25), so the layer cannot tell them apart and height does."""
    src = os.path.join(work, "windows.swift")
    with open(src, "w") as f:
        f.write("""import CoreGraphics
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in info where "\\(w[kCGWindowOwnerPID as String] ?? 0)" == CommandLine.arguments[1] {
    let b = w[kCGWindowBounds as String] as! [String: Double]
    if b["Height"]! > 60 { print(w[kCGWindowNumber as String]!); break }
}
""")
    return run("swift", src, pid, check=False).splitlines()[:1]


def main():
    if not os.path.isdir(APP):
        sys.exit(f"{APP} is not installed")
    os.makedirs(ASSETS, exist_ok=True)
    work = tempfile.mkdtemp(prefix="noir-shots-")
    backup = os.path.join(work, "prefs.plist")
    run("defaults", "export", DOMAIN, backup)
    quit_app()
    try:
        key = "id:" + PHONE_ID.hex()
        run("defaults", "write", DOMAIN, "knownPhones", "-dict-add", key, "-bool", "true")
        run("defaults", "write", DOMAIN, "knownPhoneNames", "-dict-add", key, PHONE_NAME)
        run("open", APP)
        shoot(work)
    finally:
        quit_app()
        run("defaults", "import", DOMAIN, backup)
        run("open", APP)
        print("preferences restored, app relaunched")


def quit_app():
    run("osascript", "-e", f'quit app id "{DOMAIN}"', check=False)
    for _ in range(40):
        if not run("pgrep", "-x", "Noir Receiver", check=False):
            return
        time.sleep(0.1)


def shoot(work):
    art = cover_jpeg(work)
    s = None
    for _ in range(50):
        try:
            s = socket.create_connection(("127.0.0.1", PORT), timeout=1)
            break
        except OSError:
            time.sleep(0.2)
    if s is None:
        sys.exit("the receiver never started listening")
    s.sendall(b"NOIR" + bytes([1, 0, 0, 0]))
    s.recv(8)
    s.sendall(b"NOIR" + bytes([1, CAP_CONTROL, 0, 0]) + wav_header())
    s.sendall(frame(PHONEID, PHONE_ID) + frame(DEVICE, PHONE_NAME.encode()) + frame(VOLUME, b"\x00"))
    s.sendall(frame(NOWPLAYING, nowplaying(True, *TRACK)) + frame(ARTWORK, art)
              + frame(POSITION, struct.pack("<II", POSITION_MS, DURATION_MS)))

    stop = threading.Event()

    def feed():
        sent, chunk, start = 0.0, 0.05, time.time()
        while not stop.is_set():
            s.sendall(frame(AUDIO, music(sent, int(RATE * chunk))))
            sent += chunk
            ahead = sent - (time.time() - start)
            if ahead > 0.3:
                time.sleep(ahead - 0.3)

    threading.Thread(target=feed, daemon=True).start()
    time.sleep(4)  # prebuffer, the dance's fade-in, and the song line's first layout

    item = 'menu bar item 1 of menu bar 2 of process "Noir Receiver"'
    pos = run("osascript", "-e", f'tell application "System Events" to get {{position, size}} of {item}')
    x, y, w, h = (int(float(v)) for v in pos.split(", "))
    pad = 10
    run("screencapture", "-x", f"-R{x - pad},{y},{w + 2 * pad},{h}", os.path.join(ASSETS, "menubar.png"))
    print(f"wrote assets/menubar.png ({w}x{h} pt item)")

    run("osascript", "-e", f'tell application "System Events" to click {item}')
    time.sleep(1.5)
    pid = run("pgrep", "-x", "Noir Receiver")
    wid = window_id(pid, work)
    if not wid:
        sys.exit("no popover window found after the click")
    run("screencapture", "-x", "-o", f"-l{wid[0]}", os.path.join(ASSETS, "popover.png"))
    print("wrote assets/popover.png")
    run("osascript", "-e", f'tell application "System Events" to click {item}')
    stop.set()
    s.close()


if __name__ == "__main__":
    main()
