import AppKit
import Charts
import HRTFKit
import SwiftUI

/// Shared crosshair state (an ObservableObject because @State is a macro that the
/// Command Line Tools toolchain can't expand).
public final class ChartHover: ObservableObject {
    @Published public var frequency: Double? = nil
    public init() {}
}

enum Palette {
    // Categorical slots 1-4 (validated light + dark), diffuse field as dashed neutral ink.
    static let light: [Color] = [rgb(0x2a78d6), rgb(0xeb6834), rgb(0x1baf7a), rgb(0xeda100)]
    static let dark: [Color] = [rgb(0x3987e5), rgb(0xd95926), rgb(0x199e70), rgb(0xc98500)]
    static let diffuseLight = rgb(0x52514e)
    static let diffuseDark = rgb(0xc3c2b7)
    static let surfaceLight = rgb(0xfcfcfb)

    static func rgb(_ v: Int) -> Color {
        Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    static func colors(_ scheme: ColorScheme) -> [Color] {
        (scheme == .dark ? dark : light) + [scheme == .dark ? diffuseDark : diffuseLight]
    }

    static var labels: [String] { HRTFAnalysis.directions.map { $0.0 } + [HRTFAnalysis.diffuseLabel] }
}

func formatHz(_ f: Double) -> String {
    if f >= 1000 {
        let k = f / 1000
        return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
    }
    return "\(Int(f.rounded()))"
}

func yDomain(_ r: HRTFAnalysis.Result) -> ClosedRange<Double> {
    var lo = Double.infinity, hi = -Double.infinity
    for c in r.curves {
        for p in c.points { lo = min(lo, p.level); hi = max(hi, p.level) }
    }
    let top = (hi / 5).rounded(.up) * 5 + 5
    let bottom = max((lo / 5).rounded(.down) * 5, top - 60)
    return bottom...top
}

struct EarChart: View {
    let result: HRTFAnalysis.Result
    let ear: Int
    let domain: ClosedRange<Double>
    @ObservedObject var hover: ChartHover
    @Environment(\.colorScheme) var scheme

    static let ticks: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]

    /// Edge ticks are anchored inward so their labels aren't dropped or truncated.
    static func labelAnchor(_ f: Double) -> UnitPoint {
        if f <= ticks[0] { return .topLeading }
        if f >= ticks[ticks.count - 1] { return .topTrailing }
        return .top
    }

    var body: some View {
        let curves = result.curves(ear: ear)
        VStack(alignment: .leading, spacing: 6) {
            Text(ear == 0 ? "Left ear" : "Right ear").font(.headline)
            chart(curves)
            readout(curves)
        }
    }

