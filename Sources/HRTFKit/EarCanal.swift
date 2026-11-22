import Foundation

/// Blocked-ear-canal-entrance -> eardrum conversion for diffuse-field HRTFs.
///
/// Source: D. Hammershøi & H. Møller (2008), "Determination of noise immission from sound
/// sources close to the ears", Acta Acustica united with Acustica 94, Table II: mean diffuse-field
/// HRTFs (third-octave, dB) of published human data at the eardrum (ED) and the blocked entrance (BE).
/// The correction is  ΔL_DF(ED) − ΔL_DF(BE).
public enum EarCanalCorrection {
    public static let source = "Hammershøi & Møller (2008), Acta Acustica united with Acustica 94, Table II"

    /// Third-octave centre frequencies (Hz); the table's "≤100 Hz" row is taken as 100 Hz.
    public static let frequencies: [Double] = [100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250,
                                               1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000]
    /// ΔL_DF at the eardrum (Table II).
    public static let eardrumDF: [Double] = [0.0, 0.2, 0.4, 0.6, 0.8, 1.1, 1.5, 2.1, 2.8, 3.3, 4.1, 5.5,
                                             7.7, 11.0, 15.3, 15.7, 12.9, 10.6, 9.4, 9.5, 6.8, 3.8, 0.7]
    /// ΔL_DF at the blocked entrance (Table II).
    public static let blockedEntranceDF: [Double] = [0.0, 0.2, 0.4, 0.6, 0.8, 1.1, 1.5, 1.7, 2.2, 2.3, 2.3, 3.1,
                                                     3.8, 4.4, 5.9, 8.1, 10.3, 10.0, 7.3, 6.0, 3.8, 2.0, -0.2]

    /// ED − BE per band (dB).
    public static var bandCorrection: [Double] {
        zip(eardrumDF, blockedEntranceDF).map { $0 - $1 }
    }

    /// Correction in dB at frequency f: linear in dB over log-frequency between band centres,
    /// 0 dB below 100 Hz, held at the 16 kHz value above 16 kHz.
    public static func dB(at f: Double) -> Double {
        let c = bandCorrection
        if f <= frequencies[0] { return c[0] }
        if f >= frequencies[frequencies.count - 1] { return c[c.count - 1] }
        var i = 0
        while frequencies[i + 1] < f { i += 1 }
        let t = log(f / frequencies[i]) / log(frequencies[i + 1] / frequencies[i])
        return c[i] * (1 - t) + c[i + 1] * t
    }
}

extension HRTFAnalysis {
    public enum ReferencePoint: String, Sendable, Hashable, CaseIterable {
        /// As computed from Apple's data (assumed blocked ear-canal entrance).
        case canalEntrance
        /// Apple's data plus a population-average ear-canal correction to the eardrum.
        case eardrum

        public var label: String {
            switch self {
            case .canalEntrance: return "Ear-canal entrance (as computed from Apple's data)"
            case .eardrum: return "Eardrum (adds population-average ear canal)"
            }
        }
    }

    /// Plain-text description of the method and every assumption behind the current curves.
    public static func assumptions(_ o: Options) -> String {
        var s: [String] = []
        s.append("METHOD AND ASSUMPTIONS")
        s.append("")
        s.append("1. Diffuse-field definition. The diffuse-field HRTF is the power average of |HRTF|² over all directions, each direction weighted by the solid angle it represents (Møller et al. 1995, \"Design criteria for headphones\", J. Audio Eng. Soc. 43(4), Eqs. 28–29), computed separately for each ear. The LR-avg export is the power average of the two ears.")
        s.append("")
        s.append("2. Apple's equalization (inferred, not documented by Apple). Apple stores HRIRs that are already diffuse-field equalized: on test scans their solid-angle-weighted average linear magnitude is flat within about ±0.3 dB. The un-equalized response is reconstructed by adding back the per-ear \"CTF\" stored in the file (UserData.CTF, assumed to be in dB at k·fs/128 Hz, k = 0…63). If that interpretation of the CTF is wrong, so is every absolute curve shape shown with it.")
        if !(o.addCTF || o.reference == .eardrum) {
            s.append("   Currently OFF: curves show the stored (equalized) data, so the diffuse field is nearly flat by construction.")
        }
        s.append("")
        s.append("3. Measurement point of Apple's data (inferred). Apple's HRTF is derived from a scan of the outer ear, which cannot see the ear canal, so it is assumed to be referenced to the blocked ear-canal entrance. On test scans the reconstructed diffuse field agrees with the published human blocked-entrance mean within about 1.5 dB from 1 to 3.15 kHz, and lies 2–3 dB below it from 4 to 6.3 kHz.")
        s.append("")
        if o.reference == .eardrum {
            s.append("4. Eardrum conversion (ACTIVE). Each curve has ΔL_DF(eardrum) − ΔL_DF(blocked entrance) added, from \(EarCanalCorrection.source): third-octave means of published human data. This relies on sound transmission inside the ear canal being independent of direction (Hammershøi & Møller 1996, J. Acoust. Soc. Am. 100(1)), so the same correction is applied to every direction.")
            s.append("   • It is a POPULATION AVERAGE, not your ear canal. Individual ear canals differ considerably, and Apple's data contains no information about yours.")
            s.append("   • The eardrum and blocked-entrance means come from different groups of subjects. The same correction computed from the table's free-field columns agrees within about 1 dB at 2–2.5 kHz and within about 3 dB up to 6.3 kHz, but differs by up to 8 dB at 10–12.5 kHz. Treat the converted curve above about 8 kHz as rough.")
            s.append("   • Table values are third-octave band means, used as point values at band centres and interpolated linearly in dB over log-frequency; 0 dB at or below 100 Hz (and ≈0 dB up to 400 Hz); held at the 16 kHz value above 16 kHz.")
            s.append("   • The resulting curve is meant to be comparable with eardrum-referenced (DRP) measurements such as IEC 60318-4 \"711\" couplers or a B&K 5128, which have an ear canal and eardrum simulator. Remaining differences from such rigs (for example 4–10 kHz) are not corrected.")
        } else {
            s.append("4. No eardrum conversion. Curves are referenced to the ear-canal entrance and lack the ear-canal resonance (about +9 dB near 2.5 kHz in the diffuse field) that eardrum-referenced rigs such as 711 couplers or a B&K 5128 include.")
        }
        s.append("")
        s.append("5. Above about 16 kHz the data is not reliable: Apple's stored CTF rolls off steeply towards Nyquist.")
        s.append("")
        s.append("6. Levels are relative (dB re. the file's own scale), not calibrated SPL. Smoothing: " + (o.smoothing > 0 ? "1/\(Int(o.smoothing)) octave (power)." : "none.") + " Ear mapping: " + (o.mirror ? "mirrored (channel 1 = left)." : "standard (channel 0 = left)."))
        return s.joined(separator: "\n")
    }
}
