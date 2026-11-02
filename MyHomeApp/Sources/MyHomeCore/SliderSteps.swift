import Foundation

/// Pure helpers deciding how a spec-driven numeric slider is drawn and how its
/// committed value is snapped to the DP step.
public enum SliderSteps {
    /// A stepped SwiftUI Slider becomes an NSSlider with one tick mark per
    /// step, and NSSlider re-lays out every tick on each layout pass. Only
    /// ranges with at most this many steps keep `step:` (ticks intended).
    public static let maxDiscreteSteps = 20

    public static func isDiscrete(range: ClosedRange<Double>, step: Double?) -> Bool {
        let s = effectiveStep(step)
        return (range.upperBound - range.lowerBound) / s <= Double(maxDiscreteSteps)
    }

    /// Round to the nearest step measured from the range's lower bound, then
    /// clamp to the range. Used for the value committed to the device.
    public static func snap(value: Double, range: ClosedRange<Double>, step: Double?) -> Double {
        let s = effectiveStep(step)
        let steps = ((value - range.lowerBound) / s).rounded()
        let snapped = range.lowerBound + steps * s
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    private static func effectiveStep(_ step: Double?) -> Double {
        guard let step, step > 0 else { return 1 }
        return step
    }
}
