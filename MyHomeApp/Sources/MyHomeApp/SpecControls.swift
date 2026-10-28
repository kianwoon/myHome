// baseline-guard:allow new spec-driven controls source, no prior baseline
import SwiftUI
import MyHomeCore

/// Renders one control per upstream-declared dp. Inferred controls live in
/// RichControlView and are shown only for dps the spec does not declare.
struct SpecControlsView: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let state: DeviceState

    var body: some View {
        let controls = state.controlCapabilities
        if controls.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(controls) { capability in
                    CapabilityRow(device: device, state: state, capability: capability)
                }
            }
        }
    }

}

private struct CapabilityRow: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let state: DeviceState
    let capability: Capability

    @State private var numberValue: Double = 0
    @State private var editingNumber = false

    var body: some View {
        switch capability.kind {
        case .boolean:
            Toggle(isOn: Binding(
                get: { state.dps[capability.dpId]?.boolValue ?? false },
                set: { newValue in
                    Task {
                        await store.setDps(
                            device,
                            [capability.dpId: newValue],
                            optimistic: [capability.dpId: .bool(newValue)]
                        )
                    }
                }
            )) {
                Text(capability.displayName)
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

        case .enumeration:
            HStack(spacing: 8) {
                Text(capability.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: {
                        state.dps[capability.dpId]?.stringValue
                            ?? capability.range.first
                            ?? ""
                    },
                    set: { newValue in
                        Task {
                            await store.setDps(
                                device,
                                [capability.dpId: newValue],
                                optimistic: [capability.dpId: .string(newValue)]
                            )
                        }
                    }
                )) {
                    ForEach(enumOptions(capability), id: \.self) { value in
                        Text(enumLabel(value, in: capability)).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }

        case .integer:
            // General rule: a stepped SwiftUI Slider becomes an AppKit slider
            // with (max-min)/step TICK MARKS, and AppKit rebuilds every tick
            // rect on each layout (NSSliderTickMarks._rebuildTickMarkRectCache).
            // Upstream declares dps like countdown_1 (0-86400s, step 1): a
            // stepped slider there is 86,400 tick rects per card per render —
            // the 100% CPU hang. So: countdown/timer dps are not sliders at
            // all, and any range whose tick count would exceed 100 renders
            // step-free (continuous, zero tick marks).
            if capability.code.lowercased().contains("countdown") {
                // Countdown dps get an explicit preset picker, never a stepped
                // slider: seconds are written directly, so no tick marks exist.
                CountdownPicker(device: device, state: state, capability: capability)
            } else if let lower = capability.minValue, let upper = capability.maxValue {
                // Invariant: a stepped SwiftUI Slider renders (max-min)/step
                // AppKit TICK MARKS, rebuilt on every layout pass — so only
                // SMALL ranges may be stepped; large ranges render
                // continuous (zero tick marks).
                let ticks = (upper - lower) / (capability.step ?? 1)
                if ticks <= 100 {
                HStack(spacing: 8) {
                    Text(capability.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $numberValue,
                        in: lower...max(lower, upper),
                        step: max(capability.step ?? 1, 0.1),
                        onEditingChanged: { editing in
                            editingNumber = editing
                            if !editing {
                                Task {
                                    await store.setDps(device, [capability.dpId: numberValue])
                                }
                            }
                        }
                    )
                    .controlSize(.mini)
                    Text(numberLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
                .onAppear {
                    numberValue = state.dps[capability.dpId]?.doubleValue ?? lower
                }
                .onChange(of: state.dps[capability.dpId]?.doubleValue ?? lower) { newValue in
                    if !editingNumber {
                        numberValue = newValue
                    }
                }
                } else {
                    // Continuous slider: no step, therefore no tick marks.
                    HStack(spacing: 8) {
                        Text(capability.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $numberValue,
                               in: lower...max(lower, upper)) { editing in
                            editingNumber = editing
                            if !editing {
                                Task { await store.setDps(device, [capability.dpId: numberValue]) }
                            }
                        }
                        .controlSize(.mini)
                        Text(numberLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                    .onAppear {
                        numberValue = state.dps[capability.dpId]?.doubleValue ?? lower
                    }
                }
            }

        default:
            EmptyView()
        }
    }

    private var numberLabel: String {
        let text = DPSValue.format(numberValue)
        if let unit = capability.unit, !unit.isEmpty {
            return "\(text) \(unit)"
        }
        return text
    }

    /// General rule: an enum picker must never go blank. A status value the
    /// spec's range does not include (degraded firmware, cloud fallback) is
    /// appended as its own option so the current state stays visible and a
    /// valid option is one click away.
    private func enumOptions(_ capability: Capability) -> [String] {
        let current = state.dps[capability.dpId]?.stringValue
        guard let current, !current.isEmpty else { return capability.range }
        return capability.range.contains(current)
            ? capability.range
            : capability.range + [current]
    }

    private func enumLabel(_ value: String, in capability: Capability) -> String {
        capability.range.contains(value)
            ? value.capitalized
            : "\(value.capitalized) (custom)"
    }
}

/// Preset timer control for spec-declared countdown dps. Values are written as
/// integer seconds through the normal setDps path; a status value that matches
/// no preset appears as its own option so the current setting stays visible.
private struct CountdownPicker: View {
    @EnvironmentObject private var store: DeviceStore
    let device: Device
    let state: DeviceState
    let capability: Capability

    private static let presets: [(seconds: Int, label: String)] = [
        (0, "Off"),
        (900, "15 min"),
        (1800, "30 min"),
        (3600, "1 h"),
        (7200, "2 h"),
        (14400, "4 h"),
        (28800, "8 h"),
    ]

    var body: some View {
        let current = max(0, state.dps[capability.dpId]?.intValue ?? 0)
        let options = Self.presets.contains { $0.seconds == current }
            ? Self.presets
            : Self.presets + [(current, Self.durationLabel(current))]

        HStack(spacing: 8) {
            Text(capability.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("Timer", selection: Binding(
                get: { current },
                set: { seconds in
                    Task {
                        await store.setDps(
                            device,
                            [capability.dpId: seconds],
                            optimistic: [capability.dpId: .number(Double(seconds))]
                        )
                    }
                }
            )) {
                ForEach(options, id: \.seconds) { option in
                    Text(option.label).tag(option.seconds)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
        }
    }

    private static func durationLabel(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 { return "\(minutes) min" }
        return "\(seconds) s"
    }
}
