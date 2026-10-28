# Noir Receiver (macOS)

Plays audio streamed from [Noir Player](https://play.google.com/store/apps/details?id=me.arsentsn.noirplayer)
on your Android phone through your Mac's speakers: lossless 16-bit PCM over your Wi-Fi, with the
song, artwork and play/pause/skip in the menu bar.

Android cannot AirPlay to a Mac, and macOS cannot be a Bluetooth speaker for a phone, so this
small receiver is the missing end. It finds the phone through Bonjour; nothing to configure.

## Install

Needs macOS 13 or later, on any Mac (Apple silicon or Intel).

**The easy way: one line in Terminal.** Open Terminal (press ⌘ Space, type *Terminal*, press
Return), paste this line, press Return:

```sh
curl -fsSL https://raw.githubusercontent.com/arsentsn/noir-receiver/main/install.sh | sh
```

It puts Noir Receiver in your Applications folder and starts it. Run the same line again to update.
Installed this way, macOS does not show its "cannot verify the developer" warning.
([What the script does](install.sh): download, unzip, move to Applications, open.)

**Or download it yourself.** Get
[Noir-Receiver.zip](https://github.com/arsentsn/noir-receiver/releases/latest/download/Noir-Receiver.zip),
open it, and drag **Noir Receiver** into Applications. The first time you open it, macOS refuses,
because the app is not signed with a paid Apple developer account. Click **Done**, then open
**System Settings → Privacy & Security**, scroll down, and click **Open Anyway**. You only do this
once (and again after each manual update).

**Then:**
1. When macOS asks whether Noir Receiver may find devices on your local network, click **Allow**.
2. On your phone, in Noir Player, turn on **Settings → Stream to Noir Receiver** (search "receiver").
3. Open the player's output picker and choose your Mac. The first time, your Mac asks you to
   **Allow** the phone, from the menu bar.

To start it with your Mac, open its settings from the gear in its menu bar popover and turn on
**Start at login**.

**Uninstall:** quit it from its menu bar popover and drag it from Applications to the Trash.

**From source**, for developers: needs the Xcode command-line tools (`xcode-select --install`).

```sh
git clone https://github.com/arsentsn/noir-receiver.git
cd noir-receiver && ./build.sh app && open "Noir Receiver.app"
```

**Releasing:** bump `ReceiverVersion` in `Receiver.swift`, then push a tag `v` + that version;
`.github/workflows/release.yml` builds the universal, ad-hoc signed app and attaches
`Noir-Receiver.zip`, the name `install.sh` and the link above fetch. MIT licensed.

## Build and run

```sh
./build.sh                 # both targets: CLI + menu bar app
./noir-receiver            # CLI, listens on 40551 (or: ./noir-receiver 5600)
./noir-receiver --version  # prints the version the bundle, the CLI and Settings all share
./noir-receiver 5600 --ask --pending-timeout 2   # approval on, never answered: what the tests use
open "Noir Receiver.app"   # menu bar: now playing, transport, scrubber, settings
./build.sh preview && ./preview   # measure the popover and settings window offscreen, drive pairing
./build.sh check && ./eq-check     # the mark's analyser against known signals — no phone, no audio device
./build.sh app universal   # arm64 + x86_64 in one binary: what a release ships
./check.sh                 # every target, then eq-check, protocol-test.py and preview: before a commit
```

**Every target is compiled with `-target <arch>-apple-macos13.0`**, and `MIN_OS` in `build.sh`
is the one place that number is written — it also fills the bundle's `LSMinimumSystemVersion`.
Without the flag swiftc checks API availability against the Mac doing the building, which is
how the plist said 13.0 for weeks while the settings window used a macOS 14 `onChange` and
nothing objected until 2026-09-04. A source build compiles on the *user's* Mac, so that is where
such an error would have surfaced. The version is `ReceiverVersion` in `Receiver.swift`,
read by `build.sh` into the plist, printed by `--version`, shown at the foot of Settings.

The menu-bar mark dances to the audio this Mac is emitting: `EqAnalyser.swift` is a band analyser
fed from a tap on the *player node*, so what it reads is what leaves the speaker rather than what
was scheduled a few hundred milliseconds ago. **Five bands, the same as the phone**, since the
menu-bar mark moved to the caption cut on 2026-09-02 — every constant that follows from the band
count is derived, and the count itself is taken from the mark's slat array, so the two ports share
the formulae and a change to either count lands on the analyser without a second edit. `./eq-check`
asserts the parts a port breaks silently: the band count against the slat count, that the Q still
tiles, that bass drives the bottom slat, and that silence rests rather than dancing.

The files, by what they are:

- **The core**, UI-agnostic: `Protocol.swift` (the wire format), `Session.swift` (one
  connection), `Player.swift` (audio out), `Receiver.swift` (the listener and the live phone).
- **The app**: `NoirReceiverApp.swift` (the status item and its delegate), `Preferences.swift`,
  `ReceiverMenu.swift` (the popover), `SettingsView.swift`, `MenuBarItem.swift` (the song and
  the line beside the mark).
- **The mark**: `BlindsGlyph.swift`, `BlindsEqMark.swift`, `EqAnalyser.swift`.
- **Four entry points**, each a bare `@main` in its own file so the others compile against the
  same real sources: `NoirReceiverCLI.swift`, `NoirReceiverMain.swift` (the app), `Preview.swift`
  (the layout and pairing harness) and `EqAnalyserCheck.swift` (the analyser's assertions).

No dependencies — AVFoundation, Network, MediaPlayer and SwiftUI are part of macOS (13+ for the
app). The bundle is assembled by `build.sh`, no Xcode project, and ad-hoc signed (free, no Apple
account; not a Developer ID). Gatekeeper only checks files carrying the quarantine flag that
browsers attach. A local build and a copy fetched by `install.sh` (curl) carry none, so they open
straight away; a browser download is blocked on first open, and on macOS 15 and later
right-click → Open no longer gets past that, hence the Open Anyway steps under *Install*.

The bundle declares `NSLocalNetworkUsageDescription` and `NSBonjourServices` (`_noirplayer._tcp`),
for the Local Network permission macOS 15 asks for before an app can be found on the network.

The popover holds only what is playing and the controls for it — transport, scrubber, and a
**Disconnect** link while a phone is connected, because Pause leaves the phone attached and Quit
takes the receiver with it, and neither was "stop that phone" for someone across the room from
it. Everything you set once — buffer, port, pairing, animation, start at login — is in a
settings **window**, reachable from the popover's gear. It is a window rather than a panel because
the popover is `.transient` and used to throw away a half-typed port number on any stray click.

**Animation** is on by default: the menu bar mark dances while sound is coming out, and a title
too long for the popover scrolls. Turning it off leaves both still — the mark rests on the logo
and keeps its dot badge, so "connected" is still readable — and costs nothing while off: no
timer, and no power assertion. The system's Reduce Motion setting is honoured regardless of this
switch.

`./preview` measures both surfaces offscreen and fails if either is wider than it should be. That
single number is what catches a child view leaking its intrinsic width up the tree, which is
invisible in review and, in the popover's case, clipped every row on both edges before anyone
noticed. It also drives the mark's engine through the animation switch and counts frames, because
the two failures there are equally invisible: a timer that never stops (60fps and a sleep
assertion, forever) and a fade that snaps. And since 2026-09-04 it drives **pairing** end to end —
see below — because that path has no other instrument: the CLI never asks, and the real app needs
a human at the popover.

## Pairing: a new phone has to be allowed

Anyone on the same network could otherwise play audio through this Mac and push titles and
JPEGs at the popover — fine at home, not in a dorm or an office, and this app is heading for a
public download. So, **on by default in the app** (off in the core, so the CLI and every harness
behave as before): the first time a phone this Mac has not seen connects, the popover opens with
*"Sam's Galaxy wants to play on this Mac"* and Allow / Deny. The answer is remembered by the
phone's **per-install id** (frame type 8, sent ahead of its name), and only for a phone that
never sends one (every v1 build) by its name, or its host address when it sends neither. The
name alone was the key until 2026-10-13, and it is the phone's own `device_name`, which defaults
to the model: an Allow for one "Galaxy S25" let in every stranger with the same model. The id
crosses the LAN in the clear, so it stops a collision or a guess, not someone sniffing this
network. Answering a phone that sent an id drops any name-keyed entry for the same name. Settings
lists remembered phones by name as Allowed or Blocked with a Forget link, and a switch turns the
asking off altogether. Turning it off while a phone is waiting allows it.

A connection that has not reached its WAV header 10 s after connecting is closed (a phone needs
about 3.5 s at most). Nothing used to close one that connected and sent nothing.

While it waits, its audio is dropped and no audio engine is built — the phone stays the clock, so
allowing it joins the song live — but its name, song, art and position are kept, which is how the
popover can name who is asking and is already populated the moment the answer is yes. A blocked
phone is closed the instant it identifies itself, with a log line, so its three reconnect attempts
are three log lines and not three prompts. One request at a time: a second stranger arriving
while one waits is closed rather than queued.

**The phone is told**, over the control channel, so it can say "Waiting for the Mac to allow this
phone…" instead of "connected" and — after a Deny — "The Mac declined this phone" instead of
"connection lost", **and not retry**. That is frame type 3 in the table below, and it is the whole
reason a denial does not turn into three more prompts.

**One phone plays at a time, and the newest connection wins.** A second connection used to get a
second engine: both played, both taps fed the one analyser, and the popover showed whichever wrote
last. Now the previous session is told it was disconnected and closed. Not hypothetical — every
cast start used to open two sessions a second apart (the phone's header race, fixed on its side
the same day), so two engines ran for that second on every start.

It advertises itself over Bonjour as `_noirplayer._tcp`, so the phone finds it
without you typing an IP. In Noir Player: **Settings → Experimental → Stream to
a computer** on, then the cast button in the full-screen player, then pick your Mac.

The TXT record carries `v` (the protocol version) and `kind` — `laptop` or
`desktop`, which is the icon the phone's picker draws. **`kind` is decided by
whether there is an internal battery**, not by the model string: on Apple Silicon
`hw.model` reads `Mac16,1`, naming no product line at all, so a model table would
need a row per machine and be wrong for each until someone noticed.

The record must also never be *empty*. Set none and Network.framework publishes an
empty TXT anyway, which Android's `NsdService` reads as an attribute with a blank
key and throws `IllegalArgumentException: Key cannot be empty` on **every** resolve
— caught by the framework, so the resolve still succeeds and neither end looks
broken. It was there from the first Bonjour registration and was found on
2026-08-28 only by reading `logcat` for something else.

Being *bound* and being *findable* are tracked separately (`listening` and
`discoverability`), because they came apart in practice: a Mac that slept on one Wi-Fi
network and woke on another kept a healthy socket and a Bonjour registration made five
days earlier, which the phone could not see at all. A network change now re-registers
the service — watch for `re-advertising` in the log. Audio playing through a live
session survives it.

When Bonjour has not registered us 15s after the socket bound, the popover says so ("the
phone can't see this Mac", in orange) instead of the reassuring "Waiting for Noir
Player", and the menu bar tooltip matches. `discoverability` has three states rather
than two on purpose — `registering` covers the couple of seconds every launch spends
bound but not yet announced, which is not a fault and must not be drawn as one.

## The output device

The stream plays through **the system default output**, as every other app does — the Mac's own
Sound setting decides. A per-app picker was built and removed on 2026-09-05: the receiver's job is
the Mac's speakers, and anything else would be paired with the phone directly.

**The engine stops when the output hardware changes**, and macOS says so with
`AVAudioEngineConfigurationChange` — plugging in headphones, a display with speakers, a sample
rate change in Audio MIDI Setup. What it does not do is start again. Until 2026-09-04 nothing
here did either, so switching output mid-stream was silence until the phone reconnected, and not
even the 30s idle release could save it: buffers scheduled on a stopped engine never complete, so
the player counted itself audible for good. The engine is now released on that notification and
rebuilt on the next chunk — one prebuffer refill, on the new device. **Unverified on hardware**:
this Mac has one output device, so the notification has not been provoked here. Plug headphones in
mid-stream and look for `output device changed; re-opening on the next chunk` in the log.

Nothing is playing and the phone is still connected? The output device is handed back
after 30s of silence and re-opened (~33ms) when audio resumes, because holding it also
holds a `PreventUserIdleSystemSleep` assertion — a paused phone used to keep the Mac
awake for as long as it stayed connected. `pmset -g assertions` shows who is holding
what.

## The menu bar item

Settings › **Menu bar** chooses what sits in the menu bar: **Icon** (the mark alone, as it always
was) or **Song** (the mark, then "Title · Artist", up to 160pt). **Show how far into the song**
adds a thin progress line, under the mark or under the song. All of it is one template image
(`MenuBarItem.swift`), so the menu bar colours it like any other item.

A title too long for its space scrolls **one pass**, never on a loop: when the song starts, and
again when the item is hovered or clicked. Between passes it sits at its start with an ellipsis;
with Animation on Still, or Reduce Motion, it never moves. A pass rides the mark's frames when
the mark is moving (no extra image swaps, and the swap is what costs, see `EqEngine`) and its
own 60 fps timer only for the few seconds it lasts otherwise. The line alone, with the mark
still, redraws once a second. `./preview`
writes `menubar.png` with every shape on the light and dark bar.

## Logs

Both targets log to `os_log`, and the CLI additionally to stderr. A bundle launched from
Finder has no stderr, so the unified log is the only trail the menu bar app leaves:

```sh
/usr/bin/log show --predicate 'subsystem == "me.arsentsn.NoirReceiver"' --last 1h
/usr/bin/log stream --predicate 'subsystem == "me.arsentsn.NoirReceiver"'    # live
```

Spell out `/usr/bin/log`: zsh has a `log` builtin that shadows it and fails with "too
many arguments", which looks identical to an empty log.

Song titles are logged as private, so the unified log shows `<private>` where the CLI's stderr
shows the track: macOS keeps that log on disk for days, and it should not hold a listening
history. Everything else (connections, formats, device names) is public.

## Protocol

Deliberately trivial, because both ends are ours:

**Everything on the wire is untrusted**, because anything on the network can connect. The
receiver refuses a WAV header outside 8000–384000 Hz or 1–8 channels, caps a frame at 1 MB,
cuts a device name to 64 characters and each now-playing string to 512, takes artwork only as
a JPEG of at most 8192 px a side (decoded once, off the main thread, to a 256 px thumbnail),
rate-limits per-frame log lines to 20 a second, holds at most 8 connections, and closes an
unanswered Allow request after 60 s. `./protocol-test.py` asserts each of these (the cap and
the expiry against a second receiver run with `--ask`), and that `leaks` finds no session
outliving its connection.

1. An 8-byte preamble: `NOIR`, one protocol-version byte (currently 1), three
   reserved bytes. The receiver replies with the same 8-byte shape — its own
   version, its capability bits in the reserved bytes. A version above the
   receiver's own is refused with a log line rather than misread — and the connection
   is closed, which it was not until 2026-09-04: the session went dead and the socket
   stayed open, so a refused sender sat in the popover as "Streaming from …" until it
   hung up itself. Same for a desynced frame length and a stream that is not PCM WAV.
2. Bit 0 of reserved byte 0 is `CONTROL`. If the receiver offers it and the phone
   wants it, the phone answers with a preamble of its own setting the same bit.
   Both ends must set it, so every mixed-age pairing falls back to the plain
   stream below — that is what lets the control channel ship without a version 2.
3. A 44-byte canonical WAV header (16-bit PCM, sample rate and channel count as
   sent by the phone, `0xFFFFFFFF` sizes since the length is unknown).
4. Then the audio. Without `CONTROL`: raw interleaved signed 16-bit little-endian
   frames, forever — and a TCP read can end anywhere, including mid-sample, so the
   receiver carries the remainder to the next read rather than truncating (it truncated
   until 2026-09-04, which only ever sounded right because common segment sizes divide
   by four). With it: messages of `[type][length u32 LE][payload]` —

   | Type | Payload |
   |---|---|
   | 1 `audio` | that same interleaved s16le PCM |
   | 2 `flush` | empty — drop scheduled audio, the phone seeked |
   | 3 `volume` | one byte, 0-100 |
   | 4 `nowPlaying` | `[playing u8]` + three `[len u16 LE][utf8]`: title, artist, album — then, optionally, `[year u16 LE]` (0 = unknown) |
   | 5 `artwork` | JPEG bytes, or empty for "this track has no cover" |
   | 6 `deviceName` | utf8 — the phone's own name, so this end needn't show an IP |
   | 7 `position` | `[position ms u32 LE][duration ms u32 LE]`; duration 0 means "no scrubber" |
   | 8 `phoneId` | random bytes (16 today), fixed per install; sent before `deviceName`, and what pairing remembers |

   Back the other way, receiver → phone: type 1 `transport` (one byte, 0 play /
   1 pause / 2 next / 3 previous), type 2 `seek` (`[position ms u32 LE]`), and type 3
   `status` (one byte: 0 declined / 1 pending / 2 approved / 3 disconnected — see
   *Pairing*; sent only by a receiver that asks, so an older phone never sees one and
   skips it by length if it does. `declined` and `disconnected` precede the FIN and mean
   *do not retry*).

   `position` is sent only on change — seek, track change, play/pause — and this end
   interpolates between samples. Two quartz clocks drift about 5ms over a four-minute
   song and every track change resyncs, so nothing periodic is needed.

   **Unknown types are skipped**, which is why audio is framed at all — types 4 and 5
   were added after the fact and needed no new capability bit and no version bump.

   The same trick works *within* a frame, and `nowPlaying`'s year is the example: the
   receiver reads its three strings and ignores whatever follows, so appending a field
   is safe in both directions — an older receiver drops the year, and a newer one reads
   0 from an older phone that never sends it. Append; never splice.

A stream that opens with `RIFF` instead of `NOIR` is a pre-versioning sender,
accepted as version 0 with no reply.

That means `nc` and `ffplay` still work as a debugging receiver with no code —
`tail` strips the preamble, and a sender that gets no reply stays on the raw
stream (after a 500ms wait for one):

```sh
nc -l 40551 | tail -c +9 | ffplay -nodisp -autoexit -i -
```

`./protocol-test.py` drives a real `./noir-receiver` through all of the above —
every handshake pairing, a desynced length, an unknown frame type, odd-sized raw reads,
a refused sender being closed, and a second connection replacing the first.

The phone always sends 44100Hz stereo — `PlaybackService` pins the format with a
channel mixer and a resampler ahead of the tap, because the header is sent once
and the receiver can't follow a mid-stream format change. (Until 2026-09-04 the header
carried the *previous* chain's native rate on every cast start and the pinned chain's
first flush read as exactly that change; `PcmStreamer.awaitFormat` is the fix.)

## Latency

Set by the **Buffer** slider in Settings, in milliseconds: that much audio is queued before
playback starts, 200 by default. Lower it for snappier pause, raise it if a weak Wi-Fi link
causes dropouts. It applies to the next connection. (It counted *chunks* until 2026-09-04,
which was the phone's buffer size in disguise — about 46 ms each — and meant nothing on a
label; an existing setting is converted once.)

Seeking and skipping no longer pay that buffer twice — the phone sends a flush and
this end drops what it had scheduled. Pause still trails by the buffer depth, on
purpose: that audio is correct, just late, and dropping it would lose it.

It publishes to `MPNowPlayingInfoCenter` and registers `MPRemoteCommandCenter` handlers,
which is what should make macOS treat it as a real music app — F7/F8/F9 media keys, and
the song in Control Center's Now Playing card with a working scrubber. All of it rides
the frames above, so the system integration is a consequence of the metadata rather than
extra plumbing.

Verified 2026-08-07: F8 paused and resumed a phone-side stream. `Session.send` logs
`sending …`, which is the way to tell "the key never reached us" from "we sent it and
the phone ignored it".

## Not done yet

- Nothing is shown about the *queue* — one song at a time, no next-up. A larger idea sits
  behind it (2026-09-04): a second popover mode that browses the whole library, with today's
  mini player as the "simple" one. Designed, not built.
- Two phones cannot *share* this Mac: the newest connection wins and the other is told.
  Picking between them from here would need the popover to list both.

(The phone reconnects on its own since 2026-08-07 if this receiver goes away
mid-stream — three attempts with backoff, then it gives up visibly. A session the Mac ends
on purpose — Deny, Disconnect, being replaced — says so with a status frame and is not retried.)
