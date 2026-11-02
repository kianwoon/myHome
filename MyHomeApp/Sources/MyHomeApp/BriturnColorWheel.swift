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

/// Compact swatch that opens the Briturn wheel in a popover — drop-in for the
/// macOS ColorPicker well. `title` is shown beside the swatch when non-empty.
struct BriturnColorButton: View {
    let title: String
    @Binding var color: Color
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 6) {
                if !title.isEmpty { Text(title) }
                Circle()
                    .fill(color)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.primary.opacity(0.3), lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            BriturnColorWheel(color: $color)
                .frame(width: 200, height: 200)
                .padding(14)
        }
    }
}
