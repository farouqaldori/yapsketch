import AVFoundation
import AppKit
import ScreenCaptureKit
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotkeys = Hotkeys()
    /// Dictation's shortcut when it's fn, which Carbon can't register.
    private let fnKey = FnKey()
    private let player = MiniPlayer()
    private let pill = StatusPill()
    private var lastPrompt: String?
    private let console = ConsoleMonitor()
    private let input = InputMonitor()
    private let tracker = AppTracker()
    private let appleSpeech = AppleSpeech()
    private let parakeet = ParakeetLive()
    private var live: LiveTranscriber?
    private var preferredLive: LiveTranscriber { parakeet.isAvailable ? parakeet : appleSpeech }

    private var overlay: OverlayController?
    private var recorder: Recorder?
    private var session: Session?
    private var clockTimer: Timer?
    private var pointerTimer: Timer?
    /// Noted while recording so processing is quicker.
    private var liveFrames: LiveFrames?
    private var recordingStartedAt: Date?
    private var stopNote: String?
    private var state: State = .idle {
        didSet {
            refreshStatus()
            syncPlayer()
        }
    }

    private enum State: Equatable {
        case idle, starting, recording
        case processing(String)
    }

    private let defaults = UserDefaults.standard
    private var systemAudio: Bool { defaults.bool(forKey: "systemAudio") }
    private var logKeystrokes: Bool { defaults.object(forKey: "logKeystrokes") as? Bool ?? true }
    private var smartPictures: Bool { defaults.object(forKey: "smartPictures") as? Bool ?? true }
    private var recordWindow: Bool { defaults.bool(forKey: "recordWindow") }
    private var copyWhenDone: Bool { defaults.object(forKey: "copyWhenDone") as? Bool ?? true }
    private var pasteWhenDone: Bool { defaults.bool(forKey: "pasteWhenDone") }
    private lazy var dictation: Dictation = MainActor.assumeIsolated { Dictation(parakeet: parakeet, hotkeys: hotkeys) }
    private var dictating: Bool { MainActor.assumeIsolated { dictation.isBusy } }

    /// YapSketch's own shortcuts, as the keystroke log writes them.
    static var ownHotkeys: Set<String> { Set(ShortcutAction.allCases.map { Shortcuts.get($0).display }) }

    static var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/YapSketch", isDirectory: true)
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ink fades unless you turn that off.
        defaults.register(defaults: ["temporaryInk": true])
        CLI.install()
        installEditMenu()
        Storage.cleanUp()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        NotificationCenter.default.addObserver(forName: .yapSketchModelChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.parakeet.reload() }
        }
        pill.onCopy = { [weak self] in self?.copyLastPrompt() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshStatus()

        registerHotkeys()
        NotificationCenter.default.addObserver(forName: .yapSketchShortcutsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotkeys() }
        }
        NotificationCenter.default.addObserver(forName: .yapSketchShortcutsSuspended, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                if n.object as? Bool == true {
                    self?.hotkeys.unregisterAll()
                    self?.fnKey.stop()
                } else {
                    self?.registerHotkeys()
                }
            }
        }

        wireInput()
        wirePlayer()
        // Hold ⌃⌥ to draw; let go to click normally again.
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in self?.modifiersChanged(e.modifierFlags) }
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.modifiersChanged(e.modifierFlags)
            return e
        }
        parakeet.prepare()
        MainActor.assumeIsolated {
            Onboarding.shared.onStartRecording = { [weak self] in self?.toggleRecording() }
            Onboarding.shared.showIfNeeded()
            Updates.shared.isBusy = { [weak self] in self.map { $0.state != .idle } ?? false }
            Updates.shared.onChange = { [weak self] in self?.refreshStatus() }
            Updates.shared.onNotice = { [weak self] in self?.showUpdateNotice($0) }
            Updates.shared.start()
        }
        Task { await finishUnfinished() }
        NotificationCenter.default.addObserver(forName: .yapSketchRetryReport, object: nil, queue: .main) { [weak self] n in
            guard let dir = n.object as? URL else { return }
            MainActor.assumeIsolated { _ = Task { await self?.retryReport(dir) } }
        }
    }

    /// A menu-bar app shows no menu bar, but ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z in its text fields still come
    /// from an Edit menu: without one, pasting an API key does nothing.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let item = NSMenuItem()
        item.submenu = edit
        let main = NSMenu()
        main.addItem(item)
        NSApp.mainMenu = main
    }

    private func registerHotkeys() {
        hotkeys.unregisterAll()
        var taken: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases {
            let id: UInt32?
            if action == .dictate, Shortcuts.get(action).isFn {
                fnKey.onPress = { [weak self] in
                    guard let self, self.state == .idle else { return }
                    MainActor.assumeIsolated { self.dictation.pressed() }
                }
                fnKey.onRelease = { [weak self] in MainActor.assumeIsolated { self?.dictation.released() } }
                // fn+← and the like: not for us after all.
                fnKey.onCombo = { [weak self] in MainActor.assumeIsolated { self?.dictation.cancel() } }
                id = fnKey.start() ? 0 : nil
            } else if action == .dictate {
                fnKey.stop()
                id = hotkeys.register(
                    Shortcuts.get(action),
                    released: { [weak self] in
                        MainActor.assumeIsolated { self?.dictation.released() }
                    }
                ) { [weak self] in
                    guard let self, self.state == .idle else { return }
                    MainActor.assumeIsolated { self.dictation.pressed() }
                }
            } else {
                id = hotkeys.register(Shortcuts.get(action)) { [weak self] in
                    switch action {
                    case .record: self?.toggleRecording()
                    case .draw: self?.toggleDraw()
                    case .clear: self?.clearDrawings()
                    case .dictate: break
                    }
                }
            }
            if id == nil { taken.insert(action) }
        }
        Shortcuts.unavailable = taken
        player.refreshTips()
    }

    // MARK: Recording

    @objc func toggleRecording() {
        switch state {
        case .idle:
            guard !dictating else { return }
            Task { await startRecording() }
        case .recording:
            // A quick double press while capture spins up shouldn't end the recording.
            if let t = recordingStartedAt, Date().timeIntervalSince(t) < 1.5 { return }
            Task { await stopRecording() }
        default: break
        }
    }

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func overlay(for screen: NSScreen) -> OverlayController {
        if let overlay { return overlay }
        let o = OverlayController(screen: screen)
        o.canvas.onAnnotation = { [weak self] info in self?.logAnnotation(info) }
        o.canvas.onClear = { [weak self] in self?.logSimple(.clear) }
        o.canvas.onErase = { [weak self] id in self?.logErase(id) }
        o.onExitDrawMode = { [weak self] in self?.setDraw(false) }
        o.onStateChange = { [weak self] in self?.syncPlayer() }
        o.canvas.fading = defaults.bool(forKey: "temporaryInk")
        o.canvas.inkSize = CGFloat(defaults.object(forKey: "inkSize") as? Double ?? 0.7)
        overlay = o
        return o
    }

    @MainActor
    private func startRecording() async {
        guard state == .idle else { return }
        guard CGPreflightScreenCaptureAccess() else {
            Onboarding.shared.show(at: .screenRecording)
            return
        }
        if Simulate.take(.noScreenRecording) { return startFailed(.screenRecording) }
        if [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio)) || Simulate.take(.noMicrophone) {
            return startFailed(.microphone)
        }
        if let free = try? FileManager.default.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
            free < 1_000_000_000 || Simulate.take(.lowSpace)
        {
            return startFailed(.space)
        }
        pill.hide()
        state = .starting

        let screen = overlay?.screen ?? currentScreen()
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return startFailed(.other("no display ID for \(screen.localizedName)"))
        }
        let screenBounds = CGDisplayBounds(displayID)
        var area = screenBounds
        if recordWindow, let frame = await Recorder.frontWindowFrame(on: displayID) { area = frame }
        let info = DisplayInfo(
            displayID: displayID, size: area.size, scale: screen.backingScaleFactor,
            globalBounds: area, screen: screenBounds)
        let ov = overlay(for: screen)

        var made: Session?
        do {
            try FileManager.default.createDirectory(at: Self.sessionsRoot, withIntermediateDirectories: true)
            let session = try Session(root: Self.sessionsRoot, display: info)
            made = session
            let recorder = Recorder()
            // A capture that starts after it was given up on (see below) touches nothing.
            recorder.onStarted = { [weak self, weak recorder] in
                DispatchQueue.main.async {
                    guard let self, self.recorder === recorder else { return }
                    self.didStartCapture()
                }
            }
            let frames = LiveFrames(
                dir: session.dir, display: info.size, clock: { [weak session] in session?.now() ?? 0 },
                pointer: { [weak session] t in session?.pointer(at: t) })
            liveFrames = frames
            recorder.onScreenFrame = { pixels in frames.add(pixels) }
            recorder.onMicBuffer = { [weak self, weak recorder] sb in
                guard let self, self.recorder === recorder else { return }
                self.live?.append(sb)
                self.pushLevel(sb)
            }
            recorder.onError = { [weak self] error in
                Log.info("capture error: \(error)")
                // Writing stopped (a full disk, a screen unplugged): save what there is.
                DispatchQueue.main.async {
                    guard let self, self.state == .recording, self.session === session else { return }
                    self.stopNote = Self.stoppedEarly(error)
                    Task { await self.stopRecording() }
                }
            }
            recorder.onStoppedUnexpectedly = { [weak self, weak recorder] in
                // E.g. "Stop Sharing" in the menu bar.
                guard let self, self.recorder === recorder else { return }
                Task { await self.stopRecording() }
            }

            self.session = session
            self.recorder = recorder
            ov.isRecording = true
            player.update(recording: true, elapsed: 0)
            player.show(on: screen)
            recordingStartedAt = Date()
            // Capture normally starts in well under a second: don't leave the toolbar up forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, self.state == .starting, self.session === session else { return }
                self.startFailed(.timedOut, session: session)
                Task { await recorder.stop() }
            }
            if Simulate.take(.cantStart) {
                throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.failedToStart.rawValue)
            }
            if Simulate.take(.slowStart) { try? await Task.sleep(nanoseconds: 25_000_000_000) }
            guard self.session === session else { return }
            try await recorder.start(
                display: info, videoURL: session.videoURL, micURL: session.micURL, systemAudio: systemAudio,
                excludingWindows: [player.windowID])
            guard state == .starting, self.session === session else {
                await recorder.stop()
                return
            }
            state = .recording
            Log.info("recording started: \(session.dir.path)")
            Sounds.play(.start)
            if Simulate.take(.stopsEarly) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    recorder.onError?(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))
                }
            }
        } catch {
            guard made == nil || self.session === made else { return }
            startFailed(StartProblem(error), session: made)
        }
    }

    private enum StartProblem {
        case screenRecording, microphone, space, timedOut
        case other(String)

        init(_ error: Error) {
            let e = error as NSError
            if e.domain == SCStreamErrorDomain, e.code == SCStreamError.userDeclined.rawValue {
                self = .screenRecording
            } else if AppDelegate.isOutOfSpace(e) {
                self = .space
            } else {
                self = .other("\(e.domain) \(e.code): \(e.localizedDescription)")
            }
        }

        var text: String {
            switch self {
            case .screenRecording: "Recording needs Screen Recording"
            case .microphone: "Recording needs the microphone"
            case .space: "Your Mac is almost out of space. Free some up to record."
            case .timedOut: "Recording didn't start. Try again."
            case .other: "Couldn't start recording. Try again."
            }
        }
    }

    @MainActor
    private func startFailed(_ problem: StartProblem, session failed: Session? = nil) {
        Log.info("start failed: \(problem)")
        overlay?.isRecording = false
        if let failed {
            try? FileManager.default.removeItem(at: failed.dir)
            liveFrames?.close()
            liveFrames = nil
        }
        session = nil
        recorder = nil
        recordingStartedAt = nil
        state = .idle
        switch problem {
        case .screenRecording:
            pill.problem(problem.text, button: "Turn On") { Onboarding.shared.show(at: .screenRecording) }
        case .microphone:
            pill.problem(problem.text, button: "Turn On") { Onboarding.shared.show(at: .microphone) }
        case .space:
            pill.problem(problem.text, button: "Storage") { SettingsWindow.shared.show(.recording) }
        case .timedOut, .other:
            pill.problem(problem.text, button: "Try Again") { [weak self] in self?.toggleRecording() }
        }
        finishPendingTermination()
    }

    static func isOutOfSpace(_ e: NSError) -> Bool {
        let all = [e] + [e.userInfo[NSUnderlyingErrorKey] as? NSError].compactMap { $0 }
        return all.contains {
            ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError)
                || ($0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC))
                || ($0.domain == AVFoundationErrorDomain && $0.code == AVError.diskFull.rawValue)
        }
    }

    /// nil when the person stopped it ("Stop Sharing" in the menu bar).
    static func stoppedEarly(_ error: Error) -> String? {
        let e = error as NSError
        if e.domain == SCStreamErrorDomain, e.code == SCStreamError.userStopped.rawValue { return nil }
        return isOutOfSpace(e) ? "Stopped early, your Mac is out of space" : "Recording stopped early"
    }

    /// First frame written: this is t = 0 for every timestamp.
    private func didStartCapture() {
        guard let session, !session.hasStarted else { return }
        session.markStart()
        var e = SessionEvent(t: 0, kind: .sessionStart)
        e.text = "display \(Int(session.display.size.width))x\(Int(session.display.size.height))pt @\(session.display.scale)x"
        session.log(e)

        tracker.start()
        input.logKeystrokes = logKeystrokes
        input.start()
        if preferredLive.isAvailable {
            live = preferredLive
            live?.start(clock: { [weak session] in session?.now() ?? 0 })
        }

        console.onError = { [weak session] message in
            guard let session else { return }
            var e = SessionEvent(t: session.now(), kind: .console)
            e.text = message
            session.log(e)
        }
        console.start(preferring: tracker.current?.url)

        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let s = self.session else { return }
            self.player.update(recording: true, elapsed: s.now())
            self.refreshStatus()
        }
        RunLoop.main.add(t, forMode: .common)
        clockTimer = t
        // The mouse pointer at 30 Hz, enough to follow it circling something.
        let p = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let s = self?.session else { return }
            // Cocoa's bottom-left origin -> Quartz's top-left.
            let m = NSEvent.mouseLocation
            let global = CGPoint(x: m.x, y: (NSScreen.screens.first?.frame.height ?? 0) - m.y)
            if s.display.contains(global) { s.addPointer(t: s.now(), at: s.display.toLocal(global)) }
        }
        RunLoop.main.add(p, forMode: .common)
        pointerTimer = p
    }

    @MainActor
    private func stopRecording() async {
        guard state == .recording, let session, let recorder else { return }
        Sounds.play(.stop)
        pill.working(anchor: player.panel.isVisible ? player.panel.frame : nil)
        state = .processing("Saving…")
        await endCapture(session, recorder)
        if Simulate.take(.quitWhileProcessing) { exit(0) }
        await finishProcessing(session)
    }

    /// `quick` uses only the live captions and video, nothing sent anywhere. `shown` puts its steps in the menu.
    private func processor(for session: Session, quick: Bool = false, shown: Bool = true) -> PostProcessor {
        var processor = PostProcessor(session: session, refineTranscript: !quick) { [weak self] msg in
            guard shown else { return }
            DispatchQueue.main.async {
                guard let self, case .processing = self.state else { return }
                self.state = .processing(msg)
            }
        }
        processor.smartPictures = !quick && smartPictures && Jev.apiKey() != nil
        return processor
    }

    /// The report within an overall limit (generous: local speech models are slow on long recordings).
    /// Past it, a quick report from the live captions.
    nonisolated private static func report(
        _ full: PostProcessor, quick: PostProcessor, length: Double, simulate: Simulate? = nil
    ) async -> (output: PostProcessor.Output, quick: Bool)? {
        if simulate == .noReport {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return nil
        }
        let slow = simulate == .slowReport
        if let out = await Deadline.run(slow ? 6 : 600 + length * 3, {
            if slow { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            return await full.run()
        }) { return (out, false) }
        Log.info("processing ran out of time: making a quick report")
        return await Deadline.run(180, { await quick.run() }).map { ($0, true) }
    }

    @MainActor
    private func cancelRecording() async {
        guard state == .recording, let session, let recorder else { return }
        state = .processing("Discarding…")
        await endCapture(session, recorder)
        try? FileManager.default.removeItem(at: session.dir)
        Log.info("recording discarded: \(session.dir.lastPathComponent)")
        self.session = nil
        self.recorder = nil
        recordingStartedAt = nil
        state = .idle
        finishPendingTermination()
    }

    @MainActor
    private func endCapture(_ session: Session, _ recorder: Recorder) async {
        setDraw(false)
        session.log(SessionEvent(t: session.now(), kind: .sessionEnd))
        clockTimer?.invalidate()
        clockTimer = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
        input.stop()
        tracker.stop()
        console.stop()

        await recorder.stop()
        liveFrames?.close()
        liveFrames = nil
        await live?.finish()
        live = nil
        overlay?.isRecording = false
        player.update(recording: false, elapsed: 0)
        overlay?.clear()
        // Let late AX lookups and final speech results land.
        try? await Task.sleep(nanoseconds: 700_000_000)
        session.close()
    }

    @MainActor
    private func finishProcessing(_ session: Session) async {
        let length = Date().timeIntervalSince(recordingStartedAt ?? Date())
        let simulate = [Simulate.slowReport, .noReport].first(where: Simulate.take)
        guard
            let (output, quick) = await Self.report(
                processor(for: session), quick: processor(for: session, quick: true), length: length, simulate: simulate)
        else {
            Log.info("no report: \(session.dir.path)")
            try? "Couldn't make the report".write(
                to: session.dir.appendingPathComponent(RecordingSummary.failureFile), atomically: true, encoding: .utf8)
            NotificationCenter.default.post(name: .yapSketchRecordingsChanged, object: nil)
            pill.problem("Couldn't make the report. The recording is saved.", button: "Show") {
                HistoryPane.reveal = "r:" + session.dir.lastPathComponent
                SettingsWindow.shared.show(.history)
                NotificationCenter.default.post(name: .yapSketchRecordingsChanged, object: nil)
            }
            endSession()
            return
        }

        let notes = [stopNote, quick ? "A quick report, the full one took too long" : nil, output.note].compactMap { $0 }
        Log.info("report ready: \(output.reportURL.path) (transcript: \(output.transcriptSource))\(notes.map { "; \($0)" }.joined())")
        let note = notes.first.map { " · \($0)" } ?? ""
        NotificationCenter.default.post(name: .yapSketchRecordingsChanged, object: nil)

        let folder = output.reportURL.deletingLastPathComponent()
        lastPrompt =
            (try? String(contentsOf: folder.appendingPathComponent("PROMPT.md"), encoding: .utf8))
            ?? "Run `yapsketch show \(folder.lastPathComponent)` to see my screen recording, then do what I ask in it."
        if pasteWhenDone, let prompt = lastPrompt {
            if await Paster.deliver(prompt, mode: copyWhenDone ? .pasteAndKeep : .paste, submit: false) {
                pill.done("Pasted into \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "the app in front")" + note)
            } else {
                pill.notice("Copied to clipboard" + note)
            }
        } else {
            if copyWhenDone { copyLastPrompt() }
            // Copy only when it isn't on the clipboard already.
            if copyWhenDone { pill.notice("Copied to clipboard" + note) } else { pill.done("Report ready" + note) }
        }
        Sounds.play(.done)
        Storage.cleanUp(keeping: session.dir)
        endSession()
    }

    private func endSession() {
        session = nil
        recorder = nil
        recordingStartedAt = nil
        stopNote = nil
        state = .idle
        finishPendingTermination()
    }

    @MainActor
    private func retryReport(_ dir: URL) async {
        let failed = dir.appendingPathComponent(RecordingSummary.failureFile)
        guard let reopened = try? Session(existing: dir) else { return }
        Log.info("making the report again: \(dir.lastPathComponent)")
        let seconds = (try? await AVURLAsset(url: reopened.videoURL).load(.duration).seconds) ?? 0
        let made = await Self.report(
            processor(for: reopened, shown: false), quick: processor(for: reopened, quick: true, shown: false), length: seconds)
        if let made {
            try? FileManager.default.removeItem(at: failed)
            Log.info("report ready: \(made.output.reportURL.path) (made again)")
        } else {
            Log.info("no report again: \(dir.path)")
        }
        NotificationCenter.default.post(name: .yapSketchRecordingsChanged, object: nil)
    }

    /// Makes reports for recordings the app quit or crashed before finishing. Each is tried
    /// once, in case making it is what crashed.
    @MainActor
    private func finishUnfinished() async {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: Self.sessionsRoot, includingPropertiesForKeys: nil)) ?? []).filter {
            fm.fileExists(atPath: $0.appendingPathComponent("session.json").path)
                && !fm.fileExists(atPath: $0.appendingPathComponent("REPORT.md").path)
                && $0.standardizedFileURL != session?.dir.standardizedFileURL
        }
        for dir in dirs {
            let video = dir.appendingPathComponent("recording.mp4")
            guard fm.fileExists(atPath: video.path) else {
                try? fm.removeItem(at: dir)
                continue
            }
            let tried = dir.appendingPathComponent(".finishing")
            // One whose report couldn't be made waits for Try Again in History.
            guard !fm.fileExists(atPath: tried.path), !fm.fileExists(atPath: dir.appendingPathComponent(RecordingSummary.failureFile).path),
                let seconds = try? await AVURLAsset(url: video).load(.duration).seconds, seconds > 0.5,
                let reopened = try? Session(existing: dir)
            else { continue }
            fm.createFile(atPath: tried.path, contents: nil)
            Log.info("finishing an unfinished recording: \(dir.lastPathComponent)")
            let made = await Self.report(
                processor(for: reopened, shown: false), quick: processor(for: reopened, quick: true, shown: false), length: seconds)
            try? fm.removeItem(at: tried)
            guard let made else { continue }
            Log.info("report ready: \(made.output.reportURL.path) (finished after relaunch)")
            NotificationCenter.default.post(name: .yapSketchRecordingsChanged, object: nil)
            guard state == .idle else { continue }
            lastPrompt = try? String(contentsOf: dir.appendingPathComponent("PROMPT.md"), encoding: .utf8)
            pill.done("Your last recording is ready")
        }
    }

    private func applySettings() {
        guard let canvas = overlay?.canvas else { return }
        let size = CGFloat(defaults.object(forKey: "inkSize") as? Double ?? 0.7)
        if canvas.inkSize != size {
            canvas.inkSize = size
            canvas.needsDisplay = true
        }
        let fade = defaults.bool(forKey: "temporaryInk")
        if canvas.fading != fade {
            canvas.fading = fade
            syncPlayer()
        }
    }

    @objc private func discardRecording() { Task { await cancelRecording() } }

    private func copyLastPrompt() {
        guard let lastPrompt else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastPrompt, forType: .string)
    }

    // MARK: Quit

    private var terminationPending = false

    /// Quitting mid-recording still finalizes the files and writes the report.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch state {
        case .idle:
            MainActor.assumeIsolated {
                if Onboarding.shared.quitIsForPermission { Onboarding.shared.reopenAfterQuit() }
            }
            return .terminateNow
        case .recording:
            terminationPending = true
            Task { await stopRecording() }
            return .terminateLater
        case .starting, .processing:
            terminationPending = true
            return .terminateLater
        }
    }

    private func finishPendingTermination() {
        guard terminationPending else { return }
        terminationPending = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    // MARK: Draw / markers

    @objc func toggleDraw() {
        // Drawing usually comes right before recording: get the speech model loading.
        parakeet.prepare()
        setDraw(!(overlay?.drawMode ?? false))
    }

    private func setDraw(_ on: Bool) {
        let ov = overlay(for: overlay?.screen ?? currentScreen())
        ov.setDrawMode(on)
        syncPlayer()
        refreshStatus()
    }

    /// Whether a global (top-left origin) point is on the mini player.
    private func isOnPlayer(_ global: CGPoint) -> Bool {
        guard player.panel.isVisible, let primary = NSScreen.screens.first else { return false }
        return player.panel.frame.contains(CGPoint(x: global.x, y: primary.frame.height - global.y))
    }

    private var holdingDraw = false

    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let f = flags.intersection(.deviceIndependentFlagsMask)
        let held = f.contains(.control) && f.contains(.option) && !f.contains(.command) && !f.contains(.shift)
        guard held != holdingDraw else { return }
        holdingDraw = held
        overlay(for: overlay?.screen ?? currentScreen()).setHolding(held)
    }

    // MARK: Mini player

    private func wirePlayer() {
        player.onTool = { [weak self] tool in
            guard let self else { return }
            guard let tool else {
                self.setDraw(false)
                return
            }
            let ov = self.overlay(for: self.overlay?.screen ?? self.currentScreen())
            ov.canvas.tool = tool
            self.setDraw(true)
        }
        player.onColor = { [weak self] i in
            self?.overlay?.canvas.colorIndex = i
            self?.syncPlayer()
        }
        player.onToggleFade = { [weak self] in
            guard let self else { return }
            let canvas = self.overlay(for: self.overlay?.screen ?? self.currentScreen()).canvas
            canvas.fading.toggle()
            self.defaults.set(canvas.fading, forKey: "temporaryInk")
            self.syncPlayer()
        }
        player.onUndo = { [weak self] in self?.overlay?.canvas.undo() }
        player.onClear = { [weak self] in self?.clearDrawings() }
        player.onRecordToggle = { [weak self] in self?.toggleRecording() }
        player.onDiscard = { [weak self] in Task { await self?.cancelRecording() } }
    }

    private func syncPlayer() {
        let drawing = overlay?.drawMode ?? false
        let canvas = overlay?.canvas
        player.sync(
            drawing: drawing, tool: canvas?.tool ?? .pen, color: canvas?.colorIndex ?? 0,
            fading: canvas?.fading ?? defaults.bool(forKey: "temporaryInk"))
        if state == .recording || state == .starting || (overlay?.sticky ?? false) {
            player.show(on: overlay?.screen ?? currentScreen())
        } else {
            player.hide()
        }
    }

    private var lastLevelPush: CFTimeInterval = 0

    /// Throttled to about 25 updates a second.
    private func pushLevel(_ sb: CMSampleBuffer) {
        let now = CACurrentMediaTime()
        guard now - lastLevelPush > 0.04 else { return }
        lastLevelPush = now
        let level = Recorder.level(sb)
        DispatchQueue.main.async { self.player.push(level: level) }
    }

    @objc func clearDrawings() {
        overlay?.clear()
    }

    private func logAnnotation(_ info: AnnotationInfo) {
        guard let session, state == .recording else { return }
        var e = SessionEvent(t: session.now(), kind: info.tool == .text ? .textNote : .annotation)
        e.tool = info.tool.rawValue
        e.color = info.color
        e.text = info.text
        // The canvas works in screen coordinates; the log uses the recorded area's.
        let offset = session.display.captureOffset
        e.bbox = [info.bbox.minX - offset.x, info.bbox.minY - offset.y, info.bbox.width, info.bbox.height].map { Double($0) }
        if let tip = info.tip {
            e.x = tip.x - offset.x
            e.y = tip.y - offset.y
        }
        e.id = info.id
        if info.duration > 0.05 { e.t0 = max(0, e.t - info.duration) }
        e.app = tracker.current?.app
        e.window = tracker.current?.window
        // What's under an arrow's tip, or the middle of the mark, so the agent can find it in code.
        let point = info.tip ?? CGPoint(x: info.bbox.midX, y: info.bbox.midY)
        let global = CGPoint(x: session.display.screen.minX + point.x, y: session.display.screen.minY + point.y)
        DispatchQueue.global(qos: .userInitiated).async {
            e.element = InputMonitor.describeElement(at: global)
            session.log(e)
        }
    }

    private func logErase(_ id: Int) {
        guard let session, state == .recording else { return }
        var e = SessionEvent(t: session.now(), kind: .erase)
        e.id = id
        session.log(e)
    }

    private func logSimple(_ kind: EventKind) {
        guard let session, state == .recording else { return }
        session.log(SessionEvent(t: session.now(), kind: kind))
    }

    // MARK: Input wiring

    private func wireInput() {
        input.clock = { [weak self] in self?.session?.now() ?? 0 }
        input.isSuppressed = { [weak self] in self?.overlay?.drawMode ?? false }

        input.onClickVisual = { [weak self] global in
            guard let self, let s = self.session, s.display.contains(global), !self.isOnPlayer(global) else { return }
            self.overlay?.ripple(atLocal: s.display.toScreen(global))
        }
        input.onClick = { [weak self] click, element in
            guard let self, let s = self.session, s.display.contains(click.global) else { return }
            var onPlayer = false
            DispatchQueue.main.sync { onPlayer = self.isOnPlayer(click.global) }
            if onPlayer { return }
            let local = s.display.toLocal(click.global)
            var e = SessionEvent(t: click.t, kind: .click)
            e.x = local.x.rounded()
            e.y = local.y.rounded()
            e.button = click.button
            e.element = element
            DispatchQueue.main.async {
                e.app = self.tracker.current?.app
                s.log(e)
            }
        }
        input.onKeys = { [weak self] t, text in
            guard let s = self?.session else { return }
            var e = SessionEvent(t: t, kind: .keys)
            e.text = text
            e.app = self?.tracker.current?.app
            s.log(e)
        }
        input.onShortcut = { [weak self] t, combo in
            guard let s = self?.session else { return }
            if Self.ownHotkeys.contains(combo) { return }
            var e = SessionEvent(t: t, kind: .shortcut)
            e.text = combo
            e.app = self?.tracker.current?.app
            s.log(e)
        }
        input.onScroll = { [weak self] t in self?.session?.log(SessionEvent(t: t, kind: .scroll)) }
        input.onKeycast = { [weak self] text in self?.overlay?.showKeycast(text) }

        tracker.onChange = { [weak self] ctx, appChanged in
            guard let s = self?.session else { return }
            var e = SessionEvent(t: s.now(), kind: appChanged ? .appSwitch : .window)
            e.app = ctx.app
            e.window = ctx.window
            e.url = ctx.url
            s.log(e)
        }

        for engine in [appleSpeech, parakeet] as [LiveTranscriber] {
            engine.onPartial = { [weak self] text in
                self?.player.setCaption(text)
            }
            engine.onSegment = { [weak self] seg in self?.session?.addLiveTranscript(seg) }
        }
        appleSpeech.onUnavailable = { [weak self] _ in
            self?.overlay?.flash("Words won't show live. Turn on Dictation in System Settings › Keyboard.")
        }
        parakeet.onUnavailable = { [weak self] reason in
            Log.info("live captions unavailable: \(reason)")
            self?.overlay?.flash("Words won't show live for this recording.")
        }
    }

    // MARK: Menu

    private func refreshStatus() {
        guard let button = statusItem?.button else { return }
        switch state {
        case .idle, .starting:
            let drawing = overlay?.drawMode ?? false
            button.image = drawing ? NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "Drawing") : StatusIcon.image
            button.title = ""
        case .recording:
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            button.title = " " + Fmt.clock(session?.now() ?? 0, decimals: false)
        case .processing:
            button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Processing")
            button.title = ""
        }
        // A waiting update: a coral dot on the icon until it's opened.
        let dot = MainActor.assumeIsolated { Updates.shared.available != nil } && (state == .idle || state == .starting)
        if dot, updateDot.superview !== button { button.addSubview(updateDot) }
        updateDot.isHidden = !dot
        let b = button.bounds
        updateDot.frame = CGRect(x: b.maxX - 9, y: button.isFlipped ? 3 : b.maxY - 10, width: 7, height: 7)
    }

    private lazy var updateDot: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Brand.coral.cgColor
        v.layer?.cornerRadius = 3.5
        return v
    }()

    private func showUpdateNotice(_ notice: Updates.Notice) {
        switch notice {
        case .upToDate(let version):
            pill.notice("You have the latest YapSketch (\(version))")
        case .failed:
            pill.problem("Couldn't update YapSketch. Try again later.", button: "Try Again") {
                MainActor.assumeIsolated { Updates.shared.checkForUpdates() }
            }
        case .updated(let release):
            pill.notice("Updated to YapSketch \(release.version)", button: "What's new") {
                MainActor.assumeIsolated { UpdateWindow.shared.show(installed: release) }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, key: String = "", mods: NSEvent.ModifierFlags = [], image: String? = nil) {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.keyEquivalentModifierMask = mods
            mi.target = self
            if let image { mi.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
            menu.addItem(mi)
        }
        let rec = Shortcuts.get(.record)
        let draw = Shortcuts.get(.draw)
        switch state {
        case .recording:
            add("Stop Recording", #selector(toggleRecording), key: rec.menuKey, mods: rec.menuModifiers, image: "stop.fill")
            add("Discard Recording", #selector(discardRecording), image: "trash")
            add(
                (overlay?.drawMode ?? false) ? "Stop Drawing" : "Draw on Screen", #selector(toggleDraw), key: draw.menuKey,
                mods: draw.menuModifiers, image: "pencil.tip")
        case .processing:
            add("Processing…", nil, image: "hourglass")
        case .idle, .starting:
            if let update = MainActor.assumeIsolated({ Updates.shared.available }) {
                let mi = NSMenuItem(title: "", action: #selector(openUpdate), keyEquivalent: "")
                mi.target = self
                mi.attributedTitle = NSAttributedString(
                    string: "YapSketch \(update.version) is ready", attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)])
                mi.image = Self.updateDotImage
                menu.addItem(mi)
                menu.addItem(.separator())
            }
            add(
                "Start Recording", state == .idle ? #selector(toggleRecording) : nil, key: rec.menuKey, mods: rec.menuModifiers,
                image: "record.circle")
            let recordings = CLI.recordings()
            if !recordings.isEmpty {
                menu.addItem(.separator())
                let copy = NSMenuItem(title: "Copy Recording", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for dir in recordings.prefix(10) {
                    let mi = NSMenuItem(title: Self.menuTitle(dir), action: #selector(copyRecording(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = dir
                    sub.addItem(mi)
                }
                copy.submenu = sub
                menu.addItem(copy)
            }
            add("History…", #selector(openHistory), key: "y", mods: .command)
        }
        if !Permission.allGranted {
            menu.addItem(.separator())
            add("Permissions needed…", #selector(openOnboarding), image: "exclamationmark.triangle")
        }
        let troubled = Providers.connected.compactMap { p in Credentials.problem(for: p.id).map { (p, $0) } }
        if !troubled.isEmpty {
            if Permission.allGranted { menu.addItem(.separator()) }
            for (p, problem) in troubled {
                let trouble: ProviderTrouble = problem == .outOfFunds ? .outOfFunds : .revoked
                add("\(trouble.sentence(p.name))…", #selector(openModels), image: "exclamationmark.triangle")
            }
        }
        if Simulate.showsMenu {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Simulate a Problem", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for kind in [nil] + Simulate.allCases.map(Optional.some) {
                let mi = NSMenuItem(title: kind?.title ?? "None", action: #selector(pickSimulated(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = kind?.rawValue
                mi.state = Simulate.pending == kind ? .on : .off
                sub.addItem(mi)
                if kind == nil { sub.addItem(.separator()) }
            }
            item.submenu = sub
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add("Settings…", #selector(openSettings), key: ",", mods: .command)
        add("Star on GitHub", #selector(starOnGitHub))
        if Updates.isEnabled { add("Check for Updates…", #selector(checkForUpdates)) }
        add("Quit YapSketch", #selector(quit), key: "q", mods: .command)
    }

    /// A menu-bar app has no other window, so reopening shows the welcome or Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !UserDefaults.standard.bool(forKey: "onboarded") || !Permission.allGranted {
                Onboarding.shared.show()
            } else {
                SettingsWindow.shared.show()
            }
        }
        return false
    }

    @objc private func openOnboarding() { MainActor.assumeIsolated { Onboarding.shared.show() } }
    @objc private func pickSimulated(_ sender: NSMenuItem) {
        Simulate.pending = (sender.representedObject as? String).flatMap(Simulate.init)
    }
    @objc private func openSettings() { MainActor.assumeIsolated { SettingsWindow.shared.show() } }
    @objc private func openModels() { MainActor.assumeIsolated { SettingsWindow.shared.show(.models) } }
    @objc private func openHistory() { MainActor.assumeIsolated { SettingsWindow.shared.show(.history) } }
    @objc private func starOnGitHub() { Links.starOnGitHub() }
    @objc private func checkForUpdates() { MainActor.assumeIsolated { Updates.shared.checkForUpdates() } }
    @objc private func openUpdate() { MainActor.assumeIsolated { UpdateWindow.shared.show() } }

    private static let updateDotImage = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { r in
        Brand.coral.setFill()
        NSBezierPath(ovalIn: CGRect(x: r.midX - 4, y: r.midY - 4, width: 8, height: 8)).fill()
        return true
    }

    @objc private func copyRecording(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? URL else { return }
        copyInstructions(dir)
    }

    private static func menuTitle(_ dir: URL) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let date = f.date(from: dir.lastPathComponent)
        let when = date.map {
            Calendar.current.isDateInToday($0)
                ? $0.formatted(date: .omitted, time: .shortened) : $0.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        } ?? dir.lastPathComponent
        let prompt = (try? String(contentsOf: dir.appendingPathComponent("PROMPT.md"), encoding: .utf8)) ?? ""
        var words = prompt.split(separator: "\n").first.map(String.init) ?? ""
        words = words.replacingOccurrences(of: #"\s*\[\d+\]"#, with: "", options: .regularExpression)
        if words.count > 48 { words = String(words.prefix(47)).trimmingCharacters(in: .whitespaces) + "…" }
        return words.isEmpty ? when : "\(when)  \(words)"
    }

    private func copyInstructions(_ dir: URL) {
        guard let prompt = try? String(contentsOf: dir.appendingPathComponent("PROMPT.md"), encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
