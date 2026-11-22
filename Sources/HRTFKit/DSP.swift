import Foundation

/// Fractional-delay baking of the per-ear ITD into the impulse responses.
/// Mirrors reference/apple_hrtf_to_sofa.py (bake_delays).
public enum DSP {
    public static let fdHalf = 16          // windowed-sinc half length
    public static let fdBeta = 8.0         // Kaiser beta
    public static let preDelay = 16        // common delay so sinc pre-ringing isn't truncated

    static func besselI0(_ x: Double) -> Double {
        var s = 1.0, t = 1.0, k = 1.0
        while true {
            let q = x / (2 * k)
            t *= q * q
            s += t
            if t < 1e-12 * s { return s }
            k += 1
        }
    }

    /// 2*fdHalf taps for j = -fdHalf+1 ... fdHalf, fractional delay mu in [0, 1).
    static func fracDelayKernel(_ mu: Double) -> [Double] {
        var out = [Double](repeating: 0, count: 2 * fdHalf)
        if mu == 0 {
            out[fdHalf - 1] = 1
            return out
        }
        let i0b = besselI0(fdBeta)
        var idx = 0
        for j in (-fdHalf + 1)...fdHalf {
            let x = Double(j) - mu
            let s = sin(Double.pi * x) / (Double.pi * x)
            let r = x / Double(fdHalf)
            let w = besselI0(fdBeta * (max(0, 1 - r * r)).squareRoot()) / i0b
            out[idx] = s * w
            idx += 1
        }
        var tot = 0.0
        for v in out { tot += v }
        for i in 0..<out.count { out[i] /= tot }
        return out
    }

    /// Returns impulse responses with the ITD applied, length N (power of two), index (m*C + c)*N + n.
    public static func bakeDelays(_ h: AppleHRTF) -> (ir: [Double], length: Int) {
        let M = h.numMeasurements, C = h.numChannels, L = h.filterLength
        var maxd = -Double.infinity
        for d in h.delay { maxd = max(maxd, d) }
        let need = L + preDelay + Int(maxd.rounded(.up)) + fdHalf + 1
        var N = 1
        while N < need { N <<= 1 }
        let K = 2 * fdHalf
        var out = [Double](repeating: 0, count: M * C * N)
        for m in 0..<M {
            for c in 0..<C {
                let d = Double(preDelay) + max(0, h.delay[m * C + c])
                let D = Int(d.rounded(.down))
                let mu = d - Double(D)
                let k = fracDelayKernel(mu)
                let start = D - fdHalf + 1
                let ob = (m * C + c) * N + start
                let ib = (m * C + c) * L
                // full convolution y[n] = sum_t h[t] k[n-t], n in 0 ..< L+K-1
                for n in 0..<(L + K - 1) {
                    var acc = 0.0
                    let tLo = max(0, n - K + 1), tHi = min(L - 1, n)
                    if tLo <= tHi {
                        for t in tLo...tHi { acc += h.ir[ib + t] * k[n - t] }
                    }
                    out[ob + n] = acc
                }
            }
        }
        return (out, N)
    }
}
