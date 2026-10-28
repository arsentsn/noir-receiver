// What the app remembers between launches that the receiver core does not: the mark's motion,
// the menu bar's shape, and the persisting of the core's own settings.

import Combine
import Foundation

/// Preferences that are the app's rather than the receiver's, backed by UserDefaults.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    /// Motion: the menu bar mark's dance, and scrolling a title too long to fit.
    ///
    /// **On by default** — the dancing mark is how the menu bar says "playing", and
    /// losing that by default would cost more than it saves. But a permanently moving
    /// icon in the corner of the screen is exactly the sort of thing that grates on
    /// some people, and this turns it off without giving up the icon or the dot badge.
    /// Independent of the system's Reduce Motion, which is honoured regardless.
    /// **One control with three states, not two toggles** (2026-09-02). It shipped for about an
    /// hour as `animate` plus a dependent `reactive`, which is the shape that has to explain
    /// itself: a switch that only exists while another switch is on is a state machine drawn as
    /// two independent things, and the combination "not animating, but reactive" was
    /// representable and meaningless.
    @Published var markMotion: MarkMotion {
        didSet { UserDefaults.standard.set(markMotion.rawValue, forKey: Keys.markMotion) }
    }

    /// What the status item shows beside the mark. Icon by default: it is what every install had.
    @Published var menuBarStyle: MenuBarStyle {
        didSet { UserDefaults.standard.set(menuBarStyle.rawValue, forKey: Keys.menuBarStyle) }
    }

    /// The thin line under the status item for how far into the song the phone is. Off by default,
    /// for the same reason.
    @Published var progressLine: Bool {
        didSet { UserDefaults.standard.set(progressLine, forKey: Keys.progressLine) }
    }

    /// Whether the mark moves at all — and therefore whether *titles* scroll too, which is the
    /// one thing this setting governs beyond the mark.
    var animate: Bool { markMotion != .off }
    /// Whether it moves to the audio rather than to the canned loop.
    var reactive: Bool { markMotion == .reactive }

    private enum Keys {
        static let markMotion = "markMotion"
        /// The two booleans this replaced. Read once, to carry an existing choice over.
        static let legacyAnimate = "animate"
        static let legacyReactive = "reactiveEq"
        static let port = "port"
        static let prebufferMs = "prebufferMs"
        /// The chunk count `prebufferMs` replaced. Read once, to convert an existing choice.
        static let legacyPrebufferChunks = "prebufferChunks"
        static let requireApproval = "requireApproval"
        static let knownPhones = "knownPhones"
        static let knownPhoneNames = "knownPhoneNames"
        static let menuBarStyle = "menuBarStyle"
        static let progressLine = "progressLine"
    }

    // The receiver's own settings — port, buffer, pairing — live on the `Receiver` at runtime
    // and are only *persisted* from here, so the settings window edits one object and the CLI,
    // which has no Preferences, takes the same values as plain init arguments. Used to be string
    // keys repeated in the delegate and the settings view, with the default written out in both.

    static func port() -> UInt16 {
        let stored = UserDefaults.standard.integer(forKey: Keys.port)
        return (1...65535).contains(stored) ? UInt16(stored) : DefaultPort
    }

    static func setPort(_ port: UInt16) {
        UserDefaults.standard.set(Int(port), forKey: Keys.port)
    }

    /// Milliseconds, migrated from the chunk count the slider used to store. A chunk was one
    /// of the phone's ~46 ms buffers, so the old default of four reads as 186 and lands on
    /// 200 — snapped to the slider's 50 ms steps rather than showing a number nobody chose.
    static func prebufferMs() -> Int {
        let defaults = UserDefaults.standard
        let ms = defaults.integer(forKey: Keys.prebufferMs)
        if ms > 0 { return ms }
        let chunks = defaults.integer(forKey: Keys.legacyPrebufferChunks)
        guard chunks > 0 else { return DefaultPrebufferMs }
        let snapped = Int((Double(chunks) * 46.4 / 50).rounded()) * 50
        let clamped = min(max(snapped, Int(SettingsView.bufferRange.lowerBound)),
                          Int(SettingsView.bufferRange.upperBound))
        defaults.set(clamped, forKey: Keys.prebufferMs)
        return clamped
    }

    static func setPrebufferMs(_ ms: Int) {
        UserDefaults.standard.set(ms, forKey: Keys.prebufferMs)
    }

    /// Loads the persisted pairing settings onto the receiver, and keeps them persisted as
    /// they change. Call before `start()`, so the first connection already knows whether it
    /// has to wait. The caller stores the cancellables.
    static func bind(_ receiver: Receiver) -> [AnyCancellable] {
        let defaults = UserDefaults.standard
        // register(defaults:), as for `animate` above: an unset bool reads false, and this
        // one defaults *on*.
        defaults.register(defaults: [Keys.requireApproval: true])
        receiver.requireApproval = defaults.bool(forKey: Keys.requireApproval)
        receiver.knownPhones = (defaults.dictionary(forKey: Keys.knownPhones) as? [String: Bool]) ?? [:]
        receiver.knownPhoneNames =
            (defaults.dictionary(forKey: Keys.knownPhoneNames) as? [String: String]) ?? [:]
        return [
            receiver.$requireApproval.dropFirst()
                .sink { defaults.set($0, forKey: Keys.requireApproval) },
            receiver.$knownPhones.dropFirst()
                .sink { defaults.set($0, forKey: Keys.knownPhones) },
            receiver.$knownPhoneNames.dropFirst()
                .sink { defaults.set($0, forKey: Keys.knownPhoneNames) },
        ]
    }

    private init() {
        // register(defaults:) and not `bool(forKey:) ?? true`: an unset bool reads as
        // false, which would have shipped the animation off for every existing install.
        UserDefaults.standard.register(defaults: [Keys.legacyAnimate: true, Keys.legacyReactive: true])
        // Migrate rather than default: someone who turned the animation off is not asking for it
        // back because the setting was reshaped. Absent `markMotion` means a pre-2026-09-02
        // install, whose two booleans still say what it wanted.
        menuBarStyle = UserDefaults.standard.string(forKey: Keys.menuBarStyle)
            .flatMap(MenuBarStyle.init(rawValue:)) ?? .icon
        progressLine = UserDefaults.standard.bool(forKey: Keys.progressLine)
        if let stored = UserDefaults.standard.string(forKey: Keys.markMotion),
           let motion = MarkMotion(rawValue: stored) {
            markMotion = motion
        } else if !UserDefaults.standard.bool(forKey: Keys.legacyAnimate) {
            markMotion = .off
        } else {
            markMotion = UserDefaults.standard.bool(forKey: Keys.legacyReactive) ? .reactive : .fixed
        }
    }
}

/// What the menu-bar mark does: nothing, a fixed loop, or the audio.
///
/// Ordered as the settings control draws it — least motion to most — so `allCases` is the picker.
enum MarkMotion: String, CaseIterable, Identifiable {
    case off, fixed, reactive
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Still"
        case .fixed: return "Loop"
        case .reactive: return "Audio"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "The mark and long titles stay still. The icon still shows a dot when a phone "
                 + "is connected."
        case .fixed:
            return "The mark dances to a fixed loop while sound plays — the same motion it had "
                 + "before it could listen."
        case .reactive:
            return "The mark's bars follow what this Mac is playing."
        }
    }
}
