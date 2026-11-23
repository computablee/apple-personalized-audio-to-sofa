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
  --plot DIR           also write HRTF plots (<name>-hrtf.png) and curves (<name>-hrtf.csv) to DIR
  --smoothing N        1/N-octave smoothing for plots (default 12, 0 = none)
  --custom AZ,EL       add a custom-direction curve to the plots (SOFA convention:
                       azimuth 0 = front, 90 = left, 270 = right; elevation -90..90)
"""

@MainActor
func runCLI() -> Int32 {
    var opts = ConversionOptions()
    var outdir: URL? = nil
    var plotDir: URL? = nil
    var smoothing = 12.0
    var custom: HRTFAnalysis.Direction? = nil
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
        case "--custom":
            let parts = next().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2 else { fail("bad --custom (expected AZ,EL)") }
            custom = HRTFAnalysis.Direction(azimuth: parts[0], elevation: parts[1])
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
                var ao = HRTFAnalysis.Options()
                ao.smoothing = smoothing
                ao.mirror = opts.mirror
                ao.custom = custom
                let r = HRTFAnalysis.analyze(h, options: ao)
                let stem = base + "-hrtf"
                try r.csv().write(to: pd.appendingPathComponent(stem + ".csv"), atomically: true, encoding: .utf8)
                try HRTFPlotExport.writePNG(r, to: pd.appendingPathComponent(stem + ".png"))
                print("  plot -> \(pd.appendingPathComponent(stem + ".png").path)")
            }
        } catch {
            failures += 1
            FileHandle.standardError.write("\(input.path): \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }
    return failures == 0 ? 0 : 1
}

exit(await runCLI())
