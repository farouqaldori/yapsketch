import AppKit
import SwiftUI

// MARK: Speech

struct SpeechPage: View {
    @ObservedObject var model: Onboarding
    let stage: Onboarding.SpeechStage

    var body: some View {
        HStack(spacing: 0) {
            SetupSidebar(model: model, current: .speech)
            Group {
                switch stage {
                case .choose: SpeechChoice(model: model)
                case .localModels: LocalModels(model: model)
                case .downloading: Downloading(model: model)
                case .cloud: CloudProviders(model: model)
                case .cloudModels: CloudModels(model: model)
                }
            }
            .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 28)
        }
    }
}

private struct SpeechChoice: View {
    @ObservedObject var model: Onboarding
    @State private var cloud = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupTitle("Where should your words turn into text?")
            Text("You can switch any time in Settings.").font(.ui(14)).foregroundStyle(.soft).padding(.top, 8)
            VStack(spacing: 10) {
                ChoiceCard(
                    symbol: "laptopcomputer", title: "On this Mac", tag: "Recommended",
                    text: "Private and free, and it works offline. A one-time download.", selected: !cloud
                ) { cloud = false }
                ChoiceCard(
                    symbol: "cloud", title: "In the cloud", tag: nil,
                    text: "More languages, most accurate. Needs an Opper or OpenRouter account.", selected: cloud
                ) { cloud = true }
            }
            .padding(.top, 20)
            Spacer(minLength: 12)
            HStack {
                Button("Back") { model.goBack() }.buttonStyle(TextButtonStyle(color: .soft))
                Spacer()
                Button("Continue") { model.step = .speech(cloud ? .cloud : .localModels) }
                    .buttonStyle(.inkLarge).keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { cloud = model.useCloud }
    }
}

private struct LocalModels: View {
    @ObservedObject var model: Onboarding
    @ObservedObject private var store = ModelStore.shared

