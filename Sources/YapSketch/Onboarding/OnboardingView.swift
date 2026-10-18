import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: Onboarding

    var body: some View {
        Group {
            switch model.step {
            case .welcome: WelcomePage(model: model)
            case .speech(let stage): SpeechPage(model: model, stage: stage)
            case .smartPictures: SmartPicturesPage(model: model)
            case .permission(let p): PermissionPage(model: model, permission: p)
            case .done: DonePage(model: model)
            }
        }
        .frame(width: 720, height: 500)
        .background(.paper)
        .ignoresSafeArea()
        .tint(.ink)
    }
}

// MARK: Welcome

private struct WelcomePage: View {
    @ObservedObject var model: Onboarding

    private var subtitle: String {
        let n = Permission.allCases.count - model.granted.count
        let words = ["no", "one", "two", "three", "four"]
        if n == 0 { return "Two quick choices, and your permissions are already on." }
        return "Two quick choices and \(words[min(n, 4)]) permission\(n == 1 ? "" : "s"). About two minutes."
    }

    private var items: [(id: String, symbol: String, title: String, purpose: String, done: Bool)] {
        [
            ("speech", "waveform", "Speech", "On your Mac or in the cloud", false),
            ("smart", "viewfinder", "Smart pictures", "Points your agent to the right spot", false),
        ] + Permission.allCases.map { p in (p.rawValue, p.symbol, p.title, p.purpose, model.granted.contains(p)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppMark(size: 60)
            Text("Show your agent what you mean.")
                .font(.serif(32)).kerning(-0.8).foregroundStyle(.ink).multilineTextAlignment(.center)
                .padding(.top, 14).padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.ui(14.5)).foregroundStyle(.soft).multilineTextAlignment(.center)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 8) {
                ForEach(items, id: \.id) { item in
                    HStack(alignment: .top, spacing: 12) {
                        if item.done {
                            DoneMark(size: 20)
                        } else {
                            Image(systemName: item.symbol).font(.system(size: 17)).foregroundStyle(.coral).frame(width: 20, height: 20)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.ui(14, .medium)).foregroundStyle(.ink)
                            Text(item.purpose).font(.ui(12.5)).foregroundStyle(.soft).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.line))
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(item.done ? "On" : "")
                }
            }
            .padding(.top, 20)
            Spacer(minLength: 12)
            HStack {
                Spacer()
                Button("Get started") { model.goNext() }.buttonStyle(.inkLarge).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 64).padding(.top, 40).padding(.bottom, 28)
    }
}

// MARK: A permission

private struct PermissionPage: View {
    @ObservedObject var model: Onboarding
    let permission: Permission

    private var on: Bool { model.granted.contains(permission) }
    private var denied: Bool { permission == .microphone && model.micDenied }
    private var waiting: Bool { !on && !model.needsReopen && model.openedSettings }
    private var dragsIn: Bool { permission != .microphone }

