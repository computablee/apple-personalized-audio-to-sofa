import AppKit
import HRTFKit
import HRTFViz
import SwiftUI
import UniformTypeIdentifiers

@main
struct HRTFToSOFAApp: App {
    init() {
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("HRTF → SOFA") {
            RootView()
                .frame(minWidth: 1260, minHeight: 760)
        }
        .windowResizability(.contentMinSize)
    }
}

struct Job: Identifiable {
    enum Status: Equatable { case pending, working, done(URL), failed(String) }
    let id = UUID()
    let input: URL
    var status: Status = .pending
}

@MainActor
final class Model: ObservableObject {
    @Published var jobs: [Job] = []
    @Published var bakeDelays = true
    @Published var mirror = false
    @Published var distance = 1.0
    @Published var listenerName = "AppleHRTF"
    @Published var outputDirectory: URL? = nil      // nil = next to each input
    @Published var isRunning = false
    @Published var dropTargeted = false

    func add(_ urls: [URL]) {
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
                add(items.filter { $0.pathExtension.lowercased() == "dat" })
            } else if u.pathExtension.lowercased() == "dat", !jobs.contains(where: { $0.input == u }) {
                jobs.append(Job(input: u))
            }
        }
    }

    func chooseInputs() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [UTType(filenameExtension: "dat") ?? .data]
        p.message = "Choose Apple personalized HRTF .dat files (or a folder containing them)"
        if p.runModal() == .OK { add(p.urls) }
    }

    func chooseOutput() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = "Use Folder"
        if p.runModal() == .OK { outputDirectory = p.url }
    }

    func convertAll() {
        var opts = ConversionOptions()
        opts.bakeDelays = bakeDelays
        opts.mirror = mirror
        opts.distance = distance
        opts.listenerName = listenerName.trimmingCharacters(in: .whitespaces).isEmpty ? "AppleHRTF" : listenerName
        let outDir = outputDirectory
        isRunning = true
        let pending = jobs.indices.filter { jobs[$0].status != .working }
        for i in pending { jobs[i].status = .pending }
        Task {
            for i in pending {
                jobs[i].status = .working
                let input = jobs[i].input
                let result = await Task.detached(priority: .userInitiated) { () -> Job.Status in
                    do {
                        let dir = outDir ?? input.deletingLastPathComponent()
                        let url = try SOFABuilder.convert(input: input, outputDirectory: dir, options: opts)
                        return .done(url)
                    } catch {
                        return .failed(error.localizedDescription)
                    }
                }.value
                jobs[i].status = result
            }
            isRunning = false
        }
    }

    var finishedURLs: [URL] {
        jobs.compactMap { if case .done(let u) = $0.status { return u } else { return nil } }
    }
}

struct ContentView: View {
    @StateObject private var model = Model()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Convert Apple Personalized Spatial Audio profiles to SOFA (SimpleFreeFieldHRIR)")
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundColor(model.dropTargeted ? .accentColor : .secondary)
                if model.jobs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "ear").font(.system(size: 32)).foregroundColor(.secondary)
                        Text("Drop .dat files or a folder here").foregroundColor(.secondary)
                        Button("Choose Files…") { model.chooseInputs() }
                    }
                } else {
                    List {
                        ForEach(model.jobs) { job in
                            HStack {
                                statusIcon(job.status)
                                VStack(alignment: .leading) {
                                    Text(job.input.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    if case .failed(let msg) = job.status {
                                        Text(msg).font(.caption).foregroundColor(.red)
                                    } else if case .done(let url) = job.status {
                                        Text(url.path).font(.caption).foregroundColor(.secondary)
                                            .lineLimit(1).truncationMode(.head)
                                    }
                                }
                            }
                        }
                    }
                    .padding(4)
                }
            }
            .frame(minHeight: 180)
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls)
                return true
            } isTargeted: { model.dropTargeted = $0 }

            GroupBox("Options") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Bake ITD into impulse responses (recommended for BRIR work)", isOn: $model.bakeDelays)
                    Toggle("Mirror ear / azimuth interpretation", isOn: $model.mirror)
                        .help("Apple's data does not say which channel is which ear. Default assumes channel 1 = left and clockwise azimuth. Both choices localize correctly; mirroring swaps which of your real ears' responses is used for each side.")
                    HStack {
                        Text("Listener name")
                        TextField("AppleHRTF", text: $model.listenerName).frame(width: 180)
                        Spacer().frame(width: 24)
                        Text("Source distance")
                        TextField("", value: $model.distance, format: .number).frame(width: 50)
                        Text("m")
                    }
                    HStack {
                        Text("Output:")
                        Text(model.outputDirectory?.path ?? "same folder as each input")
                            .foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button("Choose…") { model.chooseOutput() }
                        if model.outputDirectory != nil { Button("Reset") { model.outputDirectory = nil } }
                    }
                }
                .padding(6)
            }

            HStack {
                Button("Add Files…") { model.chooseInputs() }
                Button("Clear") { model.jobs.removeAll() }.disabled(model.isRunning || model.jobs.isEmpty)
                Spacer()
                if !model.finishedURLs.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(model.finishedURLs) }
                }
                Button(model.isRunning ? "Converting…" : "Convert") { model.convertAll() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isRunning || model.jobs.isEmpty)
            }
        }
        .padding(18)
    }

    @ViewBuilder func statusIcon(_ s: Job.Status) -> some View {
        switch s {
        case .pending: Image(systemName: "circle").foregroundColor(.secondary)
        case .working: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        }
    }
}

