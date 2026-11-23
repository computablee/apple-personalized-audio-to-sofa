import HRTFKit
import SwiftUI

/// 2D direction picker: drag around a top-down head to set azimuth, and along a side-view arc to set elevation.
/// Directions use the SOFA convention: azimuth counter-clockwise from the front (90° = left, 180° = behind,
/// 270° = right), elevation −90° (below) to +90° (above).
public struct DirectionPicker: View {
    @Binding var azimuth: Double
    @Binding var elevation: Double
    /// Measurement actually used (SOFA convention), shown as a hollow ring.
    let matched: (azimuth: Double, elevation: Double)?
    let onBegin: () -> Void
    @Environment(\.colorScheme) var scheme

    public init(azimuth: Binding<Double>, elevation: Binding<Double>,
                matched: (azimuth: Double, elevation: Double)?, onBegin: @escaping () -> Void = {}) {
        _azimuth = azimuth
        _elevation = elevation
        self.matched = matched
        self.onBegin = onBegin
    }

    var accent: Color { Palette.colors(scheme)[1] }       // same colour as the "Custom" curve
    var ink: Color { scheme == .dark ? Palette.diffuseDark : Palette.diffuseLight }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Direction").font(.headline)
            Text("Top view (azimuth)").font(.caption).foregroundColor(.secondary)
            topView.frame(width: 190, height: 190)
            Text("Side view (elevation)").font(.caption).foregroundColor(.secondary)
            sideView.frame(width: 190, height: 190)
            VStack(alignment: .leading, spacing: 2) {
                Text("Requested: az \(Int(azimuth.rounded()))°, el \(Int(elevation.rounded()))°")
                    .font(.caption.monospacedDigit())
                if let m = matched {
                    Text("Measured: az \(Int(m.azimuth.rounded()))°, el \(Int(m.elevation.rounded()))°")
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                }
                Text(Self.describe(azimuth: azimuth, elevation: elevation))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    /// Plain-language description, e.g. "behind, slightly left, above".
    static func describe(azimuth a: Double, elevation e: Double) -> String {
        var parts: [String] = []
        let az = a.truncatingRemainder(dividingBy: 360)
        let fb = cos(az * .pi / 180), lr = sin(az * .pi / 180)
        if fb > 0.38 { parts.append("in front") } else if fb < -0.38 { parts.append("behind") }
        if lr > 0.38 { parts.append("left") } else if lr < -0.38 { parts.append("right") }
        if parts.isEmpty { parts.append("in front") }
        if e > 20 { parts.append("above") } else if e < -20 { parts.append("below") } else { parts.append("ear height") }
        return parts.joined(separator: ", ")
    }

    // MARK: Top view: front is up, the listener's left is screen-left.

    var topView: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let ring = size / 2 - 16
            let head = size * 0.17
            ZStack {
                Circle().stroke(ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: ring * 2, height: ring * 2).position(c)
                headTop(center: c, radius: head)
                label("Front", at: CGPoint(x: c.x, y: c.y - ring - 9))
                label("Behind", at: CGPoint(x: c.x, y: c.y + ring + 9))
                label("L", at: CGPoint(x: c.x - ring - 9, y: c.y))
                label("R", at: CGPoint(x: c.x + ring + 9, y: c.y))
                if let m = matched {
                    Circle().stroke(accent, lineWidth: 2).frame(width: 14, height: 14)
                        .position(Self.topPoint(azimuth: m.azimuth, center: c, radius: ring))
                }
                Path { p in
                    p.move(to: c)
                    p.addLine(to: Self.topPoint(azimuth: azimuth, center: c, radius: ring))
                }
                .stroke(accent.opacity(0.6), lineWidth: 1.5)
                Circle().fill(accent).frame(width: 10, height: 10)
                    .position(Self.topPoint(azimuth: azimuth, center: c, radius: ring))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onBegin()
                let dx = g.location.x - c.x, dy = g.location.y - c.y
                guard dx * dx + dy * dy > 4 else { return }
                var a = atan2(-dx, -dy) * 180 / .pi
                if a < 0 { a += 360 }
                azimuth = a.rounded()
            })
            .help("Drag around the head to choose the azimuth")
        }
    }

    static func topPoint(azimuth a: Double, center c: CGPoint, radius r: CGFloat) -> CGPoint {
        let t = a * .pi / 180
        return CGPoint(x: c.x - r * CGFloat(sin(t)), y: c.y - r * CGFloat(cos(t)))
    }

    func headTop(center c: CGPoint, radius r: CGFloat) -> some View {
        ZStack {
            // nose (front = up)
            Path { p in
                p.move(to: CGPoint(x: c.x - r * 0.28, y: c.y - r * 0.92))
                p.addLine(to: CGPoint(x: c.x, y: c.y - r * 1.32))
                p.addLine(to: CGPoint(x: c.x + r * 0.28, y: c.y - r * 0.92))
            }
            .fill(ink.opacity(0.25))
            // ears
            Ellipse().fill(ink.opacity(0.25)).frame(width: r * 0.36, height: r * 0.7)
                .position(x: c.x - r * 1.05, y: c.y)
            Ellipse().fill(ink.opacity(0.25)).frame(width: r * 0.36, height: r * 0.7)
                .position(x: c.x + r * 1.05, y: c.y)
            Circle().fill(ink.opacity(0.18)).frame(width: r * 2, height: r * 2).position(c)
            Circle().stroke(ink.opacity(0.6), lineWidth: 1.5).frame(width: r * 2, height: r * 2).position(c)
        }
    }

    // MARK: Side view: the head faces right; drag on the arc to set elevation.

    var sideView: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let ring = size / 2 - 16
            let head = size * 0.17
            ZStack {
                Path { p in
                    p.addArc(center: c, radius: ring, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                }
                .stroke(ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Path { p in
                    p.move(to: CGPoint(x: c.x - ring * 0.2, y: c.y))
                    p.addLine(to: CGPoint(x: c.x + ring, y: c.y))
                }
                .stroke(ink.opacity(0.25), lineWidth: 1)
                headSide(center: c, radius: head)
                label("Above", at: CGPoint(x: c.x, y: c.y - ring - 9))
                label("Below", at: CGPoint(x: c.x, y: c.y + ring + 9))
                label("0°", at: CGPoint(x: c.x + ring + 10, y: c.y))
                if let m = matched {
                    Circle().stroke(accent, lineWidth: 2).frame(width: 14, height: 14)
                        .position(Self.sidePoint(elevation: m.elevation, center: c, radius: ring))
                }
                Path { p in
                    p.move(to: c)
                    p.addLine(to: Self.sidePoint(elevation: elevation, center: c, radius: ring))
                }
                .stroke(accent.opacity(0.6), lineWidth: 1.5)
                Circle().fill(accent).frame(width: 10, height: 10)
                    .position(Self.sidePoint(elevation: elevation, center: c, radius: ring))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onBegin()
                let dx = g.location.x - c.x, dy = g.location.y - c.y
                guard dx * dx + dy * dy > 4 else { return }
                var e = atan2(-dy, max(dx, 0.0001)) * 180 / .pi
                e = max(-90, min(90, e))
                elevation = e.rounded()
            })
            .help("Drag along the arc to choose the elevation")
        }
    }

    static func sidePoint(elevation e: Double, center c: CGPoint, radius r: CGFloat) -> CGPoint {
        let t = e * .pi / 180
        return CGPoint(x: c.x + r * CGFloat(cos(t)), y: c.y - r * CGFloat(sin(t)))
    }

    func headSide(center c: CGPoint, radius r: CGFloat) -> some View {
        ZStack {
            // nose (facing right)
            Path { p in
                p.move(to: CGPoint(x: c.x + r * 0.92, y: c.y - r * 0.28))
                p.addLine(to: CGPoint(x: c.x + r * 1.32, y: c.y + r * 0.05))
                p.addLine(to: CGPoint(x: c.x + r * 0.92, y: c.y + r * 0.3))
            }
            .fill(ink.opacity(0.25))
            Circle().fill(ink.opacity(0.18)).frame(width: r * 2, height: r * 2).position(c)
            Circle().stroke(ink.opacity(0.6), lineWidth: 1.5).frame(width: r * 2, height: r * 2).position(c)
            // ear
            Ellipse().fill(ink.opacity(0.35)).frame(width: r * 0.36, height: r * 0.62)
                .position(x: c.x - r * 0.1, y: c.y)
        }
    }

    func label(_ s: String, at p: CGPoint) -> some View {
        Text(s).font(.caption2).foregroundColor(.secondary).position(p)
    }
}