    var body: some View {
        HStack(spacing: 0) {
            SetupSidebar(model: model, current: .permission(permission))
            VStack(alignment: .leading, spacing: 0) {
                Stage(height: permission == .microphone && !on ? 168 : 150) { illustration }
                Text(title).font(.serif(28)).kerning(-0.5).foregroundStyle(.ink)
                    .padding(.top, 22).padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                Text(text).font(.ui(14.5)).foregroundStyle(.soft).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                if waiting && dragsIn { AppCard().padding(.top, 16) }
                if waiting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to turn it on…").font(.ui(13)).foregroundStyle(.soft)
                    }
                    .padding(.top, 14)
                }
                if on { Banner(text: banner).padding(.top, 16) }
                if model.needsReopen { Banner(text: "Screen Recording is on").padding(.top, 16) }
                Spacer(minLength: 12)
                footer
            }
            .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 28)
        }
    }

    @ViewBuilder private var illustration: some View {
        if on || model.needsReopen {
            SettingsListPicture(permission: permission, on: true)
        } else if permission == .microphone && !denied {
            MicPromptPicture()
        } else {
            SettingsListPicture(permission: permission, on: false)
        }
    }

    private var title: String {
        if on { return "That's it, it's on." }
        if model.needsReopen { return "Now reopen YapSketch." }
        if waiting && dragsIn { return "Drag YapSketch into the list." }
        switch permission {
        case .microphone: return denied ? "Turn the microphone back on." : "Let YapSketch hear you."
        case .screenRecording: return "Let YapSketch see your screen."
        case .accessibility: return "Let YapSketch paste for you."
        case .inputMonitoring: return "Let your shortcuts work everywhere."
        }
    }

    private var text: String {
        if on {
            switch permission {
            case .microphone: return "YapSketch can hear you now."
            case .screenRecording: return "YapSketch can see your screen, only while you're recording."
            case .accessibility: return "YapSketch can now paste where you're typing."
            case .inputMonitoring: return "Your shortcuts now work in every app."
            }
        }
        if model.needsReopen {
            return "macOS needs YapSketch to restart before it can see your screen. It'll reopen right here."
        }
        if waiting {
            return dragsIn
                ? "In System Settings, drag this card into the \(permission.settingsTitle) list, then turn YapSketch on."
                : "In System Settings, turn YapSketch on under Microphone."
        }
        switch permission {
        case .microphone:
            return denied
                ? "The microphone is off for YapSketch. Turn it back on in System Settings."
                : "Talk instead of typing. Your words become text, right on your Mac."
        case .screenRecording:
            return "Your agent sees exactly what you show it. YapSketch only records while you're recording."
        case .accessibility:
            return "Your prompt lands straight in your agent, and it knows exactly what you clicked or circled."
        case .inputMonitoring:
            return "Start recording or dictating from any app, with one shortcut."
        }
    }

    private var banner: String {
        let left = Permission.allCases.filter { !model.granted.contains($0) }.count
        let then = left == 0 ? "That's all four." : left == 1 ? "Moving on to the last one…" : "Moving on…"
        return "\(permission.title) is on. \(then)"
    }

    @ViewBuilder private var footer: some View {
        if waiting {
            HStack(spacing: 8) {
                Button("Back") { model.goBack() }.buttonStyle(TextButtonStyle(color: .soft))
                Spacer(minLength: 8)
                Button("Open Settings again") { model.openSettings(permission) }.buttonStyle(TextButtonStyle())
                if dragsIn {
                    Button("Show the app in Finder") { model.showInFinder() }
                        .buttonStyle(.paperLarge)
                        .help("Can't drag? Shows YapSketch.app in Finder, to add with the + button in System Settings.")
                }
            }
        } else {
            HStack {
                Button("Back") { model.goBack() }.buttonStyle(TextButtonStyle(color: .soft))
                Spacer()
                if on {
                    Button("Continue") { model.goNext() }.buttonStyle(.inkLarge).keyboardShortcut(.defaultAction)
                } else if model.needsReopen {
                    Button("Quit & Reopen") { model.reopen() }.buttonStyle(.inkLarge).keyboardShortcut(.defaultAction)
                } else if permission == .microphone && !denied {
                    Button("Allow microphone") { model.ask(permission) }.buttonStyle(.inkLarge).keyboardShortcut(.defaultAction)
                } else {
                    Button("Open System Settings") { model.ask(permission) }.buttonStyle(.inkLarge).keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

enum SetupItem: Hashable {
    case speech, smartPictures
    case permission(Permission)

    static var all: [SetupItem] { [.speech, .smartPictures] + Permission.allCases.map { .permission($0) } }
}

struct SetupSidebar: View {
    @ObservedObject var model: Onboarding
    @ObservedObject private var store = ModelStore.shared
    let current: SetupItem

    var body: some View {
        let items = SetupItem.all
        let index = (items.firstIndex(of: current) ?? 0) + 1
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Setup · \(index) of \(items.count)").padding(.horizontal, 6).padding(.bottom, 10)
            ForEach(items, id: \.self) { item in
                let here = item == current
                let done = isDone(item)
                Button {
                    switch item {
                    case .speech: model.step = .speech(.choose)
                    case .smartPictures: model.step = .smartPictures
                    case .permission(let p): model.step = .permission(p)
                    }
                } label: {
                    HStack(spacing: 10) {
                        if item == .speech, !model.useCloud, let p = store.progress[model.localModel] {
                            ProgressRing(value: p).frame(width: 18, height: 18)
                        } else if done {
                            DoneMark()
                        } else {
                            Circle().strokeBorder(here ? .coral : .faint, lineWidth: here ? 2 : 1.5).frame(width: 18, height: 18)
                        }
                        Text(title(item)).font(.ui(13.5, here ? .medium : .regular)).foregroundStyle(here || done ? .ink : .soft)
                        Spacer(minLength: 0)
                        if item == .speech, !model.useCloud, let p = store.progress[model.localModel] {
                            Text("\(Int(p * 100))%").font(.mono(11)).foregroundStyle(.soft)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 9).fill(here ? .card : .clear).shadow(color: .shade.opacity(here ? 0.08 : 0), radius: 1, y: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(done ? "Done" : "Not done yet")
                .accessibilityAddTraits(here ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, 52)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(.panel)
    }

    private func title(_ item: SetupItem) -> String {
        switch item {
        case .speech: "Speech"
        case .smartPictures: "Smart pictures"
        case .permission(let p): p.title
        }
    }

    private func isDone(_ item: SetupItem) -> Bool {
        switch item {
        case .speech: model.useCloud ? CloudSpeech.selected() != nil : store.installed.contains(model.localModel)
        case .smartPictures: Jev.route() != nil
        case .permission(let p): model.granted.contains(p)
        }
    }
}

struct ProgressRing: View {
    let value: Double

    var body: some View {
        ZStack {
            Circle().stroke(.line, lineWidth: 2)
            Circle().trim(from: 0, to: value).stroke(.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
        }
        .padding(1)
        .accessibilityHidden(true)
    }
}

// MARK: Done

private struct DonePage: View {
    @ObservedObject var model: Onboarding
    @State private var opensAtLogin = LoginItem.isOn

    var body: some View {
        let on = model.granted.count
        let all = Permission.allCases.count
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DoneMark(size: 14)
                Text(on == all ? "All four permissions are on" : "\(on) of \(all) permissions are on").font(.ui(12.5, .medium))
            }
            .foregroundStyle(.doneText)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.doneWash))
            Text("You're set. Try it now.")
                .font(.serif(34)).kerning(-0.8).foregroundStyle(.ink)
                .padding(.top, 18).padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            Text("These shortcuts work in every app. Click one to change it.").font(.ui(15)).foregroundStyle(.soft)
            HStack(alignment: .top, spacing: 10) {
                ShortcutRecorder(action: .record, card: "Record and talk")
                ShortcutRecorder(action: .draw, card: "Draw on screen")
                ShortcutRecorder(action: .dictate, card: "Hold to dictate")
            }
            .padding(.top, 26)
            BrandRow("Open YapSketch when you log in", subtitle: "It waits in the menu bar", isOn: $opensAtLogin)
                .onChange(of: opensAtLogin) { LoginItem.set(opensAtLogin) }
                .background(RoundedRectangle(cornerRadius: 14).fill(.card))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.line))
                .padding(.top, 16)
            Spacer(minLength: 12)
            HStack {
                Text("You can also change them later in Settings.").font(.ui(12.5)).foregroundStyle(.soft)
                Spacer(minLength: 12)
                Button("Start my first recording") { model.startRecording() }.buttonStyle(.inkLarge)
            }
        }
        .padding(.horizontal, 64).padding(.top, 44).padding(.bottom, 28)
        .onAppear {
            LoginItem.offerOnce()
            opensAtLogin = LoginItem.isOn
        }
    }
}

// MARK: Pieces

struct AppCard: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            AppMark(size: compact ? 30 : 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("YapSketch").font(.ui(compact ? 14 : 14.5, .semibold)).foregroundStyle(.ink)
                if !compact { Text("Drag me into the list").font(.ui(12.5)).foregroundStyle(.soft) }
            }
            Spacer(minLength: 8)
            Grip()
        }
        .padding(.horizontal, compact ? 12 : 14).padding(.vertical, compact ? 10 : 12)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: compact ? 12 : 14).fill(.line).offset(y: 2)
                RoundedRectangle(cornerRadius: compact ? 12 : 14).fill(.card)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 14).strokeBorder(.ink, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: Bundle.main.bundleURL as NSURL)
        } preview: {
            AppMark(size: 48)
        }
        .help("Drag into the list in System Settings")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("YapSketch app")
        .accessibilityHint("Drag into the list in System Settings")
    }
}