// MARK: - Tabs

struct RootView: View {
    var body: some View {
        TabView {
            ContentView().tabItem { Text("Convert") }
            VisualizeView().tabItem { Text("Visualize") }
        }
        .padding(8)
    }
}

// MARK: - Visualizer

@MainActor
final class VizModel: ObservableObject {
    @Published var file: URL? = nil
    @Published var smoothing: Double = 12 { didSet { recompute() } }
    @Published var mirror = false { didSet { recompute() } }
    @Published var addCTF = false {
        didSet {
            if !addCTF && reference == .eardrum { reference = .canalEntrance }
            recompute()
        }
    }
    /// Eardrum reference implies the CTF is added back (enforced here and in HRTFKit).
    @Published var reference: HRTFAnalysis.ReferencePoint = .canalEntrance {
        didSet {
            if reference == .eardrum && !addCTF { addCTF = true }
            recompute()
        }
    }
    @Published var showAssumptions = false
    @Published var customEnabled = false { didSet { applyCustom() } }
    /// SOFA convention: 0° front, 90° left, 180° behind, 270° right (negative values wrap, e.g. −90° = right).
    @Published var customAzimuth: Double = 135 { didSet { if customEnabled { applyCustom() } } }
    @Published var customElevation: Double = 0 { didSet { if customEnabled { applyCustom() } } }
    /// Result without the custom curve (recomputed only when settings change).
    private var baseResult: HRTFAnalysis.Result? = nil

    var customDirection: HRTFAnalysis.Direction {
        HRTFAnalysis.Direction(azimuth: customAzimuth, elevation: customElevation)
    }

    var customMatched: (azimuth: Double, elevation: Double)? {
        result?.curves.first(where: { $0.label == HRTFAnalysis.customLabel })?.matched
    }

    /// Adds/updates/removes the custom curves on top of the base result: two FFTs, fast enough for live dragging.
    func applyCustom() {
        guard let base = baseResult, let h = hrtf else { return }
        if customEnabled {
            var o = base.options
            o.custom = nil
            let curves = HRTFAnalysis.customCurves(h, options: o, direction: customDirection)
            result = base.replacingCustom(curves, direction: customDirection)
        } else {
            result = base.replacingCustom([], direction: nil)
        }
    }

    var options: HRTFAnalysis.Options {
        var o = HRTFAnalysis.Options()
        o.smoothing = smoothing
        o.mirror = mirror
        o.addCTF = addCTF
        o.reference = reference
        if customEnabled { o.custom = HRTFAnalysis.Direction(azimuth: customAzimuth, elevation: customElevation) }
        return o
    }
    @Published var result: HRTFAnalysis.Result? = nil
    @Published var busy = false
    @Published var error: String? = nil
    @Published var dropTargeted = false
    let hover = ChartHover()
    private var hrtf: AppleHRTF? = nil
    private var generation = 0

