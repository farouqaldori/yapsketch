#if DEBUG
import AppKit
import SwiftUI
import AVFoundation
import Speech

/// Debug-only: `YapSketch --snapshot-overlay out.png` renders the overlay with sample
/// ink, captions and HUD offscreen, to check what gets burned into recordings.
enum DevSnapshot {
    /// `--describe-test out.txt`: what the accessibility tree says at points in Chrome's window.
    static func describeTest(to url: URL) {
        var lines: [String] = []
        guard let chrome = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.google.Chrome" }) else {
            try? "Chrome not running".write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let app = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        var win: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win)
        var posV: CFTypeRef?
        var sizeV: CFTypeRef?
        var pos = CGPoint.zero
        var size = CGSize.zero
        if let win {
            AXUIElementCopyAttributeValue(win as! AXUIElement, kAXPositionAttribute as CFString, &posV)
            AXUIElementCopyAttributeValue(win as! AXUIElement, kAXSizeAttribute as CFString, &sizeV)
            if let posV { AXValueGetValue(posV as! AXValue, .cgPoint, &pos) }
            if let sizeV { AXValueGetValue(sizeV as! AXValue, .cgSize, &size) }
        }
        lines.append("trusted=\(AXIsProcessTrusted()) window=\(pos) \(size)")
        for (fx, fy) in [(0.25, 0.25), (0.5, 0.3), (0.75, 0.35), (0.5, 0.5), (0.3, 0.7), (0.8, 0.2)] {
            let p = CGPoint(x: pos.x + size.width * fx, y: pos.y + size.height * fy)
            lines.append("(\(fx),\(fy)) -> \(InputMonitor.describeElement(at: p) ?? "nil")")
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// `--snapshot-player out.png`: the mini player, recording, with the pen selected.
    static func player(to url: URL) {
        let p = MiniPlayer()
        p.update(recording: true, elapsed: 83)
        for v: Float in [0.2, 0.5, 0.9, 0.6, 0.3, 0.7, 1.0, 0.4, 0.15] { p.push(level: v) }
        p.sync(drawing: true, tool: .pen, color: 0, fading: true)
        guard let view = p.panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let out = NSImage(size: CGSize(width: view.bounds.width + 40, height: view.bounds.height + 40))
        out.lockFocus()
        NSColor(white: 0.85, alpha: 1).setFill()
        CGRect(origin: .zero, size: out.size).fill()
        rep.draw(
            in: view.bounds.offsetBy(dx: 20, dy: 20), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) {
            try? bmp.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// `--snapshot-pills <dir>`: the toolbar and pills in each state, over a desktop-ish gradient.
    @MainActor static func pills(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func shoot(_ panel: NSPanel, _ name: String) {
            panel.sharingType = .readOnly
            panel.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let raw = dir.appendingPathComponent("raw-\(name).png")
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-l", "\(panel.windowNumber)", "-x", raw.path]
            try? shot.run()
            shot.waitUntilExit()
            panel.orderOut(nil)
            guard let image = NSImage(contentsOf: raw) else { return }
            let out = NSImage(size: CGSize(width: image.size.width + 60, height: image.size.height + 60))
            out.lockFocus()
            NSGradient(starting: NSColor(srgbRed: 0.6, green: 0.48, blue: 0.36, alpha: 1), ending: NSColor(srgbRed: 0.31, green: 0.35, blue: 0.47, alpha: 1))?
                .draw(in: CGRect(origin: .zero, size: out.size), angle: -40)
            image.draw(in: CGRect(x: 30, y: 30, width: image.size.width, height: image.size.height))
            out.unlockFocus()
            if let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) {
                try? bmp.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            }
            try? FileManager.default.removeItem(at: raw)
        }

        let player = MiniPlayer()
        player.update(recording: true, elapsed: 7)
        player.setCaption("and this one should match it")
        for v: Float in [0.2, 0.5, 0.9, 0.6, 0.3, 0.7, 1.0, 0.4, 0.15] { player.push(level: v) }
        player.sync(drawing: false, tool: .pen, color: 0, fading: false)
        player.show(on: NSScreen.main!)
        shoot(player.panel, "toolbar")
        player.update(recording: false, elapsed: 0)
        player.sync(drawing: true, tool: .pen, color: 1, fading: true)
        shoot(player.panel, "toolbar-drawing")

        let status = StatusPill()
        status.working()
        shoot(status.debugPanel, "status-working")
        status.done("Copied to clipboard")
        shoot(status.debugPanel, "status-done")
        status.problem("Couldn't start recording. Try again.", button: "Try Again") {}
        shoot(status.debugPanel, "status-problem")
        status.problem("YapSketch needs the microphone to record", button: "Turn On") {}
        shoot(status.debugPanel, "status-problem-permission")
        status.problem("Couldn't make the report. The recording is saved.", button: "Show") {}
        shoot(status.debugPanel, "status-problem-report")

        let dictation = DictationPill()
        dictation.listening()
        dictation.text("Ship it on Friday and tell the team")
        for v: Float in [0.3, 0.8, 0.5, 0.9, 0.35, 0.6, 0.4] { dictation.level(v) }
        shoot(dictation.debugPanel, "dictation-listening")
        dictation.working()
        shoot(dictation.debugPanel, "dictation-working")
        dictation.done("Pasted into Slack")
        shoot(dictation.debugPanel, "dictation-done")
        print(dir.path)
    }

    /// `--snapshot-onboarding <dir>`: each page of the welcome, and the helper card.
    @MainActor static func onboarding(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func capture(_ w: NSWindow, _ name: String) {
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-l", "\(w.windowNumber)", "-o", "-x", dir.appendingPathComponent("\(name).png").path]
            try? shot.run()
            shot.waitUntilExit()
        }
        let model = Onboarding.shared
        let w = model.makeWindow()
        let pages: [(String, Onboarding.Step, Set<Permission>, Bool, Bool)] = [
            ("1-welcome", .welcome, [], false, false),
            ("1a-speech", .speech(.choose), [], false, false),
            ("1b-local-models", .speech(.localModels), [], false, false),
            ("1c-downloading", .speech(.downloading), [], false, false),
            ("1d-cloud", .speech(.cloud), [], false, false),
            ("1e-cloud-models", .speech(.cloudModels), [], false, false),
            ("1f-smart-pictures", .smartPictures, [], false, false),
            ("1g-smart-pictures-accounts", .smartPictures, [], false, false),
            ("2-microphone", .permission(.microphone), [], false, false),
            ("3-screen-recording", .permission(.screenRecording), [.microphone], false, false),
            ("3b-screen-recording-waiting", .permission(.screenRecording), [.microphone], true, false),
            ("3c-screen-recording-reopen", .permission(.screenRecording), [.microphone], true, true),
            ("4-accessibility-on", .permission(.accessibility), [.microphone, .screenRecording, .accessibility], true, false),
            ("5-input-monitoring-waiting", .permission(.inputMonitoring), [.microphone, .screenRecording, .accessibility], true, false),
            ("6-done", .done, Set(Permission.allCases), false, false),
        ]
        model.cloudProvider = Providers.connected.first { !$0.speech.isEmpty }?.id
        for (name, step, granted, opened, reopen) in pages {
            model.debugSet(step, granted: granted, openedSettings: opened, needsReopen: reopen)
            model.showJevAccounts = name.hasSuffix("-accounts")
            capture(w, name)
        }
        w.orderOut(nil)

        let helper = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 290, height: 260), styleMask: [.borderless], backing: .buffered, defer: false)
        helper.appearance = NSAppearance(named: .aqua)
        helper.backgroundColor = Brand.markBlue.blended(withFraction: 0.6, of: Brand.inkSoft) ?? .gray
        helper.contentView = NSHostingView(rootView: HelperCard(label: "YapSketch setup · 2 of 4").padding(20))
        helper.setContentSize(helper.contentView!.fittingSize)
        capture(helper, "7-helper")
        print(dir.path)
    }

