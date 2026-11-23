import AppKit
import Charts
import HRTFKit
import SwiftUI

/// Shared interaction state: crosshair frequency and the highlighted curve.
/// (An ObservableObject because @State is a macro that the Command Line Tools toolchain can't expand.)
public final class ChartHover: ObservableObject {
    @Published public var frequency: Double? = nil
    /// Label of the highlighted curve (nil = show all).
    @Published public var selected: String? = nil
    public init() {}

    func toggle(_ label: String) { selected = (selected == label) ? nil : label }
}

enum Palette {
    // Categorical slots 1-3 only: on line charts every pair of lines can sit side by side, and only the
    // first three slots pass the all-pairs colour-vision checks in both modes. More series -> facets.
    static let light: [Color] = [rgb(0x2a78d6), rgb(0xeb6834), rgb(0x1baf7a)]
    static let dark: [Color] = [rgb(0x3987e5), rgb(0xd95926), rgb(0x199e70)]
    static let diffuseLight = rgb(0x52514e)
    static let diffuseDark = rgb(0xc3c2b7)
    static let dimmedLight = rgb(0xc8c7c0)
    static let dimmedDark = rgb(0x4a4945)
    static let surfaceLight = rgb(0xfcfcfb)

    static func rgb(_ v: Int) -> Color {
        Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    /// Colours by position within a panel: three directions, then the diffuse field.
    static func colors(_ scheme: ColorScheme) -> [Color] {
        (scheme == .dark ? dark : light) + [scheme == .dark ? diffuseDark : diffuseLight]
    }

    static func dimmed(_ scheme: ColorScheme) -> Color { scheme == .dark ? dimmedDark : dimmedLight }
}

/// Two facets per ear: the horizontal plane and the median plane, each with the diffuse field.
struct Panel {
    let title: String
    let labels: [String]      // directions in colour order, diffuse field last

    static let all: [Panel] = [
        Panel(title: "Horizontal plane: front, 45° left, 45° right",
              labels: ["Front", "45° left", "45° right", HRTFAnalysis.diffuseLabel]),
        Panel(title: "Median plane: front, 45° up, 45° down",
              labels: ["Front", "45° up", "45° down", HRTFAnalysis.diffuseLabel]),
    ]

    /// Panels for a result: the two fixed facets, plus a custom-direction facet when one was requested.
    static func panels(for result: HRTFAnalysis.Result) -> [Panel] {
        var p = all
        if let req = result.options.custom,
           let c = result.curves.first(where: { $0.label == HRTFAnalysis.customLabel }), let m = c.matched {
            p.insert(Panel(title: "Custom direction: requested az \(Int(req.azimuth.rounded()))°, el \(Int(req.elevation.rounded()))° → nearest measured az \(Int(m.azimuth.rounded()))°, el \(Int(m.elevation.rounded()))°",
                           labels: ["Front", HRTFAnalysis.customLabel, HRTFAnalysis.diffuseLabel]), at: 0)
        }
        return p
    }

    /// The highlighted label if it belongs to this panel.
    func selection(_ interaction: ChartHover) -> String? {
        guard let s = interaction.selected, labels.contains(s) else { return nil }
        return s
    }

    func color(_ label: String, _ scheme: ColorScheme, selected: String?) -> Color {
        if let s = selected, s != label { return Palette.dimmed(scheme) }
        let colors = Palette.colors(scheme)
        if label == HRTFAnalysis.diffuseLabel { return colors[colors.count - 1] }     // always the neutral ink
        let i = labels.firstIndex(of: label) ?? 0
        return colors[min(i, colors.count - 2)]
    }
}

func formatHz(_ f: Double) -> String {
    if f >= 1000 {
        let k = f / 1000
        return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
    }
    return "\(Int(f.rounded()))"
}

func yDomain(_ r: HRTFAnalysis.Result) -> ClosedRange<Double> {
    // Fixed per file/settings: spans every measured direction, so dragging the custom direction never rescales it.
    let lo = r.levelRange.lowerBound, hi = r.levelRange.upperBound
    let top = (hi / 5).rounded(.up) * 5 + 5
    let bottom = max((lo / 5).rounded(.down) * 5, top - 60)
    return bottom...top
}

struct EarChart: View {
    let result: HRTFAnalysis.Result
    let panel: Panel
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

