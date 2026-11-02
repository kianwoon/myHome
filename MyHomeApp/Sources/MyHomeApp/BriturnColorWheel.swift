import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Briturn-style colour plate (matches the Briturn mobile app's RGB control,
/// biz_control_page icon_rgb): a hue wheel with hue = angle, running clockwise
/// from red at 3 o'clock, and saturation = radius, white at the centre.
/// Brightness is a separate slider in the cards, as in the app, so the wheel
/// always emits full-value colours.
struct BriturnColorWheel: View {
    @Binding var color: Color
    @State private var hue: Double = 0
    @State private var saturation: Double = 0

    /// Preset swatches shown under the wheel (the mobile app's colour dots),
    /// full-value sRGB 0-255. Edit this list to change the row.
    static let presets: [(r: Double, g: Double, b: Double)] = [
        (255, 0, 0), (255, 255, 0), (0, 255, 0), (0, 255, 255),
        (0, 0, 255), (255, 0, 255), (153, 255, 0), (144, 255, 0)
    ]
    static let presetMatchTolerance = 0.03

    private static let hueStops: [Gradient.Stop] = stride(from: 0, through: 360, by: 30).map {
        Gradient.Stop(color: Color(hue: Double($0) / 360, saturation: 1, brightness: 1),
                      location: Double($0) / 360)
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side / 2
            ZStack {
                Circle().fill(AngularGradient(stops: Self.hueStops, center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)],
                                             center: .center, startRadius: 0, endRadius: radius))
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1)
                Circle()
                    .fill(Color(hue: hue, saturation: saturation, brightness: 1))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(radius: 1.5)
                    .offset(x: CGFloat(cos(hue * 2 * .pi) * saturation) * radius,
                            y: CGFloat(sin(hue * 2 * .pi) * saturation) * radius)
            }
            .frame(width: side, height: side)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let dx = Double(value.location.x - geo.size.width / 2)
                let dy = Double(value.location.y - geo.size.height / 2)
                var turns = atan2(dy, dx) / (2 * .pi)
                if turns < 0 { turns += 1 }
                hue = turns
                saturation = min(1, (dx * dx + dy * dy).squareRoot() / Double(radius))
                color = Color(hue: hue, saturation: saturation, brightness: 1)
            })
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear(perform: syncFromColor)
        .onChange(of: color) { _ in syncFromColor() }
    }

    /// Follow external changes (bulb read-back) without disturbing the knob
    /// while the colour is achromatic, where hue is undefined.
    private func syncFromColor() {
        #if canImport(AppKit)
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s > 0.001 { hue = Double(h) }
        saturation = Double(s)
        #endif
    }
}

/// Briturn's white plate (right-hand tab in the mobile app): a disc whose
/// vertical axis is colour temperature — warm orange at the top, soft white in
/// the middle, cool blue-white at the bottom. Emits the plate colour at the
/// touched height. With `onCCT` set it also reports the plate position as a
/// 0-100 colour temperature (0 = warm, 100 = cool) so the caller can drive the
/// bulb's real warm/cool white channels; without it, the colour binding is the
/// only output (RGB approximation).
struct BriturnWhitePlate: View {
    @Binding var color: Color
    var onCCT: ((Int) -> Void)? = nil
    private static let cctMax = 100.0
    @State private var position: Double?

    /// (height 0 = top ... 1 = bottom, sRGB 0-255), sampled from the Briturn
    /// app's plate.
    private static let stops: [(Double, (Double, Double, Double))] = [
        (0.0, (255, 147, 41)), (0.5, (253, 236, 226)), (1.0, (210, 224, 255))
    ]
    private static let matchTolerance = 0.04

    static func rgb(at t: Double) -> (Double, Double, Double) {
        let t = min(1, max(0, t))
        let hi = stops.firstIndex { $0.0 >= t } ?? stops.count - 1
        let lo = max(0, hi - 1)
        let span = stops[hi].0 - stops[lo].0
        let f = span > 0 ? (t - stops[lo].0) / span : 0
        let a = stops[lo].1, b = stops[hi].1
        return (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
    }

    static func color(at t: Double) -> Color {
        let c = rgb(at: t)
        return Color(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255)
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(LinearGradient(
                    stops: Self.stops.map { Gradient.Stop(color: Self.color(at: $0.0), location: $0.0) },
                    startPoint: .top, endPoint: .bottom))
                Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1)
                if let t = position {
                    Circle()
                        .fill(Self.color(at: t))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .shadow(radius: 1.5)
                        .offset(y: CGFloat(t - 0.5) * side)
                }
            }
            .frame(width: side, height: side)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let t = min(1, max(0, Double((value.location.y - (geo.size.height - side) / 2) / side)))
                position = t
                color = Self.color(at: t)
                onCCT?(Int((t * Self.cctMax).rounded()))
            })
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear(perform: syncFromColor)
        .onChange(of: color) { _ in syncFromColor() }
    }

    /// Show the knob only when the current colour sits on the plate.
    private func syncFromColor() {
        #if canImport(AppKit)
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
        let cur = (Double(ns.redComponent) * 255, Double(ns.greenComponent) * 255, Double(ns.blueComponent) * 255)
        var best: (t: Double, d: Double) = (0, .infinity)
        for step in 0...100 {
            let t = Double(step) / 100
            let c = Self.rgb(at: t)
            let d = ((c.0 - cur.0) * (c.0 - cur.0) + (c.1 - cur.1) * (c.1 - cur.1)
                     + (c.2 - cur.2) * (c.2 - cur.2)).squareRoot() / 441.7
            if d < best.d { best = (t, d) }
        }
        position = best.d <= Self.matchTolerance ? best.t : nil
        #endif
    }
}