    var body: some View {
        let picked = ModelStore.catalog.first { $0.id == model.localModel } ?? ModelStore.catalog[0]
        VStack(alignment: .leading, spacing: 0) {
            SetupTitle("Pick a model to download.")
            Text("They all run on your Mac. You can add others later.").font(.ui(14)).foregroundStyle(.soft).padding(.top, 6)
            RowsCard {
                ForEach(Array(ModelStore.catalog.enumerated()), id: \.element.id) { i, m in
                    if i > 0 { RowRule() }
                    Button {
                        model.localModel = m.id
                    } label: {
                        HStack(spacing: 12) {
                            Radio(on: m.id == picked.id)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 8) {
                                    Text(m.name).font(.ui(13.5, m.id == picked.id ? .medium : .regular)).foregroundStyle(.ink)
                                    if m.id == "parakeet-unified" { Tag("Recommended") }
                                }
                                Text(m.detail).font(.ui(12)).foregroundStyle(.soft)
                            }
                            Spacer(minLength: 8)
                            Text(store.installed.contains(m.id) ? "On your Mac" : m.size).font(.mono(11.5)).foregroundStyle(.soft)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(m.id == picked.id ? .isSelected : [])
                }
            }
            .padding(.top, 14)
            Spacer(minLength: 10)
            HStack {
                Button("Back") { model.goBack() }.buttonStyle(TextButtonStyle(color: .soft))
                Spacer()
                Button(store.installed.contains(picked.id) ? "Continue" : "Download and continue") { model.pickLocal(picked) }
                    .buttonStyle(.inkLarge).keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct Downloading: View {
    @ObservedObject var model: Onboarding
    @ObservedObject private var store = ModelStore.shared

    var body: some View {
        let m = ModelStore.catalog.first { $0.id == model.localModel } ?? ModelStore.catalog[0]
        let done = store.installed.contains(m.id)
        let failed = store.failed[m.id]
        let p = store.progress[m.id] ?? (done ? 1 : 0)
        VStack(alignment: .leading, spacing: 0) {
            SetupStage(height: 150) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(m.name).font(.ui(14, .medium)).foregroundStyle(.ink)
                        Spacer()
                        Text(done ? "Ready" : "\(Int(p * 100))%").font(.mono(12)).foregroundStyle(done ? .doneText : .soft)
                    }
                    Text(m.detail).font(.ui(12)).foregroundStyle(.soft).padding(.top, 3)
                    Bar(value: p).padding(.top, 12)
                    Text(failed ?? sizes(m, p, done)).font(.mono(11.5)).foregroundStyle(failed == nil ? .soft : .coralText).padding(.top, 8)
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .frame(width: 330)
                .background(RoundedRectangle(cornerRadius: 14).fill(.card))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.line))
            }
            SetupTitle(done ? "Your speech model is ready." : failed != nil ? "The download stopped." : "Downloading your speech model.")
                .padding(.top, 22)
            Text(
                done
                    ? "It runs on your Mac, even offline."
                    : failed != nil
                        ? "Try again, or carry on and download it later in Settings › Models. Until then there's nothing to turn speech into text."
                        : "It keeps going in the background while you set up the rest."
            )
                .font(.ui(14)).foregroundStyle(.soft).padding(.top, 8)
            Spacer(minLength: 12)
            HStack {
                Button("Back") { model.goBack() }.buttonStyle(TextButtonStyle(color: .soft))
                Spacer()
                if failed != nil {
                    Button("Try again") { store.download(m) }.buttonStyle(.paperLarge)
                }
                Button("Continue") { model.goNext() }.buttonStyle(.inkLarge).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func sizes(_ m: SpeechModel, _ p: Double, _ done: Bool) -> String {
        if done { return m.size }
        let got = ByteCountFormatter.string(fromByteCount: Int64(Double(m.bytes) * p), countStyle: .file)
        return "\(got) of \(m.size)"
    }
}

private struct CloudProviders: View {
    @ObservedObject var model: Onboarding
    @State private var chosen: String?
    @State private var known: Set<String> = []
    @State private var revision = 0

    private var accounts: [Account] { Accounts.shared.all.filter { !$0.provider.speech.isEmpty } }
    private var connected: [String] { accounts.filter(\.provider.isConnected).map(\.id) }

    var body: some View {
        let connected = connected
        let pick = chosen.flatMap { connected.contains($0) ? $0 : nil } ?? connected.last
        VStack(alignment: .leading, spacing: 0) {
            SetupTitle("Connect a speech provider.")
            Text("Sign in with an account you have, or make one. Your audio goes to the provider you pick, and they bill you for it.")
                .font(.ui(14)).foregroundStyle(.soft).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            VStack(spacing: 8) {
                ForEach(accounts) { account in
                    ProviderRow(
                        account: account, primary: connected.isEmpty, choosable: connected.count > 1,
                        chosen: pick == account.id
                    ) { chosen = account.id }
                }
            }
            .padding(.top, 20)
            ErrorLine(accounts: accounts)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button("Back") { model.goBack() }.buttonStyle(TextButtonStyle(color: .soft))
                Spacer()
                Button("Use this Mac instead") { model.step = .speech(.localModels) }.buttonStyle(TextButtonStyle())
                Button(pick.flatMap { Providers.named($0)?.name }.map { "Continue with \($0)" } ?? "Continue") {
                    model.cloudProvider = pick
                    model.step = .speech(.cloudModels)
                }
                .buttonStyle(.inkLarge).keyboardShortcut(.defaultAction)
                .disabled(pick == nil)
            }
        }
        .id(revision)
        .onAppear {
            known = Set(connected)
            chosen = model.cloudProvider
        }
        .onReceive(NotificationCenter.default.publisher(for: .yapSketchAccountsChanged)) { _ in
            let now = Set(self.connected)
            if let new = now.subtracting(known).first { chosen = new }
            known = now
            revision += 1
        }
    }
}

private struct CloudModels: View {
    @ObservedObject var model: Onboarding
    @State private var picked: String?

    var body: some View {
        let provider = Providers.named(model.cloudProvider)
        let offers = provider?.speech ?? []
        let current = picked ?? CloudSpeech.selected().flatMap { $0.providerID == provider?.id ? $0.model : nil } ?? offers.first?.model
        VStack(alignment: .leading, spacing: 0) {
            SetupTitle("Pick a speech model.")
            RowsCard {
                ForEach(Array(offers.enumerated()), id: \.element.model) { i, offer in
                    if i > 0 { RowRule() }
                    Button {
                        picked = offer.model
                    } label: {
                        HStack(spacing: 12) {
                            Radio(on: offer.model == current)
                            Text(offer.name).font(.ui(13.5, offer.model == current ? .medium : .regular)).foregroundStyle(.ink)
                            Spacer(minLength: 8)
                            Text(offer.detail).font(.ui(12)).foregroundStyle(.soft)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(offer.model == current ? .isSelected : [])
                }
            }
            .padding(.top, 18)
            if let provider {
                HStack(spacing: 8) {
                    ProviderMark(id: provider.id, name: provider.name, size: 16)
                    Text("Through your \(provider.name) account").font(.ui(12.5)).foregroundStyle(.soft)
                    Button("Change") { model.step = .speech(.cloud) }.buttonStyle(.plain).font(.ui(12.5)).foregroundStyle(.ink).underline()
                }
                .padding(.top, 12)
                if ModelStore.shared.installed.isEmpty {
                    Text("A small model downloads to your Mac too, for when \(provider.name) can't be reached.")
                        .font(.ui(12.5)).foregroundStyle(.soft).padding(.top, 6)
                }
            }
            Spacer(minLength: 12)
            HStack {
                Button("Back") { model.goBack() }.buttonStyle(TextButtonStyle(color: .soft))
                Spacer()
                Button("Continue") {
                    guard let provider, let offer = offers.first(where: { $0.model == current }) else { return }
                    model.pickCloud(CloudModel(providerID: provider.id, model: offer.model, name: offer.name, detail: offer.detail))
                }
                .buttonStyle(.inkLarge).keyboardShortcut(.defaultAction)
                .disabled(current == nil)
            }
        }
    }
}

// MARK: Smart pictures

struct SmartPicturesPage: View {
    @ObservedObject var model: Onboarding
    @State private var chosen: String?
    @State private var known: Set<String> = []
    @State private var revision = 0

    private var accounts: [Account] { Accounts.shared.all.filter { $0.provider.jev != nil } }
    private var connected: [String] { accounts.filter(\.provider.isConnected).map(\.id) }

    var body: some View {
        HStack(spacing: 0) {
            SetupSidebar(model: model, current: .smartPictures)
            Group {
                if let route = Jev.route(), Credentials.problem(for: route.provider.id) == nil, !model.showJevAccounts {
                    on(route.provider)
                } else {
                    list
                }
            }
            .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 28)
        }
        .id(revision)
        .onAppear {
            known = Set(connected)
            chosen = Jev.route()?.provider.id
        }
        .onReceive(NotificationCenter.default.publisher(for: .yapSketchAccountsChanged)) { _ in
            let now = Set(self.connected)
            if let new = now.subtracting(known).first { chosen = new }
            known = now
            revision += 1
        }
    }

    private func on(_ provider: any Provider) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SetupStage(height: 150) { NumberedPictureExample() }
            SetupTitle("Smart pictures are on.").padding(.top, 22)
            Text(
                "Jev runs through your \(provider.name) account. It ties each thing you say to the spot you marked, so your agent finds what you mean faster and spends fewer tokens."
            )
            .font(.ui(14)).foregroundStyle(.soft).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            HStack(spacing: 10) {
                ProviderMark(id: provider.id, name: provider.name, size: 20)
                Text("Jev with \(provider.name)").font(.ui(13.5, .medium)).foregroundStyle(.doneText)
                Spacer()
                Button("Use another account") { model.showJevAccounts = true }.buttonStyle(.plain).font(.ui(12.5)).foregroundStyle(.doneText)
                    .underline()
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12).fill(.doneWash))
            .padding(.top, 16)
            Spacer(minLength: 12)
            HStack {
                Button("Back") { model.goBack() }.buttonStyle(TextButtonStyle(color: .soft))
                Spacer()
                Button("Continue") {
                    model.useJev(provider.id)
                    model.goNext()
                }
                .buttonStyle(.inkLarge).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var list: some View {
        let connected = connected
        let pick = chosen.flatMap { connected.contains($0) ? $0 : nil } ?? connected.last
        return VStack(alignment: .leading, spacing: 0) {
            SetupStage(height: 104) { NumberedPictureExample(compact: true) }
            SetupTitle("Turn on smart pictures.").padding(.top, 16)
            Text(
                "Your agent finds what you mean faster and spends fewer tokens. Connect one of these accounts to use Jev."
            )
            .font(.ui(13.5)).foregroundStyle(.soft).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            RowsCard {
                ForEach(Array(accounts.enumerated()), id: \.element.id) { i, account in
                    if i > 0 { RowRule() }
                    ProviderRow(
                        account: account, primary: false, choosable: connected.count > 1, chosen: pick == account.id, compact: true
                    ) { chosen = account.id }
                }
            }
            .padding(.top, 12)
            ErrorLine(accounts: accounts)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button("Back") { model.goBack() }.buttonStyle(TextButtonStyle(color: .soft))
                Spacer()
                if pick == nil {
                    Button("Skip for now") { model.goNext() }.buttonStyle(TextButtonStyle())
                }
                Button("Continue") {
                    guard let pick else { return }
                    model.useJev(pick)
                    model.goNext()
                }
                .buttonStyle(.inkLarge).keyboardShortcut(.defaultAction)
                .disabled(pick == nil)
            }
        }
    }
}

// MARK: Pieces

private struct SetupTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.serif(28)).kerning(-0.5).foregroundStyle(.ink).fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct SetupStage<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ZStack { content }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 16).fill(RadialGradient(colors: [.paper, .panel], center: .top, startRadius: 0, endRadius: 260))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityHidden(true)
    }
}