    /// This panel's curves for this ear, in legend order.
    var curves: [HRTFAnalysis.Curve] {
        let mine = result.curves(ear: ear)
        return panel.labels.compactMap { label in mine.first(where: { $0.label == label }) }
    }

    var body: some View {
        let cs = curves
        VStack(alignment: .leading, spacing: 6) {
            Text(ear == 0 ? "Left ear" : "Right ear").font(.subheadline.weight(.semibold))
            chart(cs)
            readout(cs)
        }
    }

    func chart(_ curves: [HRTFAnalysis.Curve]) -> some View {
        let sel = panel.selection(hover)
        // draw the highlighted curve last so it sits on top
        let ordered = curves.filter { $0.label != sel } + curves.filter { $0.label == sel }
        return Chart {
            ForEach(ordered) { c in
                ForEach(c.points) { p in
                    LineMark(x: .value("Frequency", p.frequency),
                             y: .value("Level", p.level),
                             series: .value("Curve", c.label))
                        .foregroundStyle(panel.color(c.label, scheme, selected: sel))
                        .lineStyle(StrokeStyle(lineWidth: c.label == sel ? 3 : 2, dash: c.isDiffuse ? [6, 4] : []))
                }
            }
            if let f = hover.frequency {
                RuleMark(x: .value("Frequency", f))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
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
                    .onTapGesture { location in
                        let origin = geo[proxy.plotAreaFrame].origin
                        select(at: CGPoint(x: location.x - origin.x, y: location.y - origin.y), proxy: proxy, curves: curves)
                    }
            }
        }
        .frame(minHeight: 170)
    }

    /// Click: highlight the curve nearest the pointer (within 10 pt); clicking it again or empty space shows all.
    func select(at point: CGPoint, proxy: ChartProxy, curves: [HRTFAnalysis.Curve]) {
        guard let f: Double = proxy.value(atX: point.x), f >= HRTFAnalysis.fMin, f <= HRTFAnalysis.fMax else {
            hover.selected = nil
            return
        }
        var bestLabel: String? = nil
        var bestDistance = CGFloat.infinity
        for c in curves {
            guard let y = proxy.position(forY: level(c, at: f)) else { continue }
            let d = abs(y - point.y)
            if d < bestDistance { bestDistance = d; bestLabel = c.label }
        }
        if let label = bestLabel, bestDistance <= 10 {
            hover.toggle(label)
        } else {
            hover.selected = nil
        }
    }