    func chart(_ curves: [HRTFAnalysis.Curve]) -> some View {
        Chart {
            ForEach(curves) { c in
                ForEach(c.points) { p in
                    LineMark(x: .value("Frequency", p.frequency),
                             y: .value("Level", p.level),
                             series: .value("Curve", c.label))
                        .foregroundStyle(by: .value("Curve", c.label))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: c.isDiffuse ? [6, 4] : []))
                }
            }
            if let f = hover.frequency {
                RuleMark(x: .value("Frequency", f))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartForegroundStyleScale(domain: Palette.labels, range: Palette.colors(scheme))
        .chartLegend(.hidden)
        .chartXScale(domain: HRTFAnalysis.fMin...HRTFAnalysis.fMax, type: .log)
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: EarChart.ticks) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(anchor: EarChart.labelAnchor(value.as(Double.self) ?? 0)) {
                    if let v = value.as(Double.self) { Text(formatHz(v)) }
                }
            }
        }
        .chartYAxis { AxisMarks(position: .leading, values: .stride(by: 10)) }
        .chartXAxisLabel("Frequency (Hz)")
        .chartYAxisLabel("Level (dB)")
        .chartPlotStyle { $0.clipped() }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let x = location.x - geo[proxy.plotAreaFrame].origin.x
                            if let f: Double = proxy.value(atX: x), f >= HRTFAnalysis.fMin, f <= HRTFAnalysis.fMax {
                                hover.frequency = f
                            } else {
                                hover.frequency = nil
                            }
                        case .ended:
                            hover.frequency = nil
                        }
                    }
            }
        }
    }

    func readout(_ curves: [HRTFAnalysis.Curve]) -> some View {
        let colors = Palette.colors(scheme)
        return HStack(spacing: 14) {
            if let f = hover.frequency {
                Text(formatHz(f) + " Hz").font(.caption.monospacedDigit()).foregroundColor(.primary)
                ForEach(Array(curves.enumerated()), id: \.offset) { i, c in
                    HStack(spacing: 4) {
                        Circle().fill(colors[min(i, colors.count - 1)]).frame(width: 8, height: 8)
                        Text("\(c.label) " + String(format: "%+.1f dB", level(c, at: f)))
                            .font(.caption.monospacedDigit()).foregroundColor(.primary)
                    }
                }
            } else {
                Text("Hover the chart to read values").font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(height: 16)
    }

    func level(_ c: HRTFAnalysis.Curve, at f: Double) -> Double {
        let n = c.points.count
        let t = log(f / HRTFAnalysis.fMin) / log(HRTFAnalysis.fMax / HRTFAnalysis.fMin)
        let i = max(0, min(n - 1, Int((t * Double(n - 1)).rounded())))
        return c.points[i].level
    }
}

struct LegendRow: View {
    @Environment(\.colorScheme) var scheme

    var body: some View {
        let colors = Palette.colors(scheme)
        HStack(spacing: 18) {
            ForEach(Array(Palette.labels.enumerated()), id: \.offset) { i, label in
                HStack(spacing: 6) {
                    Path { p in p.move(to: CGPoint(x: 0, y: 5)); p.addLine(to: CGPoint(x: 22, y: 5)) }
                        .stroke(colors[i], style: StrokeStyle(lineWidth: 2, dash: i == colors.count - 1 ? [6, 4] : []))
                        .frame(width: 22, height: 10)
                    Text(label).font(.callout).foregroundColor(.primary)
                }
            }
        }
    }
}

/// Both ears side by side with a shared legend.
public struct HRTFPlotView: View {
    let result: HRTFAnalysis.Result
    @ObservedObject var hover: ChartHover

    public init(result: HRTFAnalysis.Result, hover: ChartHover) {
        self.result = result
        self.hover = hover
    }

    var subtitle: String {
        var parts: [String] = []
        let s = result.options.smoothing
        parts.append(s > 0 ? "1/\(Int(s))-octave smoothing" : "no smoothing")
        parts.append(result.options.effectiveAddCTF ? "Apple CTF added back (diffuse-field EQ undone)" : "as stored (diffuse-field equalized)")
        parts.append(result.options.reference == .eardrum
            ? "EARDRUM: + population-average ear canal (Hammershøi & Møller 2008), not your own"
            : "referenced to ear-canal entrance (assumed)")
        if result.options.mirror { parts.append("mirrored ear mapping") }
        return parts.joined(separator: " · ")
    }

    var directionNote: String {
        let left = result.curves(ear: 0)
        let used = left.compactMap { c -> String? in
            guard let m = c.matched else { return nil }
            return "\(c.label): az \(Int(m.azimuth.rounded()))°, el \(Int(m.elevation.rounded()))°"
        }
        return "Measurement used (SOFA convention, azimuth counter-clockwise, 90° = left) - " + used.joined(separator: "; ")
    }

    public var body: some View {
        let domain = yDomain(result)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HRTF magnitude - \(result.sourceFile)").font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundColor(.secondary)
            }
            LegendRow()
            HStack(alignment: .top, spacing: 24) {
                EarChart(result: result, ear: 0, domain: domain, hover: hover)
                EarChart(result: result, ear: 1, domain: domain, hover: hover)
            }
            Text(directionNote).font(.caption).foregroundColor(.secondary)
        }
    }
}

public enum HRTFPlotExport {
    public enum ExportError: Error { case renderFailed }

    /// Renders the plot (light appearance) to a PNG file.
    @MainActor
    public static func writePNG(_ result: HRTFAnalysis.Result, to url: URL, width: CGFloat = 1400, height: CGFloat = 640) throws {
        let view = HRTFPlotView(result: result, hover: ChartHover())
            .padding(24)
            .frame(width: width, height: height)
            .background(Palette.surfaceLight)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { throw ExportError.renderFailed }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw ExportError.renderFailed }
        try data.write(to: url)
    }
}