private struct ChoiceCard: View {
    let symbol: String
    let title: String
    let tag: String?
    let text: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(selected ? .coral : .soft).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).font(.ui(15, .medium)).foregroundStyle(.ink)
                        if let tag { Tag(tag) }
                    }
                    Text(text).font(.ui(13)).foregroundStyle(.soft).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Radio(on: selected)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? .ink : .line, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A pasted-key provider turns the row itself into the field, at the same height.
private struct ProviderRow: View {
    @ObservedObject var account: Account
    let primary: Bool
    let choosable: Bool
    let chosen: Bool
    var compact = false
    var note: String?
    let choose: () -> Void

    @State private var entering = false
    @State private var key = ""
    @State private var checking = false
    @State private var problem: String?
    @FocusState private var keyFocused: Bool

    private var connected: Bool { if case .connected = account.state { true } else { false } }
    private var signingIn: Bool { if case .signingIn = account.state { true } else { false } }

    var body: some View {
        let row = HStack(spacing: compact ? 10 : 12) {
            ProviderMark(id: account.id, name: account.provider.name, size: compact ? 26 : 32)
            if entering, case .apiKey(let getOne, _) = account.provider.connect {
                keyField(getOne)
            } else {
                HStack(spacing: 4) {
                    Text(account.provider.name).font(.ui(compact ? 14 : 14.5, .medium)).foregroundStyle(.ink)
                    if let note, !signingIn { Text("· \(note)").font(.ui(12.5)).foregroundStyle(.soft) }
                }
                .lineLimit(1)
                .fixedSize()
                Spacer(minLength: 8)
                trailing
            }
        }
        // One height whatever the row shows (Connect, the key field, waiting, Connected).
        .padding(.horizontal, 14)
        .frame(height: compact ? 46 : 58)

        if choosable && connected {
            Button(action: choose) {
                row.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background { if !compact { RoundedRectangle(cornerRadius: 14).fill(.card) } }
            .overlay { if !compact { RoundedRectangle(cornerRadius: 14).strokeBorder(chosen ? .ink : .line, lineWidth: 1.5) } }
            .accessibilityAddTraits(chosen ? .isSelected : [])
        } else {
            row
                .background { if !compact { RoundedRectangle(cornerRadius: 14).fill(.card) } }
                .overlay { if !compact { RoundedRectangle(cornerRadius: 14).strokeBorder(.line) } }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch account.state {
        case .connected:
            if let problem = account.problem {
                HStack(spacing: 6) {
                    Circle().fill(.coral).frame(width: 7, height: 7)
                    Text(problem == .outOfFunds ? (account.provider.billing?.empty ?? "Out of credits") : "Needs reconnecting")
                        .font(.ui(13, .medium)).foregroundStyle(.coralText).lineLimit(1)
                }
                if problem == .outOfFunds, let billing = account.provider.billing {
                    Button(billing.topUp) { NSWorkspace.shared.open(billing.url) }.buttonStyle(.paper)
                } else if problem == .disconnected {
                    Button("Reconnect") {
                        if case .apiKey = account.provider.connect { entering = true } else { account.signIn() }
                    }
                    .buttonStyle(.paper)
                }
            } else {
                HStack(spacing: 6) {
                    DoneMark(size: 15)
                    Text("Connected").font(.ui(13, .medium)).foregroundStyle(.doneText)
                }
            }
            if choosable {
                Radio(on: chosen).padding(.leading, 6)
            } else {
                Menu {
                    Button("Disconnect") { account.disconnect() }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(.soft)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(account.provider.name) options")
            }
        case .signingIn(let page):
            if let code = page?.code {
                Text(code).font(.mono(12.5, .medium)).foregroundStyle(.ink).fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.panel))
                    .help("Check this code matches the one in your browser, then approve there")
            } else {
                Text("Waiting for your browser").font(.ui(12.5)).foregroundStyle(.soft).lineLimit(1)
            }
            ProgressView().controlSize(.small)
            Button("Cancel") { account.cancel() }.buttonStyle(.paper)
        case .off:
            Button("Connect") {
                if case .apiKey = account.provider.connect {
                    entering = true
                } else {
                    account.signIn()
                }
            }
            .buttonStyle(InkOrPaper(ink: primary))
        }
    }

    private func keyField(_ getOne: URL) -> some View {
        HStack(spacing: 10) {
            SecureField("API key", text: $key, prompt: Text("Paste your \(account.provider.name) API key").foregroundColor(.faint))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.ui(13))
                .foregroundStyle(.ink)
                .focused($keyFocused)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(.paper))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(problem != nil ? .coral : keyFocused ? .ink : .line, lineWidth: keyFocused || problem != nil ? 1.5 : 1)
                )
                .onAppear { keyFocused = true }
                .onSubmit(save)
                .onExitCommand {
                    entering = false
                    key = ""
                    problem = nil
                }
            if checking {
                ProgressView().controlSize(.small)
            } else if let problem {
                Text(problem).font(.ui(12)).foregroundStyle(.coralText).lineLimit(1).help(problem)
            } else {
                Link(destination: getOne) { Text("Get a key").underline() }.font(.ui(12.5)).foregroundStyle(.soft).fixedSize()
            }
            Button("Save", action: save).buttonStyle(.ink).disabled(key.isEmpty || checking)
        }
    }

    private func save() {
        checking = true
        problem = nil
        Task {
            let result = await account.save(key: key)
            checking = false
            if result == .works || result == .outOfFunds {
                entering = false
                key = ""
            } else {
                problem = result.message(account.provider.name)
            }
        }
    }
}

