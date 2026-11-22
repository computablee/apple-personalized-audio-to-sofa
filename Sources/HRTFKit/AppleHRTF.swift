import Foundation

public enum HRTFError: Error, LocalizedError {
    case notAPlist(String)
    case missingBlob(String)
    case badBlob(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notAPlist(let s): return "Not an Apple HRTF file (top level is not a property list): \(s)"
        case .missingBlob(let s): return "HRTF entry not found: \(s)"
        case .badBlob(let s): return "Malformed HRTF data: \(s)"
        case .unsupported(let s): return "Unsupported HRTF format: \(s)"
        }
    }
}

/// Personalized HRTF decoded from Apple's .dat (binary plist) export.
///
/// Blob layout (little-endian):
///   u32 n, n-byte bplist metadata, then M records of
///   f32 elevation, f32 azimuth (clockwise), and per channel L x i16 taps + f32 delay (samples).
public struct AppleHRTF: Sendable {
    public var sampleRate: Double
    public var numMeasurements: Int      // M
    public var numChannels: Int          // C (2)
    public var filterLength: Int         // L
    /// [elevation, azimuth] per measurement, Apple convention, degrees. Count M*2.
    public var coords: [Double]
    /// Scaled impulse responses, index (m*C + c)*L + n.
    public var ir: [Double]
    /// Delays in samples, index m*C + c.
    public var delay: [Double]
    public var device: String
    public var exportDate: String
    public var sourceFile: String
    public var blobKey: String
    /// Apple's stored "CTF" (UserData), 2 x K values in dB; likely the removed diffuse-field response.
    public var ctf: [Double] = []

    public static func load(url: URL, blobKey: String = "HRIR_DFEQ") throws -> AppleHRTF {
        let fileData = try Data(contentsOf: url)
        guard let top = try? PropertyListSerialization.propertyList(from: fileData, format: nil) as? [String: Any] else {
            throw HRTFError.notAPlist(url.lastPathComponent)
        }
        guard let blobData = top[blobKey] as? Data else {
            throw HRTFError.missingBlob("\(blobKey) (keys: \(top.keys.sorted().joined(separator: ", ")))")
        }
        let b = [UInt8](blobData)
        guard b.count > 4 else { throw HRTFError.badBlob("blob too short") }
        let n = Int(readU32(b, 0))
        guard 4 + n <= b.count else { throw HRTFError.badBlob("metadata length out of range") }
        let metaData = Data(b[4..<(4 + n)])
        guard let meta = try? PropertyListSerialization.propertyList(from: metaData, format: nil) as? [String: Any] else {
            throw HRTFError.badBlob("embedded metadata is not a property list")
        }
        guard (meta["CoefficientFormat"] as? String) == "int16", (meta["DelayFormat"] as? String) == "float32" else {
            throw HRTFError.unsupported("CoefficientFormat=\(meta["CoefficientFormat"] ?? "?") DelayFormat=\(meta["DelayFormat"] ?? "?")")
        }
        guard let M = (meta["TotalNumCoordinates"] as? NSNumber)?.intValue,
              let L = (meta["FilterLength"] as? NSNumber)?.intValue,
              let C = (meta["NumChannels"] as? NSNumber)?.intValue,
              let sr = (meta["SampleRate"] as? NSNumber)?.doubleValue,
              let scale = (meta["FilterScaleFactor"] as? NSNumber)?.doubleValue else {
            throw HRTFError.badBlob("missing metadata fields")
        }
        guard C == 2 else { throw HRTFError.unsupported("\(C) channels (expected 2)") }
        let rec = 8 + C * (2 * L + 4)
        let payload = 4 + n
        guard b.count - payload == M * rec else {
            throw HRTFError.badBlob("payload is \(b.count - payload) bytes, expected \(M) x \(rec)")
        }
        var coords = [Double](repeating: 0, count: M * 2)
        var ir = [Double](repeating: 0, count: M * C * L)
        var delay = [Double](repeating: 0, count: M * C)
        for m in 0..<M {
            let r = payload + m * rec
            coords[2 * m] = Double(readF32(b, r))
            coords[2 * m + 1] = Double(readF32(b, r + 4))
            for c in 0..<C {
                let o = r + 8 + c * (2 * L + 4)
                let base = (m * C + c) * L
                for t in 0..<L {
                    let v = Int16(bitPattern: UInt16(b[o + 2 * t]) | UInt16(b[o + 2 * t + 1]) << 8)
                    ir[base + t] = Double(v) * scale
                }
                delay[m * C + c] = Double(readF32(b, o + 2 * L))
            }
        }
        let eq = top["EQ"] as? [String: Any]
        var result = AppleHRTF(sampleRate: sr, numMeasurements: M, numChannels: C, filterLength: L,
                               coords: coords, ir: ir, delay: delay,
                               device: (top["device"] as? String) ?? "",
                               exportDate: (eq?["ExportDate"] as? String) ?? "",
                               sourceFile: url.lastPathComponent, blobKey: blobKey)
        if let user = meta["UserData"] as? [String: Any], let ctf = user["CTF"] as? [NSNumber], ctf.count % C == 0 {
            result.ctf = ctf.map { $0.doubleValue }
        }
        return result
    }
}

@inline(__always) func readU32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
}

@inline(__always) func readF32(_ b: [UInt8], _ i: Int) -> Float {
    Float(bitPattern: readU32(b, i))
}
