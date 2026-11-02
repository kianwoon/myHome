// baseline-guard:allow rewrite of existing settings source to match bridge behavior
import SwiftUI
import ServiceManagement
import MyHomeCore

/// Native Settings window (macOS Settings scene). Three tabs: cloud
/// credentials, control cadence, and general preferences.
struct SettingsView: View {
    var body: some View {
        TabView {
            CloudSettingsView()
                .tabItem { Label("Cloud", systemImage: "cloud") }
            ControlSettingsView()
                .tabItem { Label("Control", systemImage: "slider.horizontal.3") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 430)
    }
}

// MARK: - Cloud

private struct CloudSettingsView: View {
    private enum Status: Equatable {
        case idle
        case working
        case success(String)
        case failure(String)
    }

    private enum SignInPhase: Equatable {
        case idle
        case sending
        case awaitingCode
        case verifying
        case verified(Int)
    }

    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var maskedSecret = ""
    @State private var apiRegion = "eu"
    @State private var status: Status = .idle
    @State private var advancedExpanded = false

    // App API sign-in state. Every field is derived from the bridge's
    // `config` / `appapi_signin` replies — there is no second source.
    @State private var accountEmail = ""
    @State private var accountCountry = ""
    @State private var accountMasked = ""
    @State private var accountSignedIn = false
    @State private var forceSignInForm = false
    @State private var code = ""
    @State private var phase: SignInPhase = .idle
    @State private var accountMessage: Status = .idle

    private let regions = ["cn", "us", "eu", "sg", "in"]

