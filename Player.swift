// Audio out: interleaved 16-bit PCM in, the Mac's default output device out. Owned by one
// `Session`; knows nothing of the network.

import Accelerate
import AVFoundation
import Foundation

// MARK: - Player

/// Wraps AVAudioEngine: feed it interleaved int16 and it plays.
final class Player {
    /// Built on demand and released again after a stretch of silence — see
    /// `idleTeardownDelay`. Nil means "no output device open right now", which is a
    /// state this has to be able to reach while a phone is still connected.
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    /// Frames scheduled and not yet played out. The prebuffer and `audible` both read this
    /// rather than a *buffer count*, because a buffer is whatever size the sender or the
    /// network handed over — 100 ms from the phone, anything at all on the raw path, where
    /// one buffer is one TCP read — so "4 chunks" measured nothing in particular and the
    /// settings slider could not honestly be labelled.
    private var pendingFrames = 0
    private var started = false
    private let lock = NSLock()
    /// How much audio is queued before playback starts. Milliseconds, converted to frames
    /// once the format is known — the one number a user can reason about.
    private let prebufferMs: Int
    private var prebufferFrames = 1

    /// How long silence has to last before the output device is handed back.
    ///
    /// `engine.stop()` does not release it: the AUHAL stays instantiated for the life
    /// of the `AVAudioEngine`, and coreaudiod holds a `PreventUserIdleSystemSleep`
    /// assertion for as long as any client has the device open. So a phone that
    /// stayed connected but paused kept this Mac from ever idle-sleeping on its own —
    /// measured at 5d 8h 52m 53s, the receiver's lifetime to the second. Releasing
    /// the engine is what drops the assertion; stopping it is not.
    ///
    /// 30s because the phone's writes are bursty enough to go quiet for several
    /// seconds mid-song (the same reason `audible` is derived from scheduled audio
    /// rather than data arrival). Waking back up costs a rebuild and one prebuffer
    /// refill, which is exactly what a seek already costs.
    private static let idleTeardownDelay: TimeInterval = 30

    private let idleQueue = DispatchQueue(label: "me.arsentsn.NoirReceiver.player.idle")
    /// Bumped to invalidate a pending teardown. A token beats holding the work item
    /// because the fire can be waiting on `lock` at the moment audio resumes, so
    /// "is this still the teardown I armed?" has to be asked *inside* the lock.
    private var idleToken: UInt64 = 0

    /// Set by the owning session, so a device release shows up in the log rather than
    /// being a silent change in what the Mac's power state is allowed to do.
    var log: ((String) -> Void)?
    /// Bumped by `flush()`. Buffers scheduled before the bump carry the old value, so
    /// the completion handlers `node.stop()` fires for the audio we just discarded
    /// cannot decrement the new generation's `pendingFrames` count.
    private var generation: UInt64 = 0
    /// Applied to the mixer once the engine exists, and remembered across restarts —
    /// the phone can set volume before a stream starts.
    private var volume: Float = 1.0

    /// The engine's configuration-change observer — see `configurationChanged`. Held so it
    /// can be removed with the engine it watched, rather than firing for one already gone.
    private var configObserver: NSObjectProtocol?

    /// Flips when sound audibly starts/stops coming out of this Mac (node started
    /// and buffers pending). This — not data arrival — is what "playing" means:
    /// the phone's writes are bursty (measured multi-second gaps mid-song, plus a
    /// flush burst right at pause), but scheduled audio drains in real time.
    /// Called on a private serial queue, in the order the flips happened; the receiver hops to main.
    var onAudible: ((Bool) -> Void)?

