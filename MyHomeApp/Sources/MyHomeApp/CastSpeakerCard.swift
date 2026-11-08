// Google Home / Nest Mini (Cast) speaker card, detail panel and menu row.
// Every control goes through DeviceController.perform — the same path as voice
// and text — and shows only CONFIRMED state. Transport buttons talk to the
// store directly (play/pause/stop are not part of the shared command set).
import SwiftUI
import MyHomeCore
import AppKit

struct CastControls: View {
    @EnvironmentObject private var store: DeviceStore
    @StateObject private var runner = KEFCommandRunner()
    @State private var transportError: String?
    let device: Device
    @State private var preview: Double?
    @State private var dragging = false
    @State private var commitTask: Task<Void, Never>?
    @State private var askingURL = false
    @State private var urlText = ""

    private var state: CastState? { store.castState(for: device) }
    private var reading: CastReading? { store.castReading(for: device) }
    private var writable: Bool { store.reachability(for: device) != .offline && state != nil }
    private var step: Int { store.castConfig.volumeStep }
    private var range: ClosedRange<Int> { store.castConfig.volumeRange }

    private func commit(_ value: Double) {
        let target = Int(value.rounded())
        Task { await runner.run(.volume(target), on: device); preview = nil }
    }

    private func transport(_ action: CastAction) {
        Task {
            if case .failed(let error) = await store.castWrite(device, action) { transportError = error.message } else { transportError = nil }
        }
    }

    private func play(_ source: CastMediaSource) { transport(.playMedia(source)) }

    private func playFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio file to play on \(device.name)"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        Task {
            do {
                let url = try await CastFileServer.shared.register(file)
                play(CastMediaSource(title: file.deletingPathExtension().lastPathComponent, url: url,
                                     contentType: CastFileServer.contentType(for: file)))
            } catch { transportError = (error as? CastError)?.message ?? "could not share that file" }
        }
    }

    private var musicMenu: some View {
        Menu {
            ForEach(store.castPresets) { preset in
                Button(preset.name) { Task { _ = await store.castPlay(device, preset: preset) } }
            }
            if !store.castPresets.isEmpty { Divider() }
            Button("Play URL…") { urlText = ""; askingURL = true }
            Button("Play File from this Mac…", action: playFile)
        } label: { Label("Play", systemImage: "music.note") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Play music")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Volume")
                Slider(value: Binding(
                    get: { preview ?? Double(state?.volume ?? 0) },
                    set: { newValue in
                        preview = newValue
                        guard !dragging else { return }
                        commitTask?.cancel()
                        commitTask = Task {
                            try? await Task.sleep(nanoseconds: UInt64(store.castConfig.commitDebounce * 1_000_000_000))
                            guard !Task.isCancelled else { return }
                            commit(newValue)
                        }
                    }),
                    in: Double(range.lowerBound)...Double(range.upperBound), step: 1,
                    onEditingChanged: { editing in
                        dragging = editing
                        if !editing, let preview { commitTask?.cancel(); commit(preview) }
                    })
                    .disabled(!writable || state?.volume == nil)
                    .accessibilityLabel("Volume")
                Text(state?.volume == nil ? "–" : "\(Int((preview ?? Double(state?.volume ?? 0)).rounded()))%")
                    .monospacedDigit().frame(width: 40, alignment: .trailing)
            }
            HStack {
                Button { Task { await runner.run(.volume(max((state?.volume ?? 0) - step, range.lowerBound)), on: device) } } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Volume down")
                Spacer()
                Button { Task { await runner.run(.mute(!(state?.muted ?? false)), on: device) } } label: {
                    Label(state?.muted == true ? "Unmute" : "Mute", systemImage: state?.muted == true ? "speaker.slash.fill" : "speaker.wave.2")
                }
                Spacer()
                Button { Task { await runner.run(.volume(min((state?.volume ?? 0) + step, range.upperBound)), on: device) } } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Volume up")
            }
            .disabled(!writable)
            HStack {
                musicMenu.disabled(!writable)
                Group {
                    Button { transport(.play) } label: { Image(systemName: "play.fill") }.accessibilityLabel("Resume")
                    Button { transport(.pause) } label: { Image(systemName: "pause.fill") }.accessibilityLabel("Pause")
                    Button { transport(.stop) } label: { Image(systemName: "stop.fill") }.accessibilityLabel("Stop")
                }
                .disabled(!writable || state?.appName == nil)
                Spacer()
                if let app = state?.appName { Text(app).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .sheet(isPresented: $askingURL) { CastPlayURLSheet(text: $urlText) { text in
                if let url = URL(string: text.trimmingCharacters(in: .whitespaces)) {
                    play(CastMediaSource(title: url.host ?? "Stream", url: url, isLive: false))
                }
            } }
            if let error = runner.error ?? transportError ?? reading?.lastError?.message {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}

struct CastPlayURLSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let onPlay: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Play an audio URL").font(.headline)
            TextField("https://…/stream.mp3", text: $text).textFieldStyle(.roundedBorder).frame(width: 360)
            Text("Only http(s) audio streams or files. The speaker fetches it directly.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Play") { onPlay(text); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(CastMediaSource(title: "", url: URL(string: text.trimmingCharacters(in: .whitespaces)) ?? URL(fileURLWithPath: "/")).isPlayable == false)
            }
        }
        .padding(16)
    }
}

