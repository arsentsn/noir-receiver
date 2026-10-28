// The wire format, both ends of it: constants, frame types, and the parsers for every value the
// phone sends. Nothing here opens a socket or a device — `Session` reads the stream and calls in.
//
// Protocol (see DEVELOPING.md § Protocol):
//   1. 8-byte preamble each way: "NOIR", version byte, three reserved bytes.
//      A stream opening with "RIFF" instead is a pre-versioning sender (v0).
//   2. 44-byte canonical WAV header.
//   3. Raw interleaved s16le frames, forever — or, once both ends agreed CONTROL,
//      `[type][len u32 LE][payload]` frames both ways (`Uplink`, `TransportFrame`,
//      `SeekFrame`, `StatusFrame`).

import Foundation

// Was 5555, which is ADB's own TCP port — a Mac running an Android emulator
// collides with it. Must match DEFAULT_PORT in the phone's PcmStreamer.kt;
// beyond that the number barely matters, since Bonjour advertises whatever
// port the listener actually holds.
public let DefaultPort: UInt16 = 40551

// Highest wire-format version this build understands; a sender announcing more is
// refused rather than misread. The reply's three reserved bytes are where future
// capability bits (control channel, etc.) get announced without a version bump.
let ProtocolVersion: UInt8 = 1

// MARK: - Capabilities

/// Reserved-byte 0, bit 0: "I can frame the stream and talk transport."
///
/// This is the whole reason the v1 preamble reserved three bytes each way. Both ends
/// must set it before anything changes on the wire, so all four combinations work:
/// two new ends negotiate framing, and any pairing involving an old end falls back to
/// the raw-PCM stream that shipped in v1 — no version 2, no flag day.
let CapControl: UInt8 = 1 << 0

/// Frame types, phone → receiver. Only used once CONTROL is agreed.
///
/// New types need no new capability bit: an end that doesn't know one skips it by its
/// length prefix, which is the forward compatibility framing was added for. `nowPlaying`
/// and `artwork` were added exactly that way, against a receiver that predated them.
enum Uplink: UInt8 {
    case audio = 1       // payload: interleaved s16le, exactly what v1 sent unframed
    case flush = 2       // payload: empty — drop scheduled audio, re-prebuffer
    case volume = 3      // payload: one byte, 0...100
    case nowPlaying = 4  // payload: see NowPlaying.parse
    case artwork = 5     // payload: JPEG bytes, or empty for "this track has no art"
    case deviceName = 6  // payload: utf8, the phone's user-visible name
    case position = 7    // payload: [position ms u32 LE][duration ms u32 LE]
    case phoneId = 8     // payload: random bytes, fixed per install; see Session.identify
}

/// Where playback had reached when the phone last said so.
///
/// Held as a sample plus a capture time rather than a live number, because the phone
/// only sends on change — seek, track, play/pause. Everything between is interpolated
/// here. Two quartz clocks drift ~20ppm, about 5ms over a four-minute song, and every
/// track change resyncs, so nothing periodic is needed to keep this honest.
public struct PlaybackPosition: Equatable {
    public let positionMs: Int
    public let durationMs: Int
    public let capturedAt: Date

    /// Milliseconds, advanced to now if the transport is running.
    public func current(playing: Bool) -> Double {
        guard playing else { return Double(positionMs) }
        let elapsed = Date().timeIntervalSince(capturedAt) * 1000
        return min(Double(positionMs) + elapsed, Double(durationMs))
    }

    /// `[position ms u32 LE][duration ms u32 LE]`.
    static func parse(_ d: Data) -> PlaybackPosition? {
        var r = WireReader(d)
        guard let position = r.u32(), let duration = r.u32() else { return nil }
        return PlaybackPosition(positionMs: Int(position), durationMs: Int(duration),
                                capturedAt: Date())
    }
}

/// What the phone's transport is doing, and what it is doing it to.
public struct NowPlaying: Equatable {
    public let playing: Bool
    public let title: String
    public let artist: String
    public let album: String
    /// 0 when the phone did not send one — either it has no year for this track, or it
    /// predates the field.
    public let year: Int

    /// Characters kept of each string the phone sends. Real titles are far shorter; the cap
    /// exists because anything on the network can send one.
    static let maxTextLength = 512

    /// "Album · 2019", or the album alone when there is no year. The phone's own
    /// convention (`TrackTitles.albumLine`), stated once here because both the popover
    /// and the log line want exactly this string — and two copies of it would drift.
    /// Empty when there is no album, so a caller can omit the whole segment.
    public var albumLine: String {
        guard !album.isEmpty else { return "" }
        return year > 0 ? "\(album) · \(year)" : album
    }