private struct Grip: View {
    var body: some View {
        Grid(horizontalSpacing: 3.2, verticalSpacing: 2.2) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow {
                    Circle().fill(.grip).frame(width: 2.8, height: 2.8)
                    Circle().fill(.grip).frame(width: 2.8, height: 2.8)
                }
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

private struct Stage<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ZStack { content }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 16).fill(
                    RadialGradient(colors: [.paper, .panel], center: .top, startRadius: 0, endRadius: 260))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityHidden(true)
    }
}

private struct MicPromptPicture: View {
    var body: some View {
        VStack(spacing: 8) {
            AppMark(size: 34)
            Text("“YapSketch” would like to access the microphone.")
                .font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center).foregroundStyle(.black)
            HStack(spacing: 8) {
                Text("Don't Allow").frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .quaternaryLabelColor)))
                Text("Allow").foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .systemBlue)))
                    .overlay(Doodle.circle.stroke(.coral, style: StrokeStyle(lineWidth: 2.6, lineCap: .round)).frame(width: 96, height: 54))
            }
            .font(.system(size: 12))
            .foregroundStyle(.black)
        }
        .padding(16)
        .frame(width: 244)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.92)).shadow(color: .black.opacity(0.14), radius: 15, y: 12))
    }
}

private struct SettingsListPicture: View {
    let permission: Permission
    let on: Bool

