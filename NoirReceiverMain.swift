// The app's entry point, and nothing else.
//
// Kept in its own file so `build.sh preview` can compile every other source — the real
// AppDelegate, the real ReceiverMenu — against a different `@main`. Two entry points in
// one compilation is an error, and stripping this one with `sed` at build time was the
// alternative. A file is cheaper than a text transform, and it cannot go stale.

import SwiftUI

@main
struct NoirReceiverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // No windows: the status item is the whole app, and Settings is an NSWindow
        // the AppDelegate owns (an LSUIElement app has no menu bar to hang ⌘, from).
        Settings { EmptyView() }
    }
}