    /// `[playing u8]`, three `[len u16 LE][utf8]` strings, then an optional `[year u16 LE]`.
    ///
    /// The year was added after the fact, and reading it as *optional* is what keeps a
    /// phone that predates it working: that phone's payload simply ends after the album,
    /// and trailing bytes were already ignored here, so no capability bit and no version
    /// bump were needed in either direction. Same trick the frame types themselves use.
    static func parse(_ d: Data) -> NowPlaying? {
        var r = WireReader(d)
        guard let playing = r.u8() else { return nil }
        func string() -> String? {
            guard let n = r.u16(), let bytes = r.bytes(Int(n)) else { return nil }
            // Capped after decoding, so a cut never lands inside a character. A title is a line
            // in a 280pt popover, and the u16 length would otherwise let one be 64 KB of text
            // for the marquee to measure.
            return String(data: bytes, encoding: .utf8).map { String($0.prefix(Self.maxTextLength)) }
        }
        guard let title = string(), let artist = string(), let album = string() else {
            return nil
        }
        return NowPlaying(playing: playing != 0, title: title, artist: artist, album: album,
                          year: Int(r.u16() ?? 0))
    }
}

/// Frame types, receiver → phone.
public enum Transport: UInt8 {
    case play = 0, pause = 1, next = 2, previous = 3
}

/// Frame types, receiver → phone.
let TransportFrame: UInt8 = 1
/// Payload: `[position ms u32 LE]`. The phone answers with a flush and a new position.
let SeekFrame: UInt8 = 2
/// Payload: one `ApprovalStatus` byte. Sent only by a receiver that asks before playing,
/// so a phone that predates it never sees one — and skips it by length if it does.
let StatusFrame: UInt8 = 3

/// What the receiver has decided about the phone on the other end of a `StatusFrame`.
///
/// `pending` goes out as soon as the header is parsed while someone still has to click
/// Allow, so the phone can say "waiting" instead of "connected" while its audio is being
/// dropped; `approved` follows the click. `declined` and `disconnected` precede a FIN, and
/// both tell the phone **not to retry** — without them a Deny reads on the phone as a
/// network fault, and it reconnects three times, each one a fresh prompt over here.
public enum ApprovalStatus: UInt8 {
    case declined = 0, pending = 1, approved = 2, disconnected = 3
}

/// `[type][length u32 LE][payload]` — the same shape both directions.
func frame(_ type: UInt8, _ payload: Data = Data()) -> Data {
    var out = Data([type])
    out.appendLE(UInt32(payload.count))
    out.append(payload)
    return out
}

// MARK: - Little-endian values

/// Reads little-endian values off the front of a payload. Every read is bounds-checked and returns
/// nil past the end rather than trapping, so a short payload from anything on the network is a
/// parse failure, never a crash. The one place the wire's byte order is written down for reading;
/// `Data.appendLE` is the other half.
struct WireReader {
    private let data: Data
    /// Where the next read starts. Settable, so a caller that finds a frame incomplete can rewind
    /// to its start and wait for more bytes.
    var offset: Data.Index

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func u8() -> UInt8? { le(UInt8.self) }
    mutating func u16() -> UInt16? { le(UInt16.self) }
    mutating func u32() -> UInt32? { le(UInt32.self) }

    /// The next `count` bytes, as their own `Data` (indexed from zero).
    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return Data(data[offset..<(offset + count)])
    }

    /// Whether the next bytes are `literal`, consuming them if so.
    mutating func expect(_ literal: String) -> Bool {
        let bytes = Array(literal.utf8)
        guard remaining >= bytes.count,
              data[offset..<(offset + bytes.count)].elementsEqual(bytes) else { return false }
        offset += bytes.count
        return true
    }

    private mutating func le<T: FixedWidthInteger>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { return nil }
        var value: T = 0
        for k in 0..<size { value |= T(data[offset + k]) << (8 * k) }
        offset += size
        return value
    }
}

extension Data {
    /// Appends `value` little-endian: the write half of `WireReader`.
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

// MARK: - WAV header

struct WavFormat {
    var sampleRate: Double
    var channels: UInt32

    static let rates: ClosedRange<UInt32> = 8_000...384_000
    static let channels: ClosedRange<UInt16> = 1...8

    /// Parses the 44-byte canonical header: `RIFF` size `WAVE`, then the `fmt ` chunk's id and
    /// size, format, channels, rate, byte rate, block align and bits. Returns nil if it isn't
    /// 16-bit PCM, or is out of range.
    static func parse(_ d: Data) -> WavFormat? {
        var r = WireReader(d)
        guard r.expect("RIFF"), r.u32() != nil, r.expect("WAVE"),
              r.bytes(8) != nil,                       // "fmt " and its chunk size
              let format = r.u16(), let channels = r.u16(), let rate = r.u32(),
              r.bytes(6) != nil,                       // byte rate, block align
              let bits = r.u16() else { return nil }
        guard format == 1 else { return nil }          // PCM only
        guard bits == 16 else { return nil }           // 16-bit only
        // **Range-checked here, because the next stop cannot fail politely.** `AVAudioFormat`
        // accepts a rate of 0 or 4 GHz, and `engine.connect` then raises an Objective-C
        // exception Swift cannot catch: one header from anything on the network ended the
        // process. Zero channels divided by zero on the raw path. The bounds are generous —
        // whatever the phone's audio chain outputs, hi-res and multichannel included.
        guard Self.rates.contains(rate), Self.channels.contains(channels) else { return nil }
        return WavFormat(sampleRate: Double(rate), channels: UInt32(channels))
    }
}
