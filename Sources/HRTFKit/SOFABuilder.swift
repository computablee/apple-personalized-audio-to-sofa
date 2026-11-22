import Foundation

public struct ConversionOptions: Sendable {
    /// Bake the per-ear ITD into Data.IR (recommended; works with every renderer).
    /// If false, Data.IR keeps Apple's 128-tap minimum-phase filters and the ITD goes in Data.Delay (M x R).
    public var bakeDelays = true
    /// Alternative interpretation: Apple azimuth counter-clockwise and channel 1 = left ear.
    /// Both interpretations localize identically; they differ only by mirroring your left/right ear.
    public var mirror = false
    public var distance = 1.0
    public var listenerName = "AppleHRTF"
    /// Fixed DateCreated/DateModified ("yyyy-MM-dd HH:mm:ss"); nil = now.
    public var date: String? = nil

    public init() {}
}

public enum SOFABuilder {
    public static let version = "1.0"

    public static func build(_ h: AppleHRTF, options o: ConversionOptions) -> SOFAWriter {
        let M = h.numMeasurements, C = h.numChannels
        let (left, right) = o.mirror ? (1, 0) : (0, 1)

        var src = [Double](repeating: 0, count: M * 3)
        for m in 0..<M {
            let elev = h.coords[2 * m], azA = h.coords[2 * m + 1]
            var az = o.mirror ? azA : 360.0 - azA
            az = az.truncatingRemainder(dividingBy: 360.0)
            if az < 0 { az += 360.0 }
            src[3 * m] = az; src[3 * m + 1] = elev; src[3 * m + 2] = o.distance
        }

        let ir: [Double]
        let N: Int
        var delay: [Double]
        let delayDims: [String]
        if o.bakeDelays {
            let baked = DSP.bakeDelays(h)
            N = baked.length
            ir = reorder(baked.ir, M: M, C: C, N: N, left: left, right: right)
            delay = [0, 0]
            delayDims = ["I", "R"]
        } else {
            N = h.filterLength
            ir = reorder(h.ir, M: M, C: C, N: N, left: left, right: right)
            delay = [Double](repeating: 0, count: M * 2)
            for m in 0..<M {
                delay[2 * m] = h.delay[m * C + left]
                delay[2 * m + 1] = h.delay[m * C + right]
            }
            delayDims = ["M", "R"]
        }

        let now: String = o.date ?? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f.string(from: Date())
        }()

        let w = SOFAWriter()
        for (n, v) in [("I", 1), ("C", 3), ("R", 2), ("E", 1), ("N", N), ("M", M)] { w.addDim(n, v) }
        let g: [(String, String)] = [
            ("Conventions", "SOFA"), ("Version", "2.1"),
            ("SOFAConventions", "SimpleFreeFieldHRIR"), ("SOFAConventionsVersion", "1.0"),
            ("APIName", "HRTFToSOFA"), ("APIVersion", version),
            ("ApplicationName", "HRTFToSOFA"), ("ApplicationVersion", version),
            ("AuthorContact", "unknown"), ("Organization", "unknown"),
            ("License", "No license provided, ask the author for permission"),
            ("DataType", "FIR"), ("RoomType", "free field"),
            ("DateCreated", now), ("DateModified", now),
            ("Title", "Personalized HRTF (\(o.listenerName))"),
            ("DatabaseName", "Apple Personalized Spatial Audio"),
            ("ListenerShortName", o.listenerName), ("Origin", "Apple Personalized Spatial Audio"),
            ("References", "none"), ("History", "Converted by HRTFToSOFA"),
            ("Comment", "Converted from an Apple personalized spatial audio profile"),
            ("AppleSourceFile", h.sourceFile), ("AppleHRIRBlob", h.blobKey),
            ("AppleDevice", h.device.isEmpty ? "unknown" : h.device),
            ("AppleExportDate", h.exportDate.isEmpty ? "unknown" : h.exportDate),
            ("ITDHandling", o.bakeDelays ? "baked into Data.IR" : "in Data.Delay; Data.IR is minimum-phase"),
            ("EarMapping", o.mirror ? "mirrored" : "standard"),
        ]
        for (k, v) in g { w.addGlobalAttr(k, v) }

        let cart = [("Type", "cartesian"), ("Units", "metre")]
        w.addVar("ListenerPosition", ["I", "C"], [0, 0, 0], cart)
        w.addVar("ReceiverPosition", ["R", "C", "I"], [0, 0.09, 0, 0, -0.09, 0], cart)
        w.addVar("SourcePosition", ["M", "C"], src, [("Type", "spherical"), ("Units", "degree, degree, metre")])
        w.addVar("EmitterPosition", ["E", "C", "I"], [0, 0, 0], cart)
        w.addVar("ListenerUp", ["I", "C"], [0, 0, 1])
        w.addVar("ListenerView", ["I", "C"], [1, 0, 0], cart)
        w.addVar("Data.IR", ["M", "R", "N"], ir)
        w.addVar("Data.SamplingRate", ["I"], [h.sampleRate], [("Units", "hertz")])
        w.addVar("Data.Delay", delayDims, delay)
        return w
    }

    /// Input index (m*C + c)*N + n  ->  output (m*2 + r)*N + n with r0 = left, r1 = right.
    static func reorder(_ x: [Double], M: Int, C: Int, N: Int, left: Int, right: Int) -> [Double] {
        var out = [Double](repeating: 0, count: M * 2 * N)
        for m in 0..<M {
            for (r, c) in [left, right].enumerated() {
                let s = (m * C + c) * N, d = (m * 2 + r) * N
                for n in 0..<N { out[d + n] = x[s + n] }
            }
        }
        return out
    }

    /// Convenience: convert one .dat file, returns the written URL.
    @discardableResult
    public static func convert(input: URL, outputDirectory: URL, options: ConversionOptions) throws -> URL {
        let h = try AppleHRTF.load(url: input)
        let w = build(h, options: options)
        let out = outputDirectory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".sofa")
        try w.write(to: out)
        return out
    }
}