    var body: some View {
        Form {
            BriturnCloudSettingsView()

            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(accountSignedIn ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 8, height: 8)
                    Text(accountSignedIn ? "Signed in as \(displayMaskedEmail)" : "Not signed in")
                        .font(.callout)
                    Spacer()
                    if accountSignedIn {
                        Button("Re-link…") {
                            forceSignInForm = true
                            accountMessage = .idle
                        }
                        .buttonStyle(.link)
                    }
                }

                if reLinkRequired {
                    Label("Re-link required — sign in again to refresh the app API session.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if signInFormVisible {
                    TextField("Email", text: $accountEmail,
                              prompt: Text("you@example.com"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Country code", text: $accountCountry,
                              prompt: Text("digits, e.g. 49"))
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 10) {
                        Button(phase == .sending ? "Sending…" : "Send Code") {
                            sendCode()
                        }
                        .disabled(!canSendCode)
                        if phase == .sending {
                            ProgressView().controlSize(.small)
                        }
                        accountStatusText
                    }
                }

                if phase == .awaitingCode || phase == .verifying {
                    TextField("Verification code", text: $code,
                              prompt: Text("code from email"))
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 10) {
                        Button("Verify") { verifyCode() }
                            .disabled(!canVerify)
                        if phase == .verifying {
                            ProgressView().controlSize(.small)
                        }
                        Button("Cancel") { cancelSignIn() }
                            .buttonStyle(.link)
                            .disabled(phase == .verifying)
                    }
                }

                if case .verified(let count) = phase {
                    Label("Signed in — \(count) devices synced",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } header: {
                Text("Tuya Account")
            } footer: {
                Text("Sign in with the email used by the Smart Life app. The app API has no usage quota; the session is remembered and only needs renewing when it expires.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Advanced: Tuya IoT Platform (optional)",
                                isExpanded: $advancedExpanded) {
                    TextField("Access ID", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    SecureField(
                        "Access Secret",
                        text: $apiSecret,
                        prompt: Text(maskedSecret.isEmpty ? "Required" : "Leave blank to keep \(maskedSecret)")
                    )
                    .textFieldStyle(.roundedBorder)
                    Picker("Region", selection: $apiRegion) {
                        ForEach(regions, id: \.self) { region in
                            Text(regionLabel(region)).tag(region)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(spacing: 10) {
                        Button("Test & Save") { testAndSave() }
                            .disabled(status == .working)
                        if status == .working {
                            ProgressView().controlSize(.small)
                        }
                        statusText
                    }
                }
            } footer: {
                Text("Used automatically as the primary cloud transport when available. The app API sign-in above has no usage quota.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .task {
            await loadConfig()
            await runSignInProbeIfRequested()
        }
    }

    private var trimmedEmail: String {
        accountEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var signInFormVisible: Bool {
        forceSignInForm || !accountSignedIn
    }

    private var reLinkRequired: Bool {
        !trimmedEmail.isEmpty && !accountSignedIn && phase == .idle
    }

    private var canSendCode: Bool {
        !trimmedEmail.isEmpty && phase != .sending && phase != .verifying
    }

    private var canVerify: Bool {
        !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && phase == .awaitingCode
    }

    private var displayMaskedEmail: String {
        if !accountMasked.isEmpty { return accountMasked }
        return maskEmail(trimmedEmail)
    }

    @ViewBuilder private var accountStatusText: some View {
        switch accountMessage {
        case .idle:
            EmptyView()
        case .working:
            Text("Contacting Tuya…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder private var statusText: some View {
        switch status {
        case .idle:
            EmptyView()
        case .working:
            Text("Testing against Tuya Cloud…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func regionLabel(_ region: String) -> String {
        region == "sg" ? "sg (Southeast Asia)" : region
    }

    private func maskEmail(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return "" }
        let local = email[email.startIndex..<at]
        let domain = email[email.index(after: at)...]
        guard let first = local.first else { return "…@\(domain)" }
        return "\(first)…@\(domain)"
    }

    private func loadConfig() async {
        do {
            let reply = try await BridgeClient.shared.request(["cmd": "config"])
            guard reply["ok"] as? Bool == true,
                  let config = reply["config"] as? [String: Any] else {
                throw BridgeError.badResponse("missing config")
            }
            apiKey = config["apiKey"] as? String ?? ""
            maskedSecret = config["apiSecretMasked"] as? String ?? ""
            let region = config["apiRegion"] as? String ?? ""
            if !region.isEmpty { apiRegion = region }

            accountEmail = config["appApiEmail"] as? String ?? ""
            accountCountry = config["appApiCountryCode"] as? String ?? ""
            accountSignedIn = config["appApiSignedIn"] as? Bool ?? false
            accountMasked = config["appApiEmailMasked"] as? String ?? ""
        } catch {
            status = .failure(error.localizedDescription)
            accountMessage = .failure("Bridge unreachable — \(error.localizedDescription)")
        }
    }

    private func sendCode() {
        let email = trimmedEmail
        guard !email.isEmpty else { return }
        let country = accountCountry.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .sending
        accountMessage = .working
        Task {
            do {
                var payload: [String: Any] = [
                    "cmd": "appapi_signin",
                    "step": "send",
                    "email": email
                ]
                if !country.isEmpty { payload["countryCode"] = country }
                let reply = try await BridgeClient.shared.request(payload, timeout: 30)
                if reply["ok"] as? Bool == true {
                    if let masked = reply["email"] as? String, !masked.isEmpty {
                        accountMasked = masked
                    }
                    accountSignedIn = false
                    phase = .awaitingCode
                    accountMessage = .success(
                        "Code sent to \(accountMasked.isEmpty ? email : accountMasked).")
                } else {
                    phase = .idle
                    accountMessage = .failure(
                        reply["error"] as? String ?? "Could not send the code.")
                }
            } catch {
                phase = .idle
                accountMessage = .failure(error.localizedDescription)
            }
        }
    }

    private func verifyCode() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        phase = .verifying
        accountMessage = .working
        Task {
            do {
                let reply = try await BridgeClient.shared.request([
                    "cmd": "appapi_signin", "step": "verify", "code": trimmed
                ], timeout: 30)
                if reply["ok"] as? Bool == true {
                    let count = reply["devices"] as? Int ?? 0
                    code = ""
                    forceSignInForm = false
                    phase = .verified(count)
                    accountMessage = .success("Signed in — \(count) devices synced.")
                    await loadConfig()
                } else {
                    phase = .awaitingCode
                    accountMessage = .failure(
                        reply["error"] as? String ?? "Verification failed.")
                }
            } catch {
                phase = .awaitingCode
                accountMessage = .failure(error.localizedDescription)
            }
        }
    }

    private func cancelSignIn() {
        code = ""
        phase = .idle
        forceSignInForm = false
        accountMessage = .idle
    }

    /// Diagnostic-only: drives the real send step once on launch when
    /// MYHOME_SIGNIN_PROBE_EMAIL is set, so the flow can be exercised and
    /// screenshotted without manual input. Inert otherwise.
    private func runSignInProbeIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard let probe = environment["MYHOME_SIGNIN_PROBE_EMAIL"], !probe.isEmpty else {
            return
        }
        accountEmail = probe
        if let country = environment["MYHOME_SIGNIN_PROBE_COUNTRY"], !country.isEmpty {
            accountCountry = country
        }
        forceSignInForm = true
        accountSignedIn = false
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        sendCode()
    }

    private func testAndSave() {
        status = .working
        var payload: [String: Any] = [
            "cmd": "setconfig",
            "apiKey": apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "apiRegion": apiRegion
        ]
        // Empty secret = keep the stored one; the bridge tests with it and never
        // echoes it back.
        let trimmedSecret = apiSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSecret.isEmpty { payload["apiSecret"] = trimmedSecret }

        Task {
            do {
                let reply = try await BridgeClient.shared.request(payload, timeout: 30)
                if reply["ok"] as? Bool == true {
                    apiSecret = ""
                    status = .success("Connection verified — credentials saved.")
                    await loadConfig()
                } else {
                    status = .failure(reply["error"] as? String ?? "Cloud test failed.")
                }
            } catch {
                status = .failure(error.localizedDescription)
            }
        }
    }
}

// MARK: - Control

private struct ControlSettingsView: View {
    @AppStorage("pollIntervalSeconds") private var pollInterval = AppSettings.defaultPollInterval
    @AppStorage("scanWindowSeconds") private var scanWindow = AppSettings.defaultScanWindow
    @AppStorage("autoScanMinutes") private var autoScanMinutes = AppSettings.defaultAutoScanMinutes

    var body: some View {
        Form {
            Section {
                Stepper("Poll interval: \(pollInterval)s", value: $pollInterval, in: AppSettings.pollIntervalRange)
                Stepper("Scan window: \(scanWindow)s", value: $scanWindow, in: AppSettings.scanWindowRange)
                Stepper(autoScanMinutes == 0 ? "Auto-scan for new lights: off" : "Auto-scan for new lights: every \(autoScanMinutes) min",
                        value: $autoScanMinutes, in: AppSettings.autoScanMinutesRange)
            } header: {
                Text("Polling")
            } footer: {
                Text("Poll interval applies the next time polling starts. Scan window applies to the next Rescan. Auto-scan looks for new Briturn lights in the background (0 = off).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Bridge") {
                let path = BridgeClient.bridgeDirectory().appendingPathComponent("bridge.py").path
                Text(path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @AppStorage("notifyOnDeviceOffline") private var notifyOffline = false
    @State private var launchAtLogin = false
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                if launchError == nil {
                    Text("MyHome starts in the menu bar when you log in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Notifications on device offline (beta)", isOn: $notifyOffline)
            } footer: {
                Text("Stores the preference now; notification delivery ships in a later update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 4)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
