import Foundation
import HRTFKit
import HRTFViz

let usage = """
usage: hrtf2sofa [options] <file.dat>...
  -o, --outdir DIR     output directory (default: next to each input)
  --keep-delays        store ITD in Data.Delay instead of baking it into Data.IR
  --mirror             mirrored ear/azimuth interpretation
  --distance M         source distance in metres (default 1.0)
  --listener NAME      ListenerShortName (default AppleHRTF)
  --date "Y-m-d H:M:S" fixed creation date (reproducible output)
  --plot DIR           also write HRTF plots (PNG), curves (CSV) and diffuse-field
                       measurement files (<name>-DFHRTF-L/R/LR-avg.txt, 1/48 oct) to DIR,
                       as stored, with Apple's CTF added back, and at the eardrum
                       (population-average ear-canal correction; see *-assumptions.md)
  --smoothing N        1/N-octave smoothing for plots (default 12, 0 = none)
"""

@MainActor
func runCLI() -> Int32 {
    var opts = ConversionOptions()
    var outdir: URL? = nil
    var plotDir: URL? = nil
    var smoothing = 12.0
    var inputs: [URL] = []
    var args = Array(CommandLine.arguments.dropFirst())

    func fail(_ s: String) -> Never {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
        exit(2)
    }
    func next() -> String {
        guard !args.isEmpty else { fail(usage) }
        return args.removeFirst()
    }

    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "-o", "--outdir": outdir = URL(fileURLWithPath: next(), isDirectory: true)
        case "--keep-delays": opts.bakeDelays = false
        case "--mirror": opts.mirror = true
        case "--distance":
            guard let d = Double(next()) else { fail("bad --distance") }
            opts.distance = d
        case "--listener": opts.listenerName = next()
        case "--date": opts.date = next()
        case "--plot": plotDir = URL(fileURLWithPath: next(), isDirectory: true)
        case "--smoothing":
            guard let s = Double(next()) else { fail("bad --smoothing") }
            smoothing = s
        case "-h", "--help": print(usage); exit(0)
        default:
            if a.hasPrefix("-") { fail("unknown option \(a)\n" + usage) }
            inputs.append(URL(fileURLWithPath: a))
        }
    }
    if inputs.isEmpty { fail(usage) }

    var failures: Int32 = 0
    for input in inputs {
        do {
            let dir = outdir ?? input.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let out = try SOFABuilder.convert(input: input, outputDirectory: dir, options: opts)
            print("\(input.path) -> \(out.path)")
            if let pd = plotDir {
                try FileManager.default.createDirectory(at: pd, withIntermediateDirectories: true)
                let h = try AppleHRTF.load(url: input)
                let base = input.deletingPathExtension().lastPathComponent
                let variants: [(Bool, HRTFAnalysis.ReferencePoint, String)] = [
                    (false, .canalEntrance, "-hrtf"), (true, .canalEntrance, "-hrtf-ctf"), (true, .eardrum, "-hrtf-eardrum"),
                ]
                for (addCTF, reference, suffix) in variants {
                    var ao = HRTFAnalysis.Options()
                    ao.smoothing = smoothing
                    ao.mirror = opts.mirror
                    ao.addCTF = addCTF
                    ao.reference = reference
                    let r = HRTFAnalysis.analyze(h, options: ao)
                    let stem = base + suffix
                    try r.csv().write(to: pd.appendingPathComponent(stem + ".csv"), atomically: true, encoding: .utf8)
                    try HRTFPlotExport.writePNG(r, to: pd.appendingPathComponent(stem + ".png"))
                    print("  plot -> \(pd.appendingPathComponent(stem + ".png").path)")
                    let dfStem = HRTFAnalysis.diffuseFieldStem(base, options: ao)
                    for f in HRTFAnalysis.diffuseFieldMeasurements(h, options: ao) {
                        try f.text.write(to: pd.appendingPathComponent("\(dfStem)-\(f.suffix).txt"), atomically: true, encoding: .utf8)
                    }
                    try HRTFAnalysis.assumptions(ao).write(to: pd.appendingPathComponent("\(dfStem)-assumptions.md"), atomically: true, encoding: .utf8)
                }
            }
        } catch {
            failures += 1
            FileHandle.standardError.write("\(input.path): \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }
    return failures == 0 ? 0 : 1
}

exit(await runCLI())
