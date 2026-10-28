// The settings window's content.

import ServiceManagement
import SwiftUI

/// Everything you set once and forget. Lives in a window, not the popover.
struct SettingsView: View {
    @ObservedObject var receiver: Receiver
    /// Milliseconds. The slider used to count chunks — "4 chunks" — which was the phone's
    /// buffer size in disguise and meant nothing to anyone reading it.
    @State private var bufferMs: Double = Double(DefaultPrebufferMs)
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var portText = ""
    @ObservedObject private var prefs = Preferences.shared

    static let bufferRange: ClosedRange<Double> = 50...750
    private static let bufferStep: Double = 50

    private func applyPort() {
        guard let port = UInt16(portText), port > 0, port != receiver.port else { return }
        Preferences.setPort(port)
        receiver.restart(on: port)
    }

    /// Start-at-login through a binding with a setter rather than `onChange(of:)`: the
    /// two-argument form is macOS 14 and this app promises 13 — which nothing checked until
    /// `build.sh` gained a `-target`, and this line was the one that failed.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { launchAtLogin }, set: { on in
            launchAtLogin = on
            do {
                if on { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                // The service refused; show what the system actually thinks.
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Buffer: \(Int(bufferMs)) ms")
                Slider(value: $bufferMs, in: Self.bufferRange, step: Self.bufferStep) { editing in
                    if !editing {
                        receiver.prebufferMs = Int(bufferMs)
                        Preferences.setPrebufferMs(Int(bufferMs))
                    }
                }
                // fixedSize(vertical:) or it ellipsizes instead of wrapping: the row
                // above is a Slider, which proposes a single line's height down to this
                // Text, and a Text given one line's height truncates rather than grows.
                Text("Audio queued before playback starts. Lower is snappier, higher survives weak Wi-Fi. Applies to the next connection.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Port")
                    TextField("", text: $portText)
                        .frame(width: 72)
                        .onSubmit(applyPort)
                    Button("Apply", action: applyPort)
                        .disabled(UInt16(portText) == nil || UInt16(portText) == receiver.port)
                    Spacer()
                }
                Text("The phone discovers whatever port is set here; only a manual address needs to match it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Ask before a new phone can play here", isOn: $receiver.requireApproval)
                Text("Anyone on this network could otherwise play through this Mac. Each answer is remembered for that phone.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if receiver.knownPhones.isEmpty {
                    Text("No phones remembered yet.")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(receiver.knownPhones.keys.sorted {
                        receiver.displayName(ofKnown: $0) < receiver.displayName(ofKnown: $1)
                    }, id: \.self) { key in
                        HStack(spacing: 6) {
                            Text(receiver.displayName(ofKnown: key)).lineLimit(1)
                            Text(receiver.knownPhones[key] == true ? "Allowed" : "Blocked")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Forget") { receiver.forget(key) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                // Segmented rather than three radios: the states are one ordered axis — how much
                // the mark moves — and a picker says "pick one of these" where three checkboxes
                // would leave the reader working out which combinations are legal.
                Picker("Animation", selection: $prefs.markMotion) {
                    ForEach(MarkMotion.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                // The caption follows the selection, so the window is not carrying three
                // paragraphs to explain three words.
                Text(prefs.markMotion.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Menu bar", selection: $prefs.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Text(prefs.menuBarStyle.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Independent of the style: a line under the mark alone, or under the song.
                Toggle("Show how far into the song", isOn: $prefs.progressLine)
            }

            Toggle("Start at login", isOn: launchAtLoginBinding)

            // The one status line worth repeating here: if the port is taken, this
            // window is where you are when you need to know.
            if !receiver.listening {
                Label("Not listening — is port \(String(receiver.port)) already taken?",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // So a bug report can say which build — the only place the version is shown.
            Text("Noir Receiver \(ReceiverVersion)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            if portText.isEmpty { portText = String(receiver.port) }
            bufferMs = Double(receiver.prebufferMs)
        }
    }
}