    static func run(to url: URL) {
        let screen = NSScreen.main!
        let o = OverlayController(screen: screen)
        o.isRecording = true
        o.showKeycast("⌘⇧R")
        o.setDrawMode(true)

        let c = o.canvas
        let h = c.bounds.height
        func drag(_ pts: [CGPoint]) {
            func ev(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(
                    with: type, location: CGPoint(x: p.x, y: h - p.y), modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            c.mouseDown(with: ev(.leftMouseDown, pts[0]))
            pts.dropFirst().forEach { c.mouseDragged(with: ev(.leftMouseDragged, $0)) }
            c.mouseUp(with: ev(.leftMouseUp, pts.last!))
        }
        c.tool = .rect
        drag([CGPoint(x: 840, y: 400), CGPoint(x: 1020, y: 464)])
        c.tool = .arrow
        c.colorIndex = 1
        drag([CGPoint(x: 640, y: 260), CGPoint(x: 830, y: 395)])
        c.tool = .pen
        c.colorIndex = 0
        // A hand-drawn circle: speeds up through the middle, slows at the end (spacing = speed).
        var circle: [CGPoint] = []
        var a = 0.0
        while a < 2.15 * .pi {
            circle.append(CGPoint(x: 400 + 110 * cos(a) + Double.random(in: -1...1), y: 600 + 60 * sin(a) + Double.random(in: -1...1)))
            a += 0.03 + 0.09 * sin(min(1, a / (2 * .pi)) * .pi)
        }
        drag(circle)
        // A slow underline and a fast scribble.
        var underline: [CGPoint] = []
        for i in 0...60 {
            let x: Double = 200 + Double(i) * 6
            let y: Double = 760 + sin(Double(i) / 6) * 3
            underline.append(CGPoint(x: x, y: y))
        }
        drag(underline)
        var scribble: [CGPoint] = []
        for i in 0...40 {
            let x: Double = 700 + Double(i) * 14
            let y: Double = 640 + (i % 2 == 0 ? -30 : 30) + Double(i)
            scribble.append(CGPoint(x: x, y: y))
        }
        drag(scribble)
        o.ripple(atLocal: CGPoint(x: 930, y: 432))

        let view = c.superview!
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Composite over a mid-grey "desktop" so translucent elements are visible.
        let out = NSImage(size: view.bounds.size)
        out.lockFocus()
        NSColor(white: 0.55, alpha: 1).setFill()
        view.bounds.fill()
        rep.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) {
            try? bmp.representation(using: .png, properties: [:])?.write(to: url)
        }
        print(url.path)
    }
}

/// Debug-only: `open YapSketch.app --args --test-speech in.m4a out.txt` feeds an audio file to
/// live speech like mic buffers. Run via `open` so the app's Speech Recognition permission applies.
enum DevSpeechTest {
    /// A one-shot debug command, so waiting on the async track load is fine here.
    private static func audioTracks(_ asset: AVURLAsset) -> [AVAssetTrack] {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var tracks: [AVAssetTrack] = []
        Task.detached {
            tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            done.signal()
        }
        done.wait()
        return tracks
    }