/// Compact swatch that opens the Briturn plates in a popover — drop-in for the
/// macOS ColorPicker well. Two tabs as in the mobile app: colour wheel and
/// white plate. `title` is shown beside the swatch when non-empty.
struct BriturnColorButton: View {
    let title: String
    @Binding var color: Color
    /// Fires with 0-100 (0 warm, 100 cool) from the white tab INSTEAD of
    /// writing `color`, so callers that send RGB on colour change don't also
    /// send an RGB approximation. nil = white tab writes `color` (RGB path).
    var onCCT: ((Int) -> Void)? = nil
    var showsWhiteTab: Bool = true
    @State private var showing = false
    @State private var whiteTab = false
    /// Swatch colour for the white-plate position when onCCT is in use; kept
    /// local so the parent's `color` (and its RGB send) is untouched.
    @State private var plateSwatch: Color?

    private var swatchColor: Color { plateSwatch ?? color }

    private var plateBinding: Binding<Color> {
        guard onCCT != nil else { return $color }
        return Binding(get: { plateSwatch ?? color }, set: { plateSwatch = $0 })
    }

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 6) {
                if !title.isEmpty { Text(title) }
                Circle()
                    .fill(swatchColor)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.primary.opacity(0.3), lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(spacing: 12) {
                if whiteTab && showsWhiteTab {
                    BriturnWhitePlate(color: plateBinding, onCCT: onCCT).frame(width: 200, height: 200)
                } else {
                    BriturnColorWheel(color: $color).frame(width: 200, height: 200)
                    presetRow
                }
                HStack(spacing: 10) {
                    tabButton(selected: !whiteTab, action: { whiteTab = false }) {
                        Circle().fill(AngularGradient(colors: (0...6).map {
                            Color(hue: Double($0) / 6, saturation: 1, brightness: 1)
                        }, center: .center))
                    }
                    if showsWhiteTab {
                        tabButton(selected: whiteTab, action: { whiteTab = true }) {
                            Circle().fill(LinearGradient(
                                colors: [BriturnWhitePlate.color(at: 0), BriturnWhitePlate.color(at: 0.5),
                                         BriturnWhitePlate.color(at: 1)],
                                startPoint: .top, endPoint: .bottom))
                        }
                    }
                }
            }
            .padding(14)
        }
        .onChange(of: color) { _ in plateSwatch = nil }
    }

    private static let presetSize: CGFloat = 22
    private static let presetSpacing: CGFloat = 6

    /// Row of preset colour dots; tapping one sets `color` like a wheel pick.
    private var presetRow: some View {
        HStack(spacing: Self.presetSpacing) {
            ForEach(Array(BriturnColorWheel.presets.enumerated()), id: \.offset) { _, p in
                let selected = presetMatches(p)
                Button {
                    color = Color(red: p.r / 255, green: p.g / 255, blue: p.b / 255)
                } label: {
                    Circle()
                        .fill(Color(red: p.r / 255, green: p.g / 255, blue: p.b / 255))
                        .frame(width: Self.presetSize, height: Self.presetSize)
                        .overlay(Circle().stroke(selected ? Color.accentColor : Color.primary.opacity(0.25),
                                                 lineWidth: selected ? 2 : 1).padding(-3))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func presetMatches(_ p: (r: Double, g: Double, b: Double)) -> Bool {
        #if canImport(AppKit)
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return false }
        let dr = Double(ns.redComponent) * 255 - p.r
        let dg = Double(ns.greenComponent) * 255 - p.g
        let db = Double(ns.blueComponent) * 255 - p.b
        return (dr * dr + dg * dg + db * db).squareRoot() / 441.7 <= BriturnColorWheel.presetMatchTolerance
        #else
        return false
        #endif
    }

    private func tabButton<Content: View>(
        selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(selected ? Color.accentColor : Color.primary.opacity(0.25),
                                         lineWidth: selected ? 2 : 1).padding(-3))
        }
        .buttonStyle(.plain)
    }
}