    /// Rendered audio, for anything that wants to *watch* what the speaker is emitting — the
    /// menu-bar mark's analyser, and nothing else so far.
    ///
    /// **A closure rather than a reference to the analyser, so the CLI does not grow one.** The CLI
    /// target builds this file without `BlindsEqMark.swift` or `EqAnalyser.swift`; naming either
    /// here would drag the mark into a binary that has no menu bar. The app sets this, the CLI
    /// never does, and the tap is only installed when it is set.
    ///
    /// **On the node, deliberately, and this is the whole latency story.** A tap on the player node
    /// fires as audio is *rendered*, so a level computed here describes what is leaving the
    /// speaker. Watching the *scheduled* buffers instead would run ahead by the prebuffer and the
    /// queue — which is the problem the phone had to build a presentation-time ring for. There
    /// is nothing to compensate on this side, and nothing
    /// should be added.
    ///
    /// Called on a render thread: allocate nothing, block nothing.
    var onRenderedPCM: ((UnsafePointer<UnsafeMutablePointer<Float>>, Int, Int, Float) -> Void)?
    private var audible = false

    init(prebufferMs: Int) {
        self.prebufferMs = max(1, prebufferMs)
    }

    /// Must be called with `lock` held. A flip is handed to `notifyQueue` *from inside the lock*,
    /// so flips reach `onAudible` in the order they happened. They used to be called after the
    /// unlock, and a buffer completing on the render thread while `enqueue` scheduled the next one
    /// could deliver `true` then `false` the wrong way round: audio playing, the mark frozen.
    private func updateAudibleLocked() {
        let now = started && pendingFrames > 0
        guard now != audible else { return }
        audible = now
        if now { cancelIdleLocked() } else { armIdleLocked() }
        let notify = onAudible
        notifyQueue.async { notify?(now) }
    }
    private let notifyQueue = DispatchQueue(label: "me.arsentsn.NoirReceiver.player.audible")

    /// Must be called with `lock` held.
    private func armIdleLocked() {
        guard engine != nil else { return }
        idleToken &+= 1
        let token = idleToken
        idleQueue.asyncAfter(deadline: .now() + Self.idleTeardownDelay) { [weak self] in
            self?.suspendIfIdle(token)
        }
    }

    /// Must be called with `lock` held. The bump is the cancellation.
    private func cancelIdleLocked() {
        idleToken &+= 1
    }

    /// Must be called with `lock` held. Forgets the engine and everything scheduled on it,
    /// and hands both back so the caller can stop them *outside* the lock — `stop()` fires
    /// the discarded buffers' completion handlers synchronously and they take it. The
    /// generation bump is what makes those handlers harmless (see `flush`). Every path that
    /// drops an engine goes through here: idle release, `stop()`, a device change — three
    /// copies of this sequence is how one of them forgets the observer.
    private func releaseEngineLocked() -> (AVAudioEngine?, AVAudioPlayerNode?) {
        generation &+= 1
        pendingFrames = 0
        started = false
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        defer { engine = nil; node = nil }
        return (engine, node)
    }

    /// Hands the output device back after `idleTeardownDelay` of silence, while the
    /// session stays open. Audio that arrives afterwards rebuilds the engine and
    /// re-prebuffers, so the only cost is the first chunk's worth of latency.
    private func suspendIfIdle(_ token: UInt64) {
        lock.lock()
        guard token == idleToken, !audible, engine != nil else {
            lock.unlock()
            return
        }
        let (engine, node) = releaseEngineLocked()
        lock.unlock()
        // Outside the lock, because `stop()` fires those completion handlers
        // synchronously and they take it.
        node?.stop()
        engine?.stop()
        log?("no audio for \(Int(Self.idleTeardownDelay))s; released the output device")
    }

    /// The engine stopped underneath us: the output device changed, or its sample rate did.
    ///
    /// Apple documents that the engine *stops* on a hardware configuration change and posts
    /// `AVAudioEngineConfigurationChange`; what it does not do is start again, and until this
    /// existed nothing here did either. Plugging in headphones mid-stream was therefore silence
    /// until the phone reconnected — and not even the 30s idle release could rescue it, because
    /// buffers scheduled on a stopped engine never complete, so `pendingFrames` never drained
    /// and the player counted itself audible for good. Release the engine the way the idle path
    /// does and let the next chunk rebuild it: one prebuffer refill, on the new device.
    ///
    /// Delivered on whatever thread posted it, so this takes the lock like everything else. A
    /// notification from an engine already released is ignored by identity.
    private func configurationChanged(_ changed: AVAudioEngine?) {
        lock.lock()
        guard let changed, changed === engine else { lock.unlock(); return }
        let (engine, node) = releaseEngineLocked()
        updateAudibleLocked()
        lock.unlock()
        node?.stop()
        engine?.stop()
        log?("output device changed; re-opening on the next chunk")
    }

