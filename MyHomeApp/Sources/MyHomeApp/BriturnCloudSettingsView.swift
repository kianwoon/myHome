import SwiftUI
import MyHomeCore

struct BriturnCloudSettingsView: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var email = ""
    @State private var password = ""
    @State private var region: BriturnCloudRegion = .us
    @State private var account: BriturnCloudAccount?
    @State private var isWorking = false
    @State private var isRestoring = true
    @State private var errorMessage: String?
    @State private var signInTask: Task<Void, Never>?

    var body: some View {
        Section {
            if let account {
                Label("Signed in as \(account.maskedEmail)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("Server", value: account.region.title)
                HStack {
                    Button(store.briturnCloudSyncing ? "Syncing…" : "Sync Devices") {
                        Task { await store.syncBriturnCloud() }
                    }
                    .disabled(store.briturnCloudSyncing || isWorking)
                    if store.briturnCloudSyncing { ProgressView().controlSize(.small) }
                    Text("\(store.briturnCloudDeviceCount) cloud devices")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = store.briturnCloudError {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                }
                Button("Sign Out") { signOut() }
                    .disabled(isWorking || isRestoring)
            } else {
                TextField("Email", text: $email, prompt: Text("Briturn account email"))
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .disabled(isWorking || isRestoring)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .disabled(isWorking || isRestoring)
                    .onSubmit { if canSignIn { signIn() } }
                Picker("Server region", selection: $region) {
                    ForEach(BriturnCloudRegion.allCases) { region in
                        Text(region.title).tag(region)
                    }
                }
                .disabled(isWorking || isRestoring)
                HStack(spacing: 10) {
                    Button(isWorking ? "Signing In…" : "Sign In") { signIn() }
                        .disabled(!canSignIn)
                    if isWorking || isRestoring {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Briturn Cloud")
        } footer: {
            Text(account == nil
                 ? "Use your Briturn app account and its server region. Your session is saved in macOS Keychain; your password is not saved."
                 : "Cloud devices sync automatically and appear in Briturn. Cloud control is available alongside local WiFi and Bluetooth. Sign out removes this Mac’s saved session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            defer { isRestoring = false }
            do {
                account = try await BriturnCloudClient.shared.savedAccount()
            } catch {
                errorMessage = "Could not read the saved Briturn session from Keychain."
            }
        }
        .onDisappear {
            signInTask?.cancel()
            password = ""
        }
    }

    private var canSignIn: Bool {
        !isWorking && !isRestoring && !password.isEmpty
            && email.trimmingCharacters(in: .whitespacesAndNewlines).contains("@")
    }

    private func signIn() {
        guard canSignIn else { return }
        isWorking = true
        errorMessage = nil
        let submittedPassword = password
        password = ""
        signInTask = Task { @MainActor in
            defer { isWorking = false }
            do {
                account = try await BriturnCloudClient.shared.signIn(email: email,
                                                                     password: submittedPassword,
                                                                     region: region)
                email = ""
                await store.syncBriturnCloud()
            } catch is CancellationError {
                // Closing Settings cancels the pending request without displaying an error.
            } catch {
                errorMessage = (error as? BriturnCloudError)?.localizedDescription
                    ?? "Could not sign in to Briturn. Please try again."
            }
        }
    }

    private func signOut() {
        isWorking = true
        errorMessage = nil
        signInTask = Task { @MainActor in
            defer { isWorking = false }
            do {
                try await BriturnCloudClient.shared.signOut()
                account = nil
                password = ""
                await store.syncBriturnCloud()
            } catch {
                errorMessage = "Could not remove the Briturn session from Keychain. Please try again."
            }
        }
    }
}
