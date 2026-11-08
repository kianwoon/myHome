// Displayed Briturn brightness, consistent across transports. An OFF light's
// channel bytes depend on where the reading came from: the cloud frame of an
// off light can carry zeroed (or white-only) channels, while a Bluetooth
// power-only update keeps the last colour bytes. Deriving brightness from the
// raw channels made one off light show 0 and its group mate 57. While off,
// every card shows the last brightness the light had while ON instead.

import Foundation

extension DeviceStore.BriturnState {
    /// Brightness percent the channels encode, regardless of power: the peak
    /// colour channel, or the combined white level when rgb is all zero.
    /// For an ON light this equals the cards' original derivation.
    public var channelBrightnessPercent: Double {
        let peak = max(r, g, b)
        let level = peak > 0 ? peak : whiteLevel
        return Double(level) * Double(DeviceStore.briturnPercentMax) / Double(DeviceStore.briturnChannelMax)
    }
}

extension DeviceStore {
    /// Brightness percent a card should show: live channels while ON; while
    /// OFF the last ON level (falling back to the channels when never seen on).
    public func briturnDisplayBrightness(_ id: String) -> Double? {
        guard let state = briturnStatus[id] else { return nil }
        if state.on { return state.channelBrightnessPercent }
        return lastOnBrightness[id] ?? state.channelBrightnessPercent
    }

    /// Records each ON light's non-zero level; called on every status change.
    func rememberOnBrightness() {
        for (id, state) in briturnStatus where state.on {
            let level = state.channelBrightnessPercent
            if level > 0, lastOnBrightness[id] != level { lastOnBrightness[id] = level }
        }
    }
}