private struct InkOrPaper: ButtonStyle {
    let ink: Bool
    func makeBody(configuration: Configuration) -> some View {
        if ink {
            InkButtonStyle().makeBody(configuration: configuration)
        } else {
            PaperButtonStyle().makeBody(configuration: configuration)
        }
    }
}

private struct ErrorLine: View {
    let accounts: [Account]
    var body: some View {
        if let error = accounts.compactMap(\.error).first {
            Text(error).font(.ui(12.5)).foregroundStyle(.coralText).padding(.top, 8)
        }
    }
}

private struct RowsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 14).fill(.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.line))
    }
}

private struct RowRule: View {
    var body: some View { Rectangle().fill(.line).frame(height: 1).padding(.horizontal, 14) }
}

private struct Radio: View {
    let on: Bool
    var body: some View {
        ZStack {
            if on {
                Circle().fill(.ink)
                Circle().fill(.card).frame(width: 6, height: 6)
            } else {
                Circle().strokeBorder(.faint, lineWidth: 1.5)
            }
        }
        .frame(width: 17, height: 17)
        .accessibilityHidden(true)
    }
}

private struct Tag: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.mono(9.5, .medium)).kerning(0.8).foregroundStyle(.doneText)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(.doneWash))
    }
}

private struct Bar: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.rule)
                Capsule().fill(.ink).frame(width: max(6, g.size.width * value))
            }
        }
        .frame(height: 6)
    }
}

