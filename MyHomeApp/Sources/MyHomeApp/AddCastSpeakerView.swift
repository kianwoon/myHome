// Add Google Home / Nest Mini speakers found on the network (Bonjour).
// Discovery and the verifying state read are read-only; nothing is written to a speaker.
import SwiftUI
import MyHomeCore

struct AddCastSpeakerView: View {
    @EnvironmentObject private var store: DeviceStore
    @Environment(\.dismiss) private var dismiss
    @State private var found: [CastDiscoveredSpeaker] = []
    @State private var scanning = false
    @State private var scanned = false
    @State private var selection = Set<String>()
    @State private var message: String?

    private var added: Set<String> { Set(store.castSpeakerDevices.map { $0.id.replacingOccurrences(of: CastProtocol.idPrefix, with: "") }) }

    private var selectable: [CastDiscoveredSpeaker] { found.filter { !added.contains($0.deviceID) } }

    var body: some View {
        VStack(spacing: 0) {
        Form {
            Section(found.isEmpty ? "Google Home / Nest speakers on your network" : "Found \(found.count) on your network") {
                if scanning { HStack { ProgressView().controlSize(.small); Text("Searching…") } }
                else if scanned, found.isEmpty { Text("No Cast speakers found. Check that the Mac is on the same Wi-Fi and Local Network access is allowed.").font(.caption).foregroundStyle(.secondary) }
                ForEach(found) { speaker in
                    let isAdded = added.contains(speaker.deviceID)
                    Toggle(isOn: Binding(get: { selection.contains(speaker.id) || isAdded },
                                         set: { on in if on { selection.insert(speaker.id) } else { selection.remove(speaker.id) } })) {
                        VStack(alignment: .leading) {
                            Text(speaker.name)
                            Text(speaker.model + (speaker.isGroup ? " · group" : "") + (isAdded ? " · added" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(isAdded)
                }
            }
        }
        .formStyle(.grouped)
        Divider()
        HStack {
                Button("Cancel") { dismiss() }
                Button("Search Again") { Task { await scan() } }.disabled(scanning)
                Button("Select All") { selection = Set(selectable.map(\.id)) }.disabled(selectable.isEmpty)
                Spacer()
                if !selection.isEmpty { Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary) }
                Button("Add Selected") {
                    var count = 0
                    for speaker in found where selection.contains(speaker.id) {
                        let record = store.addCastSpeaker(speaker.record())
                        count += 1
                        Task { await store.refreshCast(record.id, manual: true) }
                    }
                    message = "Added \(count) speaker\(count == 1 ? "" : "s")"
                    selection.removeAll()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
        }
        .padding(12)
        }
        .frame(width: 460, height: 460)
        .task { await scan() }
    }

    private func scan() async {
        scanning = true
        found = await CastSpeakerDiscovery.discover(timeout: store.castConfig.discoveryTimeout)
        scanning = false
        scanned = true
    }
}