    func choose() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [UTType(filenameExtension: "dat") ?? .data]
        p.message = "Choose an Apple personalized HRTF .dat file"
        if p.runModal() == .OK, let u = p.url { open(u) }
    }

    func open(_ url: URL) {
        file = url
        error = nil
        result = nil
        hrtf = nil
        baseResult = nil
        busy = true
        generation += 1
        let gen = generation
        Task {
            do {
                let h = try await Task.detached(priority: .userInitiated) { try AppleHRTF.load(url: url) }.value
                guard gen == generation else { return }
                hrtf = h
                recompute()
            } catch {
                guard gen == generation else { return }
                self.error = error.localizedDescription
                busy = false
            }
        }
    }

    func recompute() {
        guard let h = hrtf else { return }
        var o = options
        o.custom = nil                    // the custom curve is added by applyCustom()
        generation += 1
        let gen = generation
        busy = true
        Task {
            let r = await Task.detached(priority: .userInitiated) { HRTFAnalysis.analyze(h, options: o) }.value
            if gen == generation {
                baseResult = r
                busy = false
                applyCustom()
            }
        }
    }

    func exportPNG() {
        guard let r = result else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.nameFieldStringValue = (file?.deletingPathExtension().lastPathComponent ?? "hrtf") + "-hrtf.png"
        if p.runModal() == .OK, let u = p.url {
            do { try HRTFPlotExport.writePNG(r, to: u) } catch { self.error = "PNG export failed: \(error.localizedDescription)" }
        }
    }

    /// Writes the diffuse-field curve as EQ-software measurement files (<stem>-L.txt, -R.txt, -LR-avg.txt).
    func exportDiffuseField() {
        guard let h = hrtf else { return }
        let o = options
        let base = file?.deletingPathExtension().lastPathComponent ?? "hrtf"
        let p = NSSavePanel()
        p.nameFieldStringValue = HRTFAnalysis.diffuseFieldStem(base, options: o)
        p.message = reference == .eardrum
            ? "Saves the EARDRUM diffuse-field HRTF (Apple data + population-average ear canal) as <name>-L.txt, -R.txt, -LR-avg.txt and <name>-assumptions.md"
            : addCTF
            ? "Saves the diffuse-field HRTF at the ear-canal entrance (CTF added back) as <name>-L.txt, -R.txt, -LR-avg.txt and <name>-assumptions.md"
            : "CTF is off: this exports the near-flat diffuse field of the stored (equalized) data. Turn on \"Add back Apple's CTF\" or choose the eardrum reference for the actual diffuse-field HRTF."
        p.prompt = "Export"
        guard p.runModal() == .OK, let u = p.url else { return }
        let dir = u.deletingLastPathComponent()
        var stem = u.lastPathComponent
        if stem.lowercased().hasSuffix(".txt") { stem = String(stem.dropLast(4)) }
        busy = true
        Task {
            let files = await Task.detached(priority: .userInitiated) { HRTFAnalysis.diffuseFieldMeasurements(h, options: o) }.value
            busy = false
            do {
                var written: [URL] = []
                for f in files {
                    let url = dir.appendingPathComponent("\(stem)-\(f.suffix).txt")
                    try f.text.write(to: url, atomically: true, encoding: .utf8)
                    written.append(url)
                }
                let notes = dir.appendingPathComponent("\(stem)-assumptions.md")
                try HRTFAnalysis.assumptions(o).write(to: notes, atomically: true, encoding: .utf8)
                written.append(notes)
                NSWorkspace.shared.activateFileViewerSelecting(written)
            } catch {
                self.error = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func exportCSV() {
        guard let r = result else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.commaSeparatedText]
        p.nameFieldStringValue = (file?.deletingPathExtension().lastPathComponent ?? "hrtf") + "-hrtf.csv"
        if p.runModal() == .OK, let u = p.url {
            do { try r.csv().write(to: u, atomically: true, encoding: .utf8) } catch { self.error = "CSV export failed: \(error.localizedDescription)" }
        }
    }
}

struct VisualizeView: View {
    @StateObject private var model = VizModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button("Open .dat…") { model.choose() }
                Text(model.file?.lastPathComponent ?? "No file").foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Export PNG…") { model.exportPNG() }.disabled(model.result == nil)
                Button("Export CSV…") { model.exportCSV() }.disabled(model.result == nil)
                Button("Export DF HRTF (.txt)…") { model.exportDiffuseField() }
                    .disabled(model.result == nil)
                    .help("Diffuse-field curve as frequency/dB measurement files (1/48 octave, 20 Hz-20 kHz) for EQ software: left, right and both-ear average. Uses the current smoothing, mirror and CTF settings.")
            }
            HStack(spacing: 18) {
                Picker("Smoothing", selection: $model.smoothing) {
                    Text("None").tag(0.0)
                    Text("1/24 octave").tag(24.0)
                    Text("1/12 octave").tag(12.0)
                    Text("1/6 octave").tag(6.0)
                    Text("1/3 octave").tag(3.0)
                }
                .frame(width: 220)
                Toggle("Add back Apple's CTF (undo diffuse-field EQ)", isOn: $model.addCTF)
                    .help("Apple stores a per-ear 'CTF' alongside the filters. It looks like the diffuse-field response that was removed from this data; adding it back shows the un-equalized HRTF. This is an interpretation, not documented by Apple.")
                Toggle("Mirror ear mapping", isOn: $model.mirror)
                Spacer()
            }
            HStack(spacing: 12) {
                Picker("Reference point", selection: $model.reference) {
                    ForEach(HRTFAnalysis.ReferencePoint.allCases, id: \.self) { r in
                        Text(r.label).tag(r)
                    }
                }
                .frame(width: 470)
                .help("Eardrum adds a published population-average ear-canal correction (Hammershøi & Møller 2008, Table II) so curves are comparable with eardrum-referenced rigs such as 711 couplers or a B&K 5128. It is not your own ear canal.")
                Button("Method & assumptions…") { model.showAssumptions = true }
                    .popover(isPresented: $model.showAssumptions, arrowEdge: .bottom) {
                        ScrollView {
                            Text(HRTFAnalysis.assumptions(model.options))
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                        .frame(width: 560, height: 460)
                    }
                Spacer()
            }
            HStack(spacing: 10) {
                Toggle("Custom direction", isOn: $model.customEnabled)
                Text("Azimuth")
                TextField("", value: $model.customAzimuth, format: .number).frame(width: 60)
                Text("°  Elevation")
                TextField("", value: $model.customElevation, format: .number).frame(width: 60)
                Text("°")
                Text("Drag on the heads at the left, or type: azimuth 0° front, 90° left, 180° behind, 270° (or −90°) right; elevation −90° below to +90° above. Uses the nearest measured direction.")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .disabled(model.file == nil)
            if model.reference == .eardrum {
                Text("Eardrum curves = Apple's data (assumed blocked ear-canal entrance) + a POPULATION-AVERAGE ear canal (Hammershøi & Møller 2008, Table II). Your own ear canal is not known, and the correction is rough above about 8 kHz. See Method & assumptions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundColor(model.dropTargeted ? .accentColor : .secondary.opacity(model.result == nil ? 1 : 0))
                if let r = model.result {
                    HStack(alignment: .top, spacing: 8) {
                        DirectionPicker(azimuth: $model.customAzimuth, elevation: $model.customElevation,
                                        matched: model.customEnabled ? model.customMatched : nil,
                                        onBegin: { if !model.customEnabled { model.customEnabled = true } })
                            .frame(width: 200)
                            .padding(12)
                            .opacity(model.customEnabled ? 1 : 0.6)
                        ScrollView {
                            HRTFPlotView(result: r, hover: model.hover)
                                .padding(12)
                                .frame(height: HRTFPlotView.preferredHeight(for: r))
                        }
                    }
                } else if model.busy {
                    ProgressView("Analyzing…")
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 32)).foregroundColor(.secondary)
                        Text("Drop a .dat file here to plot its HRTFs").foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dropDestination(for: URL.self) { urls, _ in
                if let u = urls.first(where: { $0.pathExtension.lowercased() == "dat" }) { model.open(u) }
                return true
            } isTargeted: { model.dropTargeted = $0 }
            if let e = model.error { Text(e).foregroundColor(.red) }
        }
        .padding(18)
    }
}
