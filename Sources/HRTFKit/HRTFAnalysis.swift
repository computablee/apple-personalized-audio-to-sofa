import Foundation

/// Magnitude responses for a few fixed directions plus the diffuse-field average.
/// Mirrors reference/analyze_hrtf.py.
public enum HRTFAnalysis {
    public static let fftSize = 2048
    public static let displayPoints = 320
    public static let fMin = 20.0
    public static let fMax = 23900.0

    /// (label, SOFA azimuth (counter-clockwise, 90 = left), elevation)
    public static let directions: [(String, Double, Double)] = [
        ("Front", 0, 0), ("45° left", 45, 0), ("45° down", 0, -45), ("45° up", 0, 45),
    ]
    public static let diffuseLabel = "Diffuse field"

    public struct Options: Sendable {
        /// Fractional-octave smoothing denominator (e.g. 12 = 1/12 octave); 0 = none.
        public var smoothing: Double = 12
        public var mirror = false
        /// Add Apple's stored CTF back onto every curve (undoes the diffuse-field EQ, as interpreted).
        public var addCTF = false
        /// Measurement point. `.eardrum` implies the CTF is added back (it is meaningless on equalized data).
        public var reference: ReferencePoint = .canalEntrance
        /// CTF actually applied (always on for the eardrum reference).
        public var effectiveAddCTF: Bool { addCTF || reference == .eardrum }
        public init() {}
    }

    public struct Point: Identifiable, Sendable {
        public let id: Int
        public let frequency: Double
        public let level: Double
    }

    public struct Curve: Identifiable, Sendable {
        public var id: String { "\(ear)-\(label)" }
        public let label: String
        public let ear: Int                 // 0 = left, 1 = right
        public let isDiffuse: Bool
        /// Coordinates of the measurement actually used (SOFA convention), nil for diffuse field.
        public let matched: (azimuth: Double, elevation: Double)?
        public let points: [Point]
    }

    public struct Result: Sendable {
        public let sourceFile: String
        public let curves: [Curve]
        public let hasCTF: Bool
        public let options: Options
        public func curves(ear: Int) -> [Curve] { curves.filter { $0.ear == ear } }

