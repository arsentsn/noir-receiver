// CLI entry point:
//   ./noir-receiver [port]                  plays whatever connects, as it always has
//   ./noir-receiver [port] --ask            asks before a new phone plays, and never answers
//   ./noir-receiver ... --pending-timeout S how long an unanswered request waits (default 60)
//   ./noir-receiver --version
// Same core as the menu bar app; logs to stderr and runs until killed. This is what the
// dev-machine LaunchAgent wraps. Approval is off by default — there is no UI to click Allow in.
// `--ask` exists for `protocol-test.py`: with approval on, connections are held rather than
// replacing one another, which is the only way to reach the connection cap and the expiry.

import Foundation

@main
struct NoirReceiverCLI {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--version") || args.contains("-v") {
            print("noir-receiver \(ReceiverVersion)")
            return
        }
        let ask = args.contains("--ask")
        args.removeAll { $0 == "--ask" }
        var pendingTimeout: TimeInterval?
        if let i = args.firstIndex(of: "--pending-timeout") {
            guard i + 1 < args.count, let seconds = TimeInterval(args[i + 1]), seconds > 0 else {
                FileHandle.standardError.write(Data("--pending-timeout needs a number of seconds\n".utf8))
                exit(2)
            }
            pendingTimeout = seconds
            args.removeSubrange(i...(i + 1))
        }
        let port = UInt16(args.first ?? "") ?? DefaultPort
        let receiver = Receiver(port: port)
        receiver.requireApproval = ask
        if let pendingTimeout { receiver.pendingTimeout = pendingTimeout }
        receiver.start()
        RunLoop.main.run()
    }
}
