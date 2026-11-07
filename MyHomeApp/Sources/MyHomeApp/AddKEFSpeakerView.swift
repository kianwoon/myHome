// Add / edit a KEF LS50 Wireless II by IPv4 address. Test Connection performs
// identity READS only; Add becomes available after a verified, supported model.
import SwiftUI
import MyHomeCore

struct AddKEFSpeakerView: View {
    @EnvironmentObject private var store: DeviceStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @State private var room = ""
    @State private var identity: KEFIdentity?
    @State private var testing = false
    @State private var message: String?
    @State private var failed = false
    /// When editing, the existing record's id (endpoint update keeps name/room).
    var editing: KEFSpeakerRecord?

    private var addressValid: Bool { KEFClient.isValidIPv4(address) }

    var body: some View {
        Form {
            Section(editing == nil ? "Add KEF LS50 Wireless II" : "Edit Connection") {
                TextField("Primary speaker IPv4 address", text: $address)
                    .textContentType(.none)
                    .onChange(of: address) { _ in identity = nil; message = nil }
                    .accessibilityLabel("Speaker IPv4 address")
                TextField("Name (optional)", text: $name)
                TextField("Room (optional)", text: $room)
                if !address.isEmpty, !addressValid {
                    Label(KEFError.invalidAddress.message, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.caption)
                }
            }
            if let identity {
                Section("Verified") {
                    LabeledContent("Model", value: identity.model)
                    LabeledContent("Firmware", value: identity.firmware.isEmpty ? "–" : identity.firmware)
                }
            }
            if let message {
                Label(message, systemImage: failed ? "xmark.octagon" : "checkmark.circle")
                    .foregroundStyle(failed ? .red : .green).font(.callout)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Test Connection") { Task { await test() } }
                    .disabled(!addressValid || testing)
                Button(editing == nil ? "Add Speaker" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(identity == nil)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 440)
        .onAppear {
            if let editing { address = editing.address; name = editing.name; room = editing.room }
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let found = try await store.kefTestConnection(address: address)
            if let editing, editing.id != found.deviceID {
                failed = true; identity = nil
                message = "That address is a different speaker than \(editing.name)."
                return
            }
            identity = found
            failed = false
            message = "Connected."
        } catch {
            identity = nil
            failed = true
            message = (error as? KEFError)?.message ?? "Connection failed."
        }
    }

    private func save() {
        guard let identity else { return }
        let record = store.addKEFSpeaker(identity: identity, address: address, name: name, room: room)
        Task { await store.refreshKEF(record.id, manual: true) }
        dismiss()
    }
}

/// Settings tab: speakers list with add / edit / remove (local config only).
struct KEFSpeakersSettingsView: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var adding = false
    @State private var editing: KEFSpeakerRecord?

    var body: some View {
        Form {
            Section("KEF speakers") {
                if store.kefSpeakerDevices.isEmpty {
                    Text("No speakers yet. Add an LS50 Wireless II by its IP address.").foregroundStyle(.secondary)
                }
                ForEach(store.kefSpeakerDevices) { device in
                    if let record = store.kefRecord(for: device) {
                        HStack {
                            Image(systemName: DeviceKind.speaker.iconName)
                            VStack(alignment: .leading) {
                                Text(record.name)
                                Text("\(record.identity.model) · \(record.address)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") { editing = record }
                            Button("Remove", role: .destructive) { store.removeKEFSpeaker(id: record.id) }
                                .help("Removes it from MyHome only; the speaker is not reset or unpaired.")
                        }
                    }
                }
                Button("Add Speaker…") { adding = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $adding) { AddKEFSpeakerView().environmentObject(store) }
        .sheet(item: $editing) { record in AddKEFSpeakerView(editing: record).environmentObject(store) }
    }
}
