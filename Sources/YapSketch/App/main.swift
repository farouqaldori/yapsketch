import AVFoundation
import AppKit
import SwiftUI

// Writing to a helper process that has exited must not kill the app.
signal(SIGPIPE, SIG_IGN)

let args = CommandLine.arguments

// The command line, which is all the `yapsketch` wrapper ever runs.
if ProcessInfo.processInfo.environment["YAPSKETCH_CLI"] != nil || (args.count > 1 && CLI.commands.contains(args[1])) {
    CLI.run(Array(args.dropFirst()))
}
#if DEBUG
if args.contains("--test-oauth-callback") {
    Task {
        do {
            let cb = try await LoopbackPKCE.Callback.start()
            print("port \(cb.port)")
            fflush(stdout)
            let query = try await cb.wait(timeout: 20)
            print("got \(query.sorted { $0.key < $1.key })")
            cb.stop()
        } catch { print("error \(error)") }
        exit(0)
    }
    dispatchMain()
}
if let i = args.firstIndex(of: "--snapshot-overlay"), i + 1 < args.count {
    _ = NSApplication.shared
    DevSnapshot.run(to: URL(fileURLWithPath: args[i + 1]))
    exit(0)
}
if let i = args.firstIndex(of: "--describe-test"), i + 1 < args.count {
    _ = NSApplication.shared
    DevSnapshot.describeTest(to: URL(fileURLWithPath: args[i + 1]))
    exit(0)
}
if let i = args.firstIndex(of: "--snapshot-settings"), i + 2 < args.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated {
        let nav = SettingsWindow.shared
        nav.pane = SettingsPane(rawValue: args[i + 1]) ?? .general
        // YAPSKETCH_SNAPSHOT_SIZE=760x520 picks another size.
        let wh = ProcessInfo.processInfo.environment["YAPSKETCH_SNAPSHOT_SIZE"]?.split(separator: "x").compactMap { Double($0) }
        let size = wh?.count == 2 ? CGSize(width: wh![0], height: wh![1]) : CGSize(width: 1120, height: 780)
        let w = nav.makeWindow(size: size)
        w.setContentSize(size)
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        if ProcessInfo.processInfo.environment["YAPSKETCH_SNAPSHOT_SCROLLED"] != nil {
            // The page scrolled a little, to see what's under the title bar.
            func scrollViews(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(scrollViews) }
            if let main = scrollViews(w.contentView!).max(by: { $0.frame.width < $1.frame.width }) {
                main.contentView.scroll(to: NSPoint(x: 0, y: main.contentView.bounds.minY + 180))
                main.reflectScrolledClipView(main.contentView)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        }
        // The window as it's drawn on screen (an offscreen render misses some of SwiftUI).
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-l", "\(w.windowNumber)", "-o", "-x", args[i + 2]]
        try? shot.run()
        shot.waitUntilExit()
    }
    exit(0)
}
if let i = args.firstIndex(of: "--snapshot-onboarding"), i + 1 < args.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { DevSnapshot.onboarding(to: URL(fileURLWithPath: args[i + 1])) }
    exit(0)
}
if let i = args.firstIndex(of: "--snapshot-pills"), i + 1 < args.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { DevSnapshot.pills(to: URL(fileURLWithPath: args[i + 1])) }
    exit(0)
}
if let i = args.firstIndex(of: "--snapshot-player"), i + 1 < args.count {
    _ = NSApplication.shared
    DevSnapshot.player(to: URL(fileURLWithPath: args[i + 1]))
    exit(0)
}
if let i = args.firstIndex(of: "--test-speech"), i + 2 < args.count {
    _ = NSApplication.shared
    DevSpeechTest.run(
        input: URL(fileURLWithPath: args[i + 1]), output: URL(fileURLWithPath: args[i + 2]),
        parakeet: args.contains("--parakeet"))
    exit(0)
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
