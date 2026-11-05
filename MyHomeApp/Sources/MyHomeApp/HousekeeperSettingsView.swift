// Settings → AI Models → Housekeeper agent: the Cloud LLM tool-calling loop
// that handles everything the parser's fast path does not. Embedded in the
// AI Models form; any change rebuilds the agent via services.reloadHousekeeper().
import MyHomeCore
import SwiftUI

struct HousekeeperSettingsSection: View {
    @State private var enabled = AppSettings.housekeeperEnabled()
    @AppStorage(AppSettings.housekeeperFastPathKey) private var fastPath = AppSettings.defaultHousekeeperFastPath
    @AppStorage(AppSettings.housekeeperToolModeKey) private var toolMode = AppSettings.defaultHousekeeperToolMode
    @AppStorage(AppSettings.housekeeperMaxIterationsKey) private var maxIterations = AppSettings.defaultHousekeeperMaxIterations
    @AppStorage(AppSettings.housekeeperMaxToolCallsKey) private var maxToolCalls = AppSettings.defaultHousekeeperMaxToolCalls
    @AppStorage(AppSettings.housekeeperTurnTimeoutKey) private var turnTimeout = AppSettings.defaultHousekeeperTurnTimeout
    @AppStorage(AppSettings.housekeeperRequestTimeoutKey) private var requestTimeout = AppSettings.defaultHousekeeperRequestTimeout
    @AppStorage(AppSettings.housekeeperMemoryTurnsKey) private var memoryTurns = AppSettings.defaultHousekeeperMemoryTurns
    @AppStorage(AppSettings.housekeeperMemoryIdleKey) private var memoryIdle = AppSettings.defaultHousekeeperMemoryIdle
    @AppStorage(AppSettings.housekeeperConfirmMaxDevicesKey) private var confirmMaxDevices = AppSettings.defaultHousekeeperConfirmMaxDevices
    @AppStorage(AppSettings.housekeeperConfirmMaxRoomsKey) private var confirmMaxRooms = AppSettings.defaultHousekeeperConfirmMaxRooms
    @AppStorage(AppSettings.assistantSayURLEnabledKey) private var sayURLEnabled = AppSettings.defaultAssistantSayURLEnabled
    @ObservedObject private var notes: HouseholdNotes
    @State private var drafts: [String: String] = [:]
    @State private var newNote = ""

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
        _notes = ObservedObject(wrappedValue: services.notes)
    }

    var body: some View {
        Section {
            settingsFields
            notesEditor
            HousekeeperTestRow { [services] in await services.housekeeper.selfTest() }
        } header: {
            Text("Housekeeper agent")
        } footer: {
            Text(Self.footerNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: enabled) { value in
            UserDefaults.standard.set(value, forKey: AppSettings.housekeeperEnabledKey)
            services.reloadHousekeeper()
        }
        .onChange(of: fastPath) { _ in services.reloadHousekeeper() }
        .onChange(of: toolMode) { _ in services.reloadHousekeeper() }
        .onChange(of: maxIterations) { _ in services.reloadHousekeeper() }
        .onChange(of: maxToolCalls) { _ in services.reloadHousekeeper() }
        .onChange(of: turnTimeout) { _ in services.reloadHousekeeper() }
        .onChange(of: requestTimeout) { _ in services.reloadHousekeeper() }
        .onChange(of: memoryTurns) { _ in services.reloadHousekeeper() }
        .onChange(of: memoryIdle) { _ in services.reloadHousekeeper() }
        .onChange(of: confirmMaxDevices) { _ in services.reloadHousekeeper() }
        .onChange(of: confirmMaxRooms) { _ in services.reloadHousekeeper() }
        .onChange(of: sayURLEnabled) { _ in services.reloadHousekeeper() }
        .onChange(of: notes.notes) { _ in services.reloadHousekeeper() }
        .onAppear { syncDrafts() }
    }

    @ViewBuilder private var settingsFields: some View {
        Toggle("Use the housekeeper agent (Cloud LLM with tools)", isOn: $enabled)
        Toggle("Fast path: parsed single-device commands and state questions run without the model", isOn: $fastPath)
        Picker("Tool calls", selection: $toolMode) {
            Text("Auto (probe)").tag(AppSettings.ToolCallMode.auto)
            Text("Native function calling").tag(AppSettings.ToolCallMode.native)
            Text("Text protocol").tag(AppSettings.ToolCallMode.text)
        }
        Stepper("Max model steps per request: \(maxIterations)", value: $maxIterations, in: AppSettings.housekeeperMaxIterationsRange)
        Stepper("Max tool calls per request: \(maxToolCalls)", value: $maxToolCalls, in: AppSettings.housekeeperMaxToolCallsRange)
        Stepper(String(format: "Request time limit %.0fs", turnTimeout), value: $turnTimeout, in: AppSettings.housekeeperTurnTimeoutRange, step: 10)
        Stepper(String(format: "Model call time limit %.0fs", requestTimeout), value: $requestTimeout, in: AppSettings.housekeeperRequestTimeoutRange, step: 5)
        Stepper("Remember \(memoryTurns) turns", value: $memoryTurns, in: AppSettings.housekeeperMemoryTurnsRange)
        Stepper(String(format: "Forget the conversation after %.0f min", memoryIdle / 60), value: $memoryIdle, in: AppSettings.housekeeperMemoryIdleRange, step: 60)
        Stepper("Ask before touching more than \(confirmMaxDevices) devices across rooms", value: $confirmMaxDevices, in: AppSettings.housekeeperConfirmMaxDevicesRange)
        Stepper("Rooms one request may span without asking: \(confirmMaxRooms)", value: $confirmMaxRooms, in: AppSettings.housekeeperConfirmMaxRoomsRange)
        Toggle("Allow myhome://say and --say commands (diagnostics)", isOn: $sayURLEnabled)
        Text("Off by default: any local process can open the scheme. Text sent this way can never confirm a pending action (\u{201C}yes\u{201D}). For a one-off diagnostic run, launch with MYHOME_DIAGNOSTICS=1 instead.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var notesEditor: some View {
        Text("Household notes")
        ForEach(notes.notes) { note in
            HStack {
                TextField("Note", text: draftBinding(for: note))
                    .onSubmit { notes.update(id: note.id, text: drafts[note.id] ?? note.text) }
                Button { notes.remove(id: note.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
        if notes.notes.isEmpty {
            Text("No notes yet. Say \u{201C}remember \u{2026}\u{201D} to the assistant or add one here.")
                .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            TextField("New note, e.g. the desk lamp is the one by the window", text: $newNote)
                .onSubmit(addNote)
            Button("Add", action: addNote)
                .disabled(newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if let problem = notes.problem {
            Text(problem).font(.caption).foregroundStyle(.red)
        }
    }

    private func draftBinding(for note: HouseholdNote) -> Binding<String> {
        Binding(get: { drafts[note.id] ?? note.text }, set: { drafts[note.id] = $0 })
    }

    private func syncDrafts() {
        drafts = Dictionary(uniqueKeysWithValues: notes.notes.map { ($0.id, $0.text) })
    }

    private func addNote() {
        guard !newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        notes.add(newNote)
        newNote = ""
        syncDrafts()
    }

    // allow-hardcode: UI copy.
    static let footerNote = "With a Cloud LLM configured, the housekeeper handles every request the fast path does not: it sees the live state of all devices, acts through tools (every change still goes through the device controller's checks), asks only when it truly cannot decide, and confirms sweeping changes across rooms or smart sockets with one \u{201C}Go ahead?\u{201D}."
}

/// A "Test housekeeper" button: one read-only get_state round trip, result shown below.
private struct HousekeeperTestRow: View {
    let run: () async -> String
    @State private var result: String?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Test housekeeper") {
                    running = true
                    Task {
                        let text = await run()
                        result = text
                        running = false
                    }
                }
                .disabled(running)
                if running { ProgressView().controlSize(.small) }
            }
            if let result { Text(result).font(.caption).textSelection(.enabled) }
            Text("Runs one read-only get_state round trip through the configured Cloud LLM and reports whether tool calls travel natively or via the text protocol.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
