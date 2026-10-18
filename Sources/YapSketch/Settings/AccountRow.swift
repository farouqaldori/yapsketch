import AppKit
import SwiftUI

/// One provider's account on one line: its mark, name and what it offers; its status and
/// action on the right. Connecting is a pasted key (with an entry row below) or a browser
/// sign-in, whichever the provider takes.
struct AccountRow: View {
    @ObservedObject var account: Account
    @State private var entering = false
    @State private var key = ""
    @State private var checking = false
    @State private var problem: String?
    @State private var confirmRemove = false

    private var provider: any Provider { account.provider }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProviderMark(id: provider.id, name: provider.name, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name).font(.ui(14)).foregroundStyle(.ink)
                    Text(provider.offers).font(.ui(12.5)).foregroundStyle(.soft)
                }
                Spacer(minLength: 12)
                status
                actions
            }
            if entering, case .apiKey(let getOne, _) = provider.connect { keyEntry(getOne) }
            if let error = account.error { Text(error).font(.ui(12.5)).foregroundStyle(.coralText) }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .confirmationDialog("Disconnect \(provider.name)?", isPresented: $confirmRemove) {
            Button("Disconnect", role: .destructive) { account.disconnect() }
        } message: {
            Text("Its key is deleted from this Mac's Keychain.")
        }
    }

    @ViewBuilder private var status: some View {
        switch account.state {
        case .off: EmptyView()
        case .signingIn(let page):
            Label {
                Text(page?.code.map { "Approve in your browser · \($0)" } ?? "Approve in your browser")
            } icon: {
                ProgressView().controlSize(.mini)
            }
            .font(.ui(13)).foregroundStyle(.soft)
        case .connected(let user):
            switch account.problem {
            case .disconnected: dot(.coral, "Disconnected")
            case .outOfFunds: dot(.coral, provider.billing?.empty ?? "Out of funds")
            case nil: dot(.done, user.map { "Connected · \($0)" } ?? "Connected")
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch account.state {
        case .off:
            if !entering { Button("Connect", action: connect).buttonStyle(.paper) }
        case .signingIn(let page):
            HStack(spacing: 8) {
                if let page { Button("Open Again") { NSWorkspace.shared.open(page.url) }.buttonStyle(.paper) }
                Button("Cancel") { account.cancel() }.buttonStyle(.paper)
            }
        case .connected:
            HStack(spacing: 10) {
                if account.problem == .disconnected {
                    Button("Reconnect", action: connect).buttonStyle(.paper)
                } else if account.problem == .outOfFunds, let billing = provider.billing {
                    Button(billing.topUp) { NSWorkspace.shared.open(billing.url) }.buttonStyle(.paper)
                }
                Menu {
                    if let billing = provider.billing {
                        Button("Open \(billing.label)") { NSWorkspace.shared.open(billing.url) }
                        Divider()
                    }
                    Button("Disconnect…") { confirmRemove = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
    }

    private func connect() {
        switch provider.connect {
        case .apiKey:
            entering = true
            problem = nil
        case .browser:
            account.signIn()
        }
    }

    private func keyEntry(_ getOne: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField("API key", text: $key, prompt: Text("Paste your \(provider.name) API key"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                if checking { ProgressView().controlSize(.small) }
                Button("Cancel") {
                    entering = false
                    key = ""
                    problem = nil
                }
                .buttonStyle(.paper)
                Button("Save", action: save).buttonStyle(.ink).keyboardShortcut(.defaultAction).disabled(key.isEmpty || checking)
            }
            HStack {
                if let problem { Text(problem).foregroundStyle(.coralText) }
                Spacer()
                Link("Get a key", destination: getOne).foregroundStyle(.ink)
            }
            .font(.ui(12.5))
        }
    }

    private func save() {
        checking = true
        problem = nil
        Task {
            let result = await account.save(key: key)
            checking = false
            if result == .works || result == .outOfFunds {
                key = ""
                entering = false
            } else {
                problem = result.message(provider.name)
            }
        }
    }

    private func dot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.ui(13)).foregroundStyle(color == .done ? .soft : .coralText)
    }
}

/// A provider's logo as a rounded tile (its initial if there's no logo).
struct ProviderMark: View {
    let id: String
    let name: String
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let image = ProviderLogo.image(id) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Text(String(name.prefix(1))).font(.ui(size * 0.45, .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.ink).background(.rule)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).stroke(.line, lineWidth: 0.5))
    }
}
