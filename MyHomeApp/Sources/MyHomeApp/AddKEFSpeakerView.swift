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
    @State private var scanning = false
    @State private var found: [KEFDiscoveredSpeaker] = []
    @State private var scanned = false
    @State private var manual = false
    /// When editing, the existing record's id (endpoint update keeps name/room).
    var editing: KEFSpeakerRecord?

    private var addressValid: Bool { KEFClient.isValidIPv4(address) }

    var body: some View {
        Form {
            if editing == nil { discoverySection }
            if editing != nil || manual {
            Section(editing == nil ? "Add by address" : "Edit Connection") {
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
            }
            Section("Name and room (optional)") {
                if editing == nil {
                    TextField("Name", text: $name)
                    TextField("Room", text: $room)
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
                if editing != nil || manual {
                    Button("Test Connection") { Task { await test() } }
                        .disabled(!addressValid || testing)
                    Button(editing == nil ? "Add Speaker" : "Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(identity == nil)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 440)
        .onAppear {
            if let editing { address = editing.address; name = editing.name; room = editing.room }
            else { Task { await scan() } }
        }
    }

    /// Speakers found on the network (Bonjour, then verified by a read-only identity read).
    @ViewBuilder private var discoverySection: some View {
        Section("Speakers on your network") {
            if scanning {
                HStack { ProgressView().controlSize(.small); Text("Looking for KEF speakers…") }
            }
            ForEach(found) { speaker in
                let added = store.kefRecord(for: Device(id: speaker.id, name: "", ip: "", version: nil, category: KEFProtocol.category, online: true)) != nil
                HStack {
                    Image(systemName: DeviceKind.speaker.iconName)
                    VStack(alignment: .leading) {
                        Text("KEF LS50 Wireless II")
                        Text("\(speaker.address) · firmware \(speaker.identity.firmware)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if added { Text("Added").foregroundStyle(.secondary) }
                    else { Button("Add") { add(speaker) } }
                }
            }
            if scanned, found.isEmpty, !scanning {
                Text("No speakers found. Make sure the speaker is on and on the same network as this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Scan Again") { Task { await scan() } }.disabled(scanning)
                Spacer()
                Button(manual ? "Hide address entry" : "Enter address manually") { manual.toggle() }
            }
        }
    }

    private func scan() async {
        scanning = true
        defer { scanning = false; scanned = true }
        found = await KEFDiscovery.discover()
    }

    private func add(_ speaker: KEFDiscoveredSpeaker) {
        let record = store.addKEFSpeaker(identity: speaker.identity, address: speaker.address, name: name, room: room)
        Task { await store.refreshKEF(record.id, manual: true) }
        dismiss()
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
