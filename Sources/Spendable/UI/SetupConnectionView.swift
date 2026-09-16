import AppKit
import SwiftUI

struct SetupConnectionView: View {
    let model: AppModel
    @State private var token = ""
    @State private var showToken = false
    @State private var validationMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect your bank through SimpleFIN").font(.title2)
                switch model.setupState {
                case .checking:
                    Text("Checking whether a connection is already saved…")
                case .ready:
                    Text("Make a setup token on the SimpleFIN website, then paste it here. Spendable can read your accounts; it cannot move money.")
                    HStack {
                        Group {
                            if showToken { TextField("Setup token", text: $token) }
                            else { SecureField("Setup token", text: $token) }
                        }
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .writingToolsBehavior(.disabled)
                        Button("Paste") { token = NSPasteboard.general.string(forType: .string) ?? "" }
                    }
                    Toggle("Show", isOn: $showToken).toggleStyle(.checkbox)
                    if !token.isEmpty { Text("Pasted — \(token.count) characters.").foregroundStyle(.secondary) }
                    HStack {
                        Button("Cancel") { clearField() }
                        Button("Connect") { connect() }
                            .buttonStyle(.borderedProminent)
                            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                case .alreadyConnected:
                    Text("You're already connected to SimpleFIN. Changing a working connection comes in a later version.")
                    Button("Check again") { Task { await model.refresh() } }.disabled(model.isSyncing)
                case .freshCredentialRejected:
                    Text("The connection is saved, but SimpleFIN hasn't accepted it yet. Check again with the saved connection; don't make another setup token.")
                    Button("Check again") { Task { await model.refresh() } }.disabled(model.isSyncing)
                case .keychainUnavailable:
                    Text("macOS wouldn't let me check your saved connection, so I won't replace it. Unlock your login keychain and open this again.")
                    Button("Try again") { Task { await model.prepareSetup() } }
                case .claiming:
                    Text("Asking SimpleFIN for your accounts…")
                case .unsaved:
                    Text("Your connection is still here. Use Try again above after unlocking your login keychain.")
                case .connected:
                    Text(model.setupMessage ?? "Connected. Getting your accounts…")
                    Button("Check again") { Task { await model.refresh() } }.disabled(model.isSyncing)
                }
                if let validationMessage { Text(validationMessage).foregroundStyle(.orange) }
                if model.setupState != .connected && model.setupState != .claiming,
                   model.setupState != .freshCredentialRejected, let message = model.setupMessage {
                    Text(message).foregroundStyle(.secondary)
                }
                Button("Open the SimpleFIN website") { AppModel.openSimpleFIN() }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { MainWindowController.protectSetupWindow(true) }
        .task { await model.prepareSetup() }
        .onDisappear {
            clearField()
            MainWindowController.protectSetupWindow(false)
        }
    }

    private func connect() {
        do {
            let claimURL = try SimpleFINClient.claimURL(fromSetupToken: token)
            clearField()
            validationMessage = nil
            Task { await model.claimConnection(at: claimURL) }
        } catch {
            validationMessage = "That doesn't look like a SimpleFIN setup token."
            clearField()
        }
    }

    private func clearField() {
        token = ""
        showToken = false
        MainWindowController.clearSetupField()
    }
}

struct ConnectionBannerView: View {
    let model: AppModel
    @State private var confirmingReplacement = false

    var body: some View {
        if let banner = model.banner {
            VStack(alignment: .leading, spacing: 8) {
                Label(banner.title, systemImage: banner.symbol).font(.headline)
                Text(banner.body).font(.callout)
                HStack {
                    switch banner {
                    case .unsaved, .keychain:
                        Button("Try again") { Task { await model.retryKeychain() } }
                        Button("Open Keychain Access") { AppModel.openKeychainAccess() }
                    case .rejected:
                        Button("Paste a new setup token") { model.setupScreenRequested = true }
                    case .freshCredentialRejected:
                        Button("Try again") { Task { await model.refresh() } }.disabled(model.isSyncing)
                        Button("Replace anyway…") { confirmingReplacement = true }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12))
            .confirmationDialog("Replace the connection you just saved?", isPresented: $confirmingReplacement,
                                titleVisibility: .visible) {
                Button("Replace the saved connection") { Task { await model.approveRejectedReplacement() } }
                Button("Keep the saved connection", role: .cancel) { }
            } message: {
                Text("You can try the saved connection again without using another setup token. If you choose to replace it, you'll need to make a new token on the SimpleFIN website, and that token will be used up when you connect. The current saved connection stays in place until its replacement is verified.")
            }
        }
    }
}