private struct NumberedPictureExample: View {
    var compact = false

    var body: some View {
        let s: CGFloat = compact ? 1 : 1.15
        HStack(spacing: 14 * s) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10 * s).fill(.card)
                RoundedRectangle(cornerRadius: 10 * s).strokeBorder(.line)
                block.offset(x: 12 * s, y: 26 * s)
                block.offset(x: 54 * s, y: 26 * s)
                block.offset(x: 96 * s, y: 34 * s)
                Loop().stroke(.coral, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 54 * s, height: 46 * s).offset(x: 88 * s, y: 24 * s)
                Text("1").font(.ui(10 * s, .semibold)).foregroundStyle(.white)
                    .frame(width: 16 * s, height: 16 * s).background(Circle().fill(.coral)).offset(x: 6 * s, y: 6 * s)
            }
            .frame(width: 150 * s, height: 74 * s)
            (Text("these cards aren’t\ncentered ") + Text("[1]").foregroundColor(.coral))
                .font(.mono(12.5 * s)).foregroundStyle(.ink).lineSpacing(3)
        }
    }

    private var block: some View {
        let s: CGFloat = compact ? 1 : 1.15
        return RoundedRectangle(cornerRadius: 6 * s).fill(.rule).frame(width: 34 * s, height: 30 * s)
    }

    struct Loop: Shape {
        func path(in r: CGRect) -> Path {
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
            var path = Path()
            path.move(to: p(0.2, 0.26))
            path.addCurve(to: p(0.98, 0.45), control1: p(0.42, 0.02), control2: p(0.93, 0.06))
            path.addCurve(to: p(0.38, 0.98), control1: p(1.03, 0.85), control2: p(0.67, 1.02))
            path.addCurve(to: p(0.07, 0.5), control1: p(0.13, 0.95), control2: p(0.02, 0.73))
            path.addCurve(to: p(0.3, 0.2), control1: p(0.1, 0.36), control2: p(0.18, 0.28))
            return path
        }
    }
}