    func start(_ wav: WavFormat) throws {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: wav.sampleRate,
                                      channels: AVAudioChannelCount(wav.channels),
                                      interleaved: false) else {
            throw NSError(domain: "receiver", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unsupported format"])
        }
        lock.lock()
        defer { lock.unlock() }
        format = fmt
        prebufferFrames = max(1, Int(wav.sampleRate) * prebufferMs / 1000)
        try buildLocked(fmt)
    }

    /// Must be called with `lock` held. Arms the idle teardown on the way out, so a
    /// phone that connects already paused — never audible, so never flipping — cannot
    /// hold the device open the way one did for five days.
    private func buildLocked(_ fmt: AVAudioFormat) throws {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        // The system default output, always: the Mac's own Sound setting decides where the
        // stream plays, as it does for every other app. A per-app picker was built and removed
        // on 2026-09-05 — the receiver's job is the Mac's speakers, and anything else would be
        // paired with the phone directly.
        // Connecting with the source format lets the engine resample to whatever
        // the output device actually runs at.
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = volume
        // Only when somebody is watching — see `onRenderedPCM`. The buffer size is a request, not
        // a promise; the analyser slices whatever arrives into its own sub-blocks.
        if let watcher = onRenderedPCM {
            // **One analysis sub-block per callback, not a convenient power of two.** The analyser
            // splits whatever arrives into sub-blocks of `rate / 60` (one cycle of its lowest band)
            // and publishes each — but publishing overwrites, and the UI samples asynchronously at
            // 60fps, so only the last of a burst is ever seen. At the 2048 this first shipped with
            // that is 46 ms of audio collapsed to one visible update: the mark ran at ~21 Hz and
            // showed the *end* of each window, which reads as both "low fps" and "sometimes
            // laggy" — reported as exactly that on 2026-09-02.
            //
            // Asking for one sub-block makes the callback rate and the publish rate the same 60 Hz
            // the mark draws at. It is a request, not a promise; if the implementation hands over
            // more, the analyser still splits it correctly and only the collapse comes back.
            let tapFrames = AVAudioFrameCount(max(256, fmt.sampleRate / 60))
            // **`bufferSize` is a request and the engine may ignore it**, which matters here: the
            // whole point of asking for one sub-block is that a bigger buffer collapses to one
            // visible update per callback. So log what actually arrives, once, rather than
            // assuming the request was honoured — the receiver had no way to answer "is the mark
            // really running at 60" and that is exactly the question it kept being asked.
            var loggedTap = false
            node.installTap(onBus: 0, bufferSize: tapFrames, format: fmt) { [weak self] buffer, _ in
                guard let data = buffer.floatChannelData else { return }
                if !loggedTap {
                    loggedTap = true
                    let n = buffer.frameLength
                    self?.log?("tap: asked \(tapFrames) frames, got \(n) "
                        + "(\(String(format: "%.1f", Double(n) / fmt.sampleRate * 1000)) ms, "
                        + "\(String(format: "%.0f", fmt.sampleRate / Double(n)))/s)")
                }
                watcher(data,
                        Int(buffer.format.channelCount),
                        Int(buffer.frameLength),
                        Float(buffer.format.sampleRate))
            }
        }
        // Registered against *this* engine, so a stale notification cannot be mistaken for the
        // live one's; removed with it in `releaseEngineLocked`.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] note in
            self?.configurationChanged(note.object as? AVAudioEngine)
        }
        try engine.start()
        self.engine = engine
        self.node = node
        armIdleLocked()
    }

    /// 0...1. Survives a flush, a reconnect and an idle teardown; the phone owns
    /// this value.
    func setVolume(_ v: Float) {
        let clamped = min(max(v, 0), 1)
        lock.lock()
        volume = clamped
        engine?.mainMixerNode.outputVolume = clamped
        lock.unlock()
    }

    /// Drops everything scheduled and re-arms the prebuffer, so the next audio to
    /// arrive starts a fresh fill instead of playing out the old position first.
    /// Called when the phone seeks or changes track — that audio is wrong, not late.
    func flush() {
        lock.lock()
        generation &+= 1
        pendingFrames = 0
        started = false
        updateAudibleLocked()
        let node = self.node
        lock.unlock()
        // Fires completion handlers for the discarded buffers; the generation bump
        // above is what makes them harmless.
        node?.stop()
    }

    /// `bytes` must be interleaved signed 16-bit little-endian, whole frames only — the
    /// session carries any partial frame over to the next call.
    ///
    /// Runs under the lock start to finish, unlike the version that could read `node`
    /// and schedule against it in two steps: an idle teardown landing in that gap
    /// would schedule a buffer on a detached node, whose completion handler never
    /// fires — leaving the pending count stuck above zero, so nothing was ever "silent"
    /// again and the device could never be released. Converting a few KB of PCM inside
    /// the lock is cheaper than that failure mode.
    func enqueue(_ bytes: Data) {
        lock.lock()
        guard let fmt = format else { lock.unlock(); return }
        // Logged with its cost because this is the price of releasing the device: the
        // first chunk after a quiet stretch waits for `engine.start()` on the
        // connection's queue. Worth watching in the log — a contended audio device can
        // make that open slow, and a stalled open stalls the whole feed.
        var reopenedMs: Double?
        if engine == nil {
            let t0 = Date()
            do {
                try buildLocked(fmt)
            } catch {
                lock.unlock()
                log?("engine restart failed: \(error)")
                return
            }
            reopenedMs = Date().timeIntervalSince(t0) * 1000
        }
        let ch = Int(fmt.channelCount)
        let frames = bytes.count / (2 * ch)
        guard frames > 0, let node,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(frames)) else {
            lock.unlock()
            return
        }
        buf.frameLength = AVAudioFrameCount(frames)

        // De-interleave and scale with vDSP: one strided pass per channel instead of a scalar
        // loop over every sample, inside the lock that the render thread's completions wait on.
        bytes.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: Int16.self),
                  let dst = buf.floatChannelData else { return }
            var scale = Float(1.0 / 32768.0)
            let n = vDSP_Length(frames)
            for c in 0..<ch {
                vDSP_vflt16(src + c, vDSP_Stride(ch), dst[c], 1, n)
                vDSP_vsmul(dst[c], 1, &scale, dst[c], 1, n)
            }
        }

        pendingFrames += frames
        let shouldStart = !started && pendingFrames >= prebufferFrames
        if shouldStart { started = true }
        let gen = generation
        updateAudibleLocked()

        node.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            // A flush or an idle teardown already zeroed the count and discarded this
            // buffer.
            guard gen == self.generation else { self.lock.unlock(); return }
            self.pendingFrames -= frames
            self.updateAudibleLocked()
            self.lock.unlock()
        }
        // Under the lock and only on a running engine: `play()` on an engine a device change has
        // just stopped raises an Objective-C exception, and outside the lock that change could
        // land between the schedule above and this line. A stopped engine is about to be
        // released by `configurationChanged`, and the next chunk starts a fresh one.
        if shouldStart, engine?.isRunning == true { node.play() }
        lock.unlock()
        if let reopenedMs { log?(String(format: "re-opened the output device in %.0fms", reopenedMs)) }
    }

    func stop() {
        lock.lock()
        cancelIdleLocked()
        format = nil
        let (engine, node) = releaseEngineLocked()
        // Nil'd first, so this cannot arm a teardown for a device that is already gone.
        updateAudibleLocked()
        lock.unlock()
        node?.stop()
        engine?.stop()
    }
}