    private var neighbour: String {
        switch permission {
        case .microphone, .screenRecording: "Zoom"
        case .accessibility: "Raycast"
        case .inputMonitoring: "Karabiner"
        }
    }

    var body: some View {
        if on {
            list
        } else {
            HStack(alignment: .center, spacing: 0) {
                HStack(spacing: 7) {
                    AppMark(size: 22)
                    Text("YapSketch").font(.ui(11.5, .medium)).foregroundStyle(.ink)
                }
                .padding(.leading, 7).padding(.trailing, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 10).fill(.card).shadow(color: .shade.opacity(0.18), radius: 9, y: 8))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.ink, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                .rotationEffect(.degrees(-4))
                .offset(y: 22)
                Doodle.arrow.stroke(.coral, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 66, height: 44)
                    .padding(.horizontal, 2)
                list
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(permission.settingsTitle).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.black.opacity(0.78))
                .lineLimit(1).padding(.horizontal, 2)
            if on {
                row(mark: true, name: "YapSketch").overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.done, lineWidth: 1.5))
                row(mark: false, name: neighbour)
            } else {
                row(mark: false, name: neighbour)
                Text("Drop it here").font(.system(size: 10.5)).foregroundStyle(.coral).frame(maxWidth: .infinity).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.coral, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            }
        }
        .padding(10)
        .frame(width: on ? 262 : 210)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white).shadow(color: .black.opacity(0.12), radius: 13, y: 10))
    }

    private func row(mark: Bool, name: String) -> some View {
        HStack(spacing: 8) {
            if mark {
                AppMark(size: 18)
            } else {
                RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .systemGray).opacity(0.45)).frame(width: 18, height: 18)
            }
            Text(name).font(.system(size: 11, weight: mark ? .medium : .regular)).foregroundStyle(.black)
            Spacer()
            Capsule().fill(Color(nsColor: .systemGreen)).frame(width: 28, height: 16)
                .overlay(alignment: .trailing) { Circle().fill(.white).frame(width: 12, height: 12).padding(2) }
        }
        .padding(.horizontal, 7).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(mark ? Color.doneWash : Color.black.opacity(0.035)))
    }
}

private enum Doodle {
    static let circle = Scaled(size: CGSize(width: 96, height: 54)) { p in
        p.move(to: CGPoint(x: 78, y: 10))
        p.addCurve(to: CGPoint(x: 8, y: 18), control1: CGPoint(x: 60, y: 0), control2: CGPoint(x: 18, y: 2))
        p.addCurve(to: CGPoint(x: 48, y: 48), control1: CGPoint(x: 0, y: 32), control2: CGPoint(x: 16, y: 48))
        p.addCurve(to: CGPoint(x: 90, y: 24), control1: CGPoint(x: 80, y: 48), control2: CGPoint(x: 94, y: 38))
        p.addCurve(to: CGPoint(x: 50, y: 9), control1: CGPoint(x: 86, y: 12), control2: CGPoint(x: 66, y: 8))
    }

    static let arrow = Scaled(size: CGSize(width: 90, height: 60)) { p in
        p.move(to: CGPoint(x: 6, y: 34))
        p.addCurve(to: CGPoint(x: 78, y: 18), control1: CGPoint(x: 24, y: 10), control2: CGPoint(x: 52, y: 6))
        p.move(to: CGPoint(x: 68, y: 10))
        p.addLine(to: CGPoint(x: 78, y: 18))
        p.addLine(to: CGPoint(x: 67, y: 24))
    }

    /// A path drawn on a fixed grid, stretched to the frame it's given.
    struct Scaled: Shape {
        let size: CGSize
        let draw: @Sendable (inout Path) -> Void
        func path(in rect: CGRect) -> Path {
            var p = Path()
            draw(&p)
            return p.applying(CGAffineTransform(scaleX: rect.width / size.width, y: rect.height / size.height))
        }
    }
}
