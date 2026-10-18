import AppKit
import SwiftUI

/// Speech models, picture analysis and provider accounts.
struct ModelsPane: View {
    @ObservedObject private var store = ModelStore.shared
    @AppStorage("smartPictures") private var smartPictures = true
    @AppStorage("modelUnloadMinutes") private var unload = 60
    /// A model chosen before it was downloaded: used once it's here.
    @State private var pending: String?
    @AppStorage("jevProvider") private var jevProvider = ""
    /// Redraws when an account connects, disconnects or has a problem.
    @State private var accountsRevision = 0

    var body: some View {
        BrandPage("Models") {
            BrandSection(footer: "Smart pictures are powered by Jev from TypeSafe.") {
                speech
                pictures
            }
            .id(accountsRevision)
            BrandSection("Accounts", footer: "Connect one to turn on smart pictures and cloud speech models. Without one, speech still runs on your Mac.") {
                ForEach(Accounts.shared.all) { AccountRow(account: $0) }
            }
            let downloaded = ModelStore.catalog.filter { store.installed.contains($0.id) }
            BrandSection("Speech models on this Mac", footer: "Private and free. Downloaded once, then they run on your Mac.") {
                ForEach(ModelStore.catalog) { m in LocalModelRow(model: m, store: store) { pick(m.id) } }
                BrandRow("Free memory when idle") {
                    Picker("Free memory when idle", selection: $unload) {
                        Text("After 5 minutes").tag(5)
                        Text("After 15 minutes").tag(15)
                        Text("After 1 hour").tag(60)
                        Text("Never").tag(0)
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if !downloaded.isEmpty {
                BrandSection("Credits", footer: "Speech engine: transcribe.cpp by Handy (MIT). Model conversions by handy-computer.") {
                    ForEach(downloaded) { m in
                        BrandRow(m.name) { Link(m.license, destination: URL(string: m.licenseURL)!).font(.ui(13)).foregroundStyle(.ink) }
                    }
                }
            }
        }
        .onAppear { store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .yapSketchAccountsChanged)) { _ in accountsRevision += 1 }
        .onChange(of: store.installed) {
            if let p = pending, store.installed.contains(p) {
                choose(p)
                pending = nil
            }
        }
    }

    // MARK: Speech

    /// The model transcripts use: the chosen cloud one if its account is connected, else the
    /// chosen (or a downloaded) one on this Mac.
    private var currentSpeech: String { CloudSpeech.selected()?.id ?? ModelStore.current()?.id ?? "" }

    private var speech: some View {
        let cloud = CloudSpeech.selected()
        let downloading = ModelStore.catalog.first { store.progress[$0.id] != nil }
        let subtitle: String
        if let d = downloading, let p = store.progress[d.id] {
            subtitle = "Downloading \(d.name)… \(Int(p * 100))%"
        } else if let c = cloud {
            subtitle = "Cloud. Your audio is sent to \(c.providerName)."
        } else {
            subtitle = "On this Mac · private"
        }
        return BrandRow("Speech", subtitle: subtitle) {
            Picker("Speech", selection: Binding(get: { currentSpeech }, set: pick)) {
                Section("On this Mac") {
                    ForEach(ModelStore.catalog.filter { store.installed.contains($0.id) }) { m in Text(m.name).tag(m.id) }
                }
                // Each account's models under its name (menus here don't show images).
                let available = CloudSpeech.available()
                if available.isEmpty {
                    Section("Cloud") { Text("Connect an account below").tag("none").disabled(true) }
                }
                ForEach(Providers.all, id: \.id) { p in
                    let models = available.filter { $0.providerID == p.id }
                    if !models.isEmpty {
                        Section(p.name) { ForEach(models) { m in Text(m.name).tag(m.id) } }
                    }
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func pick(_ id: String) {
        if let m = ModelStore.catalog.first(where: { $0.id == id }), !store.installed.contains(id) {
            store.download(m)
            pending = id
            return
        }
        choose(id)
    }

    private func choose(_ id: String) {
        store.selectedID = id
        NotificationCenter.default.post(name: .yapSketchModelChanged, object: nil)
    }

    // MARK: Smart pictures

    private var pictures: some View {
        let connected = Providers.connected.filter { $0.jev != nil }
        let on = smartPictures
        return BrandRow(
            "Smart pictures",
            subtitle: connected.isEmpty
                ? "Your agent finds what you mean faster and spends fewer tokens. Connect an account below to turn it on."
                : "Ties each thing you say to the spot you marked and picks the clearest picture, so your agent finds what you mean faster and spends fewer tokens.",
            badge: "Recommended"
        ) {
            Picker(
                "Smart pictures",
                selection: Binding(
                    get: { on ? (Jev.route()?.provider.id ?? "off") : "off" },
                    set: { v in
                        smartPictures = v != "off"
                        if v != "off" { jevProvider = v }
                    })
            ) {
                Text("Off").tag("off")
                if !connected.isEmpty { Divider() }
                ForEach(connected, id: \.id) { p in
                    Label {
                        Text("Jev via \(p.name)")
                    } icon: {
                        Image(nsImage: ProviderLogo.menuIcon(p.id))
                    }.tag(p.id)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(connected.isEmpty)
        }
    }

}

/// A speech model on this Mac: Download, its progress, or (downloaded) In use / Use and Delete.
private struct LocalModelRow: View {
    let model: SpeechModel
    @ObservedObject var store: ModelStore
    let use: () -> Void

    var body: some View {
        let installed = store.installed.contains(model.id)
        let inUse = installed && CloudSpeech.selected() == nil && ModelStore.current()?.id == model.id
        BrandRow(
            model.name, subtitle: store.failed[model.id] ?? "\(model.detail) · \(model.size)",
            subtitleColor: store.failed[model.id] == nil ? .soft : .coralText
        ) {
            if let p = store.progress[model.id] {
                HStack(spacing: 8) {
                    ProgressView(value: p).tint(.coral).frame(width: 120)
                    Text("\(Int(p * 100))%").font(.mono(12)).foregroundStyle(.soft).frame(width: 36, alignment: .trailing)
                    Button {
                        store.cancel(model)
                    } label: {
                        Image(systemName: "xmark")
                    }.buttonStyle(.borderless).help("Cancel")
                }
            } else if installed {
                HStack(spacing: 10) {
                    if inUse {
                        Text("In use").font(.ui(13)).foregroundStyle(.soft)
                    } else {
                        Button("Use", action: use).buttonStyle(.paper)
                    }
                    Menu {
                        Button("Delete Model", role: .destructive) { store.delete(model) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            } else {
                Button("Download") { store.download(model) }.buttonStyle(.paper)
            }
        }
    }
}

extension Notification.Name {
    static let yapSketchModelChanged = Notification.Name("yapSketchModelChanged")
}