    static func run(input: URL, output: URL, parakeet: Bool) {
        var lines: [String] = []
        let speech: LiveTranscriber = parakeet ? ParakeetLive() : AppleSpeech()
        var t: Double = 0
        var lastPartial = ""
        var partials = 0
        speech.onPartial = {
            lastPartial = $0
            partials += 1
        }
        speech.onSegment = { lines.append(String(format: "[%.1f-%.1f] %@", $0.start, $0.end, $0.text)) }
        speech.onUnavailable = { lines.append("unavailable: \($0)") }
        lines.append("engine=\(speech.engineName) available=\(speech.isAvailable)")
        speech.start(clock: { t })

        let asset = AVURLAsset(url: input)
        guard let track = audioTracks(asset).first, let reader = try? AVAssetReader(asset: asset) else {
            try? "can't read \(input.path)".write(to: output, atomically: true, encoding: .utf8)
            return
        }
        let out = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true, AVLinearPCMIsBigEndianKey: false,
            ])
        reader.add(out)
        reader.startReading()
        while let sb = out.copyNextSampleBuffer() {
            t = sb.presentationTimeStamp.seconds
            speech.append(sb)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        var finished = false
        Task {
            await speech.finish()
            finished = true
        }
        let deadline = Date().addingTimeInterval(15)
        while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        lines.append("partials=\(partials) last partial: \(lastPartial)")
        try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
    }
}
#endif