        public func csv() -> String {
            var header = ["frequency_hz"]
            for c in curves { header.append("\(c.ear == 0 ? "Left" : "Right") \(c.label)") }
            var lines = [header.joined(separator: ",")]
            let n = curves.first?.points.count ?? 0
            for i in 0..<n {
                var row = [String(format: "%.3f", curves[0].points[i].frequency)]
                for c in curves { row.append(String(format: "%.4f", c.points[i].level)) }
                lines.append(row.joined(separator: ","))
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    // MARK: - FFT (iterative radix-2, power spectrum of a zero-padded real signal)

    struct FFT {
        let n: Int
        let cosT: [Double]
        let sinT: [Double]
        let rev: [Int]
        init(_ n: Int) {
            self.n = n
            var c = [Double](repeating: 0, count: n / 2), s = [Double](repeating: 0, count: n / 2)
            for k in 0..<(n / 2) {
                let a = -2.0 * Double.pi * Double(k) / Double(n)
                c[k] = cos(a); s[k] = sin(a)
            }
            cosT = c; sinT = s
            var bits = 0
            while (1 << bits) < n { bits += 1 }
            var r = [Int](repeating: 0, count: n)
            for i in 0..<n {
                var x = i, y = 0
                for _ in 0..<bits { y = (y << 1) | (x & 1); x >>= 1 }
                r[i] = y
            }
            rev = r
        }

        /// |X[k]|^2 for k = 0 ... n/2 of x (zero-padded to n).
        func power(_ x: ArraySlice<Double>) -> [Double] {
            var re = [Double](repeating: 0, count: n), im = [Double](repeating: 0, count: n)
            var j = 0
            for v in x { re[rev[j]] = v; j += 1 }
            var size = 2
            while size <= n {
                let half = size / 2, step = n / size
                var start = 0
                while start < n {
                    for k in 0..<half {
                        let wr = cosT[k * step], wi = sinT[k * step]
                        let a = start + k, b = a + half
                        let tr = re[b] * wr - im[b] * wi
                        let ti = re[b] * wi + im[b] * wr
                        re[b] = re[a] - tr; im[b] = im[a] - ti
                        re[a] += tr; im[a] += ti
                    }
                    start += size
                }
                size <<= 1
            }
            var p = [Double](repeating: 0, count: n / 2 + 1)
            for k in 0...(n / 2) { p[k] = re[k] * re[k] + im[k] * im[k] }
            return p
        }
    }

    // MARK: - Helpers

    static func solidAngleWeights(_ elev: [Double]) -> [Double] {
        var groups: [Double: Int] = [:]
        for e in elev { groups[e, default: 0] += 1 }
        return elev.map { e in
            let lo = max(-90.0, e - 2.5), hi = min(90.0, e + 2.5)
            return (sin(hi * .pi / 180) - sin(lo * .pi / 180)) / Double(groups[e]!)
        }
    }

    static func smooth(_ p: [Double], fraction: Double, df: Double) -> [Double] {
        if fraction <= 0 { return p }
        let half = p.count - 1
        var cs = [Double](repeating: 0, count: p.count + 1)
        for i in 0..<p.count { cs[i + 1] = cs[i] + p[i] }
        var out = p
        let up = pow(2.0, 1.0 / (2.0 * fraction)), down = pow(2.0, -1.0 / (2.0 * fraction))
        for k in 1...half {
            let f = Double(k) * df
            let klo = max(1, min(Int((f * down / df).rounded(.up)), k))
            let khi = min(half, max(Int((f * up / df).rounded(.down)), k))
            out[k] = (cs[khi + 1] - cs[klo]) / Double(khi - klo + 1)
        }
        return out
    }

    public static func displayGrid() -> [Double] {
        (0..<displayPoints).map { i in fMin * pow(fMax / fMin, Double(i) / Double(displayPoints - 1)) }
    }

    // MARK: - Analysis

    public static func analyze(_ h: AppleHRTF, options o: Options = Options(), grid customGrid: [Double]? = nil) -> Result {
        let M = h.numMeasurements, C = h.numChannels, L = h.filterLength
        let df = h.sampleRate / Double(fftSize)
        let fft = FFT(fftSize)
        let chan = o.mirror ? [1, 0] : [0, 1]

        var ux = [Double](repeating: 0, count: M)
        var uy = ux
        var uz = ux
        var elev = ux
        for m in 0..<M {
            let e = h.coords[2 * m], azA = h.coords[2 * m + 1]
            let az = o.mirror ? azA : 360.0 - azA
            elev[m] = e
            let er = e * .pi / 180, ar = az * .pi / 180
            ux[m] = cos(er) * cos(ar); uy[m] = cos(er) * sin(ar); uz[m] = sin(er)
        }
        let w = solidAngleWeights(elev)
        var wsum = 0.0
        for v in w { wsum += v }

        // nearest measurement for each requested direction
        let picks: [(String, Int)] = directions.map { (name, a, e) in
            let er = e * .pi / 180, ar = a * .pi / 180
            let tx = cos(er) * cos(ar), ty = cos(er) * sin(ar), tz = sin(er)
            var best = 0, bestDot = -2.0
            for m in 0..<M {
                let d = ux[m] * tx + uy[m] * ty + uz[m] * tz
                if d > bestDot { bestDot = d; best = m }
            }
            return (name, best)
        }

        let grid = customGrid ?? displayGrid()
        let nctf = h.ctf.count / 2
        var curves: [Curve] = []
        for ear in 0..<2 {
            let c = chan[ear]
            var specs: [(String, [Double], (Double, Double)?)] = []
            for (name, m) in picks {
                let start = (m * C + c) * L
                let azA = h.coords[2 * m + 1]
                var az = o.mirror ? azA : 360.0 - azA
                az = az.truncatingRemainder(dividingBy: 360); if az < 0 { az += 360 }
                specs.append((name, fft.power(h.ir[start..<(start + L)]), (az, h.coords[2 * m])))
            }
            var df_ = [Double](repeating: 0, count: fftSize / 2 + 1)
            for m in 0..<M {
                let start = (m * C + c) * L
                let p = fft.power(h.ir[start..<(start + L)])
                for k in 0..<p.count { df_[k] += w[m] * p[k] }
            }
            for k in 0..<df_.count { df_[k] /= wsum }
            specs.append((diffuseLabel, df_, nil))

            for (name, p, matched) in specs {
                let s = smooth(p, fraction: o.smoothing, df: df)
                let db = s.map { 10 * log10($0 + 1e-20) }
                var pts: [Point] = []
                pts.reserveCapacity(grid.count)
                for (i, f) in grid.enumerated() {
                    let pos = f / df
                    let i0 = Int(pos.rounded(.down)), t = pos - Double(i0)
                    var v = db[i0] * (1 - t) + db[i0 + 1] * t
                    if o.effectiveAddCTF && nctf > 0 {
                        let step = h.sampleRate / 2 / Double(nctf)
                        let q = f / step
                        let j = min(Int(q.rounded(.down)), nctf - 1), u = q - Double(j)
                        let base = c * nctf
                        if j >= nctf - 1 {
                            v += h.ctf[base + nctf - 1]
                        } else {
                            let c0 = h.ctf[base + j], c1 = h.ctf[base + j + 1]
                            v += c0 * (1 - u) + c1 * u
                        }
                    }
                    if o.reference == .eardrum { v += EarCanalCorrection.dB(at: f) }
                    pts.append(Point(id: i, frequency: f, level: v))
                }
                curves.append(Curve(label: name, ear: ear, isDiffuse: matched == nil,
                                    matched: matched.map { (azimuth: $0.0, elevation: $0.1) }, points: pts))
            }
        }
        return Result(sourceFile: h.sourceFile, curves: curves, hasCTF: nctf > 0, options: o)
    }

    // MARK: - Measurement-file export (frequency<TAB>dB, 1/48 octave from 20 Hz, like REW/Squig .txt)

    /// 480 points, 20 Hz * 2^(i/48), i = 0..<480 (20 Hz ... 20.19 kHz).
    public static func measurementGrid() -> [Double] {
        (0..<480).map { 20.0 * pow(2.0, Double($0) / 48.0) }
    }

    static func numberString(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }

    /// No header, one "frequency\tlevel" per line, LF, no trailing newline.
    public static func measurementText(_ points: [Point]) -> String {
        points.map { numberString($0.frequency) + "\t" + numberString($0.level) }.joined(separator: "\n")
    }

    /// Diffuse-field curves on the measurement grid: (file suffix, text) for left, right and
    /// the power average of both ears. Follows `options` (smoothing, mirror, CTF).
    public static func diffuseFieldMeasurements(_ h: AppleHRTF, options: Options) -> [(suffix: String, text: String)] {
        let r = analyze(h, options: options, grid: measurementGrid())
        guard let l = r.curves.first(where: { $0.ear == 0 && $0.isDiffuse }),
              let rr = r.curves.first(where: { $0.ear == 1 && $0.isDiffuse }) else { return [] }
        var avg: [Point] = []
        for i in 0..<l.points.count {
            let pl = pow(10.0, l.points[i].level / 10), pr = pow(10.0, rr.points[i].level / 10)
            avg.append(Point(id: i, frequency: l.points[i].frequency, level: 10 * log10((pl + pr) / 2)))
        }
        return [("L", measurementText(l.points)), ("R", measurementText(rr.points)), ("LR-avg", measurementText(avg))]
    }

    /// File-name stem for diffuse-field exports, e.g. "<name>-DFHRTF" or "<name>-DF-asstored".
    public static func diffuseFieldStem(_ base: String, options: Options) -> String {
        base + (options.effectiveAddCTF ? "-DFHRTF" : "-DF-asstored")
            + (options.reference == .eardrum ? "-eardrum" : "") + (options.mirror ? "-mirrored" : "")
    }
}