/// Add / remove saved radio stations (used by voice: "play jazz on the study speaker").
struct CastPresetEditor: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var name = ""
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Radio stations").font(.headline)
            ForEach(store.castPresets) { preset in
                HStack {
                    Text(preset.name).lineLimit(1)
                    Spacer()
                    Button { store.removeCastPreset(id: preset.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Remove \(preset.name)")
                }
            }
            HStack {
                TextField("Name", text: $name).frame(width: 110)
                TextField("Stream URL", text: $url)
                Button("Add") {
                    if store.addCastPreset(name: name, url: url) != nil { name = ""; url = "" }
                }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || url.isEmpty)
            }
        }
    }
}

struct CastBadgeView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device

    var body: some View {
        let reading = store.castReading(for: device)
        let offline = (reading?.failures ?? 0) > 0
        let connecting = reading?.lastSuccess == nil && !offline
        let stale = store.castFreshness(for: device) == .stale
        let title = offline ? "Offline" : (connecting ? "Connecting" : (reading?.state.playback == .playing ? "Playing" : "Ready"))
        Label(stale ? "\(title) · stale" : title, systemImage: offline ? "wifi.slash" : (connecting ? "ellipsis.circle" : "checkmark.circle.fill"))
            .font(.caption.weight(.medium))
            .foregroundStyle(offline ? .red : (connecting ? .secondary : .green))
            .accessibilityLabel("Status: \(title)\(stale ? ", last known value" : "")")
    }
}

struct CastSpeakerCard: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let isSelected: Bool
    let onSelect: () -> Void

    private var subtitle: String {
        let model = store.castRecord(for: device)?.model ?? ""
        let base = model.isEmpty ? "Google Cast" : model
        return device.room.isEmpty ? base : "\(base) · \(device.room)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: DeviceKind.speaker.iconName).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                CastBadgeView(device: device)
            }
            CastControls(device: device)
            HStack { Spacer(); Button("Details", action: onSelect).controlSize(.small) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(device.name), Google Cast speaker")
    }
}

struct CastSpeakerDetailView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    @State private var confirmRemove = false
    @State private var refreshing = false
    @State private var name = ""
    @State private var room = ""

    private var record: CastSpeakerRecord? { store.castRecord(for: device) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: DeviceKind.speaker.iconName).font(.largeTitle)
                    VStack(alignment: .leading) {
                        Text(device.name).font(.title2.weight(.semibold))
                        CastBadgeView(device: device)
                    }
                }
                CastControls(device: device)
                Divider()
                if let record {
                    LabeledContent("Model", value: record.model.isEmpty ? "–" : record.model)
                    LabeledContent("Device ID", value: record.deviceID)
                    TextField("Name", text: $name).onSubmit { store.updateCastSpeaker(id: record.id, name: name) }
                    TextField("Room", text: $room).onSubmit { store.updateCastSpeaker(id: record.id, room: room) }
                }
                Divider()
                CastPresetEditor()
                Divider()
                HStack {
                    Button("Refresh") {
                        refreshing = true
                        Task { await store.refreshCast(device.id, manual: true); refreshing = false }
                    }.disabled(refreshing)
                    Spacer()
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                }
                Text("Removing only forgets this speaker in MyHome; the speaker itself is untouched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .onAppear { name = record?.name ?? ""; room = record?.room ?? "" }
        .confirmationDialog("Remove \(device.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { store.removeCastSpeaker(id: device.id) }
        }
    }
}

struct CastMenuRow: View {
    @EnvironmentObject private var store: DeviceStore
    @StateObject private var runner = KEFCommandRunner()
    let device: Device

    private var state: CastState? { store.castState(for: device) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: DeviceKind.speaker.iconName)
            Text(device.name).lineLimit(1)
            Spacer()
            Button { Task { await runner.run(.volume(max((state?.volume ?? 0) - store.castConfig.volumeStep, store.castConfig.volumeRange.lowerBound)), on: device) } } label: { Image(systemName: "minus") }
                .accessibilityLabel("Volume down")
            Text(state?.volume.map { "\($0)%" } ?? "–").monospacedDigit().frame(minWidth: 36)
            Button { Task { await runner.run(.volume(min((state?.volume ?? 0) + store.castConfig.volumeStep, store.castConfig.volumeRange.upperBound)), on: device) } } label: { Image(systemName: "plus") }
                .accessibilityLabel("Volume up")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .disabled(store.reachability(for: device) == .offline)
    }
}