    func readout(_ curves: [HRTFAnalysis.Curve]) -> some View {
        let sel = panel.selection(hover)
        return HStack(spacing: 14) {
            if let f = hover.frequency {
                Text(formatHz(f) + " Hz").font(.caption.monospacedDigit()).foregroundColor(.primary)
                ForEach(curves) { c in
                    HStack(spacing: 4) {
                        Circle().fill(panel.color(c.label, scheme, selected: sel)).frame(width: 8, height: 8)
                        Text("\(c.label) " + String(format: "%+.1f dB", level(c, at: f)))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(sel == nil || sel == c.label ? .primary : .secondary)
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

/// Clickable legend for one panel: click an entry to highlight it, click again to show all.
struct LegendRow: View {
    let panel: Panel
    let interactive: Bool
    @ObservedObject var hover: ChartHover
    @Environment(\.colorScheme) var scheme

    var body: some View {
        let sel = panel.selection(hover)
        HStack(spacing: 18) {
            ForEach(panel.labels, id: \.self) { label in
                if interactive {
                    Button { hover.toggle(label) } label: { entry(label, selected: sel) }
                        .buttonStyle(.plain)
                        .help(sel == label ? "Click to show all curves" : "Click to highlight \(label)")
                } else {
                    entry(label, selected: sel)
                }
            }
            if interactive && sel != nil {
                Button("Show all") { hover.selected = nil }.buttonStyle(.link)
            }
        }
    }

    func entry(_ label: String, selected sel: String?) -> some View {
        let isDiffuse = label == HRTFAnalysis.diffuseLabel
        return HStack(spacing: 6) {
            Path { p in p.move(to: CGPoint(x: 0, y: 5)); p.addLine(to: CGPoint(x: 22, y: 5)) }
                .stroke(panel.color(label, scheme, selected: sel),
                        style: StrokeStyle(lineWidth: sel == label ? 3 : 2, dash: isDiffuse ? [6, 4] : []))
                .frame(width: 22, height: 10)
            Text(label).font(.callout)
                .fontWeight(sel == label ? .semibold : .regular)
                .foregroundColor(sel == nil || sel == label ? .primary : .secondary)
        }
        .contentShape(Rectangle())
    }
}

/// Both ears side by side, faceted into horizontal-plane and median-plane panels.
public struct HRTFPlotView: View {
    let result: HRTFAnalysis.Result
    let interactive: Bool
    @ObservedObject var hover: ChartHover

    /// Height that gives each panel comfortable room (used for scrolling in the app and for PNG export).
    public static func preferredHeight(for result: HRTFAnalysis.Result, perPanel: CGFloat = 330) -> CGFloat {
        CGFloat(Panel.panels(for: result).count) * perPanel + 140
    }

    public init(result: HRTFAnalysis.Result, hover: ChartHover, interactive: Bool = true) {
        self.result = result
        self.hover = hover
        self.interactive = interactive
    }

    var subtitle: String {
        var parts: [String] = []
        let s = result.options.smoothing
        parts.append(s > 0 ? "1/\(Int(s))-octave smoothing" : "no smoothing")
        parts.append("as stored (diffuse-field equalized)")
        if result.options.mirror { parts.append("mirrored ear mapping") }
        return parts.joined(separator: " · ")
    }

    var directionNote: String {
        let left = result.curves(ear: 0)
        let used = left.compactMap { c -> String? in
            guard let m = c.matched else { return nil }
            return "\(c.label): az \(Int(m.azimuth.rounded()))°, el \(Int(m.elevation.rounded()))°"
        }
        return "Measurement used (SOFA convention, azimuth counter-clockwise, 90° = left, 270° = right) - " + used.joined(separator: "; ")
    }

    public var body: some View {
        let domain = yDomain(result)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HRTF magnitude - \(result.sourceFile)").font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundColor(.secondary)
            }
            ForEach(Panel.panels(for: result), id: \.labels) { panel in
                VStack(alignment: .leading, spacing: 6) {
                    Text(panel.title).font(.headline)
                    LegendRow(panel: panel, interactive: interactive, hover: hover)
                    HStack(alignment: .top, spacing: 24) {
                        EarChart(result: result, panel: panel, ear: 0, domain: domain, hover: hover)
                        EarChart(result: result, panel: panel, ear: 1, domain: domain, hover: hover)
                    }
                }
            }
            Text(directionNote).font(.caption).foregroundColor(.secondary)
            if interactive {
                Text("Click a line or a legend entry to highlight it; click it again, or click empty space, to show all.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

public enum HRTFPlotExport {
    public enum ExportError: Error { case renderFailed }

    /// Renders the plot (light appearance, nothing highlighted) to a PNG file.
    @MainActor
    public static func writePNG(_ result: HRTFAnalysis.Result, to url: URL, width: CGFloat = 1400, height: CGFloat? = nil) throws {
        let h = height ?? HRTFPlotView.preferredHeight(for: result, perPanel: 490)
        let view = HRTFPlotView(result: result, hover: ChartHover(), interactive: false)
            .padding(24)
            .frame(width: width, height: h)
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
