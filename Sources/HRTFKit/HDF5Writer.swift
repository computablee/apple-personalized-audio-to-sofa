import Foundation

// Minimal, dependency-free HDF5 writer producing netCDF-4 compatible files.
// Mirrors reference/apple_hrtf_to_sofa.py (SOFAWriter) byte for byte.
//
// Structure (chosen so libhdf5, netCDF-C and libmysofa all read it):
//   superblock v2, object headers v2, root group with dense link storage
//   (fractal heap + v2 B-tree name index), netCDF dimension scales
//   (CLASS / NAME / REFERENCE_LIST / _Netcdf4Dimid), variables with
//   DIMENSION_LIST (vlen object references via a global heap collection),
//   contiguous little-endian float64 data.

let UNDEF: UInt64 = .max

public typealias Bytes = [UInt8]

extension Array where Element == UInt8 {
    mutating func le<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { self.append(contentsOf: $0) }
    }
}

func p8(_ v: Int) -> Bytes { [UInt8(truncatingIfNeeded: v)] }
func p16(_ v: Int) -> Bytes { var b = Bytes(); b.le(UInt16(truncatingIfNeeded: v)); return b }
func p32(_ v: Int) -> Bytes { var b = Bytes(); b.le(UInt32(truncatingIfNeeded: v)); return b }
func p32u(_ v: UInt32) -> Bytes { var b = Bytes(); b.le(v); return b }
func p64u(_ v: UInt64) -> Bytes { var b = Bytes(); b.le(v); return b }
func p64(_ v: Int) -> Bytes { p64u(UInt64(v)) }
func cat(_ parts: Bytes...) -> Bytes { var out = Bytes(); for p in parts { out += p }; return out }
func ascii(_ s: String) -> Bytes { Bytes(s.utf8) }
func align8(_ x: Int) -> Int { (x + 7) & ~7 }

// MARK: - Jenkins lookup3 (HDF5 metadata checksum + link name hash)

@inline(__always) private func rot(_ x: UInt32, _ k: UInt32) -> UInt32 { (x << k) | (x >> (32 - k)) }

public func lookup3(_ data: Bytes, _ initval: UInt32 = 0) -> UInt32 {
    var length = data.count
    var a: UInt32 = 0xdeadbeef &+ UInt32(truncatingIfNeeded: length) &+ initval
    var b = a
    var c = a
    var i = 0
    func word(_ k: Int) -> UInt32 {
        UInt32(data[k]) | UInt32(data[k + 1]) << 8 | UInt32(data[k + 2]) << 16 | UInt32(data[k + 3]) << 24
    }
    while length > 12 {
        a = a &+ word(i); b = b &+ word(i + 4); c = c &+ word(i + 8)
        a = a &- c; a ^= rot(c, 4);  c = c &+ b
        b = b &- a; b ^= rot(a, 6);  a = a &+ c
        c = c &- b; c ^= rot(b, 8);  b = b &+ a
        a = a &- c; a ^= rot(c, 16); c = c &+ b
        b = b &- a; b ^= rot(a, 19); a = a &+ c
        c = c &- b; c ^= rot(b, 4);  b = b &+ a
        length -= 12; i += 12
    }
    if length == 0 { return c }
    var w: [UInt32] = [0, 0, 0]
    for j in 0..<length {
        w[j / 4] |= UInt32(data[i + j]) << UInt32(8 * (j % 4))
    }
    a = a &+ w[0]; b = b &+ w[1]; c = c &+ w[2]
    c ^= b; c = c &- rot(b, 14)
    a ^= c; a = a &- rot(c, 11)
    b ^= a; b = b &- rot(a, 25)
    c ^= b; c = c &- rot(b, 16)
    a ^= c; a = a &- rot(c, 4)
    b ^= a; b = b &- rot(a, 14)
    c ^= b; c = c &- rot(b, 24)
    return c
}

// MARK: - Message encoders

let DT_F64: Bytes = cat([0x11, 0x20, 0x3f, 0x00], p32(8), p16(0), p16(64), [52, 11, 0, 52], p32(1023))
let DT_F32: Bytes = cat([0x11, 0x20, 0x1f, 0x00], p32(4), p16(0), p16(32), [23, 8, 0, 23], p32(127))
let DT_I32: Bytes = cat([0x10, 0x08, 0x00, 0x00], p32(4), p16(0), p16(32))
let DT_REF: Bytes = cat([0x17, 0x00, 0x00, 0x00], p32(8))
let DT_VLEN_REF: Bytes = cat([0x19, 0x00, 0x00, 0x00], p32(16), DT_REF)

func dtStr(_ n: Int) -> Bytes { cat([0x13, 0x00, 0x00, 0x00], p32(n)) }

func compoundMemberV1(_ name: String, _ offset: Int, _ dt: Bytes) -> Bytes {
    var nb = ascii(name); nb.append(0)
    while nb.count % 8 != 0 { nb.append(0) }
    return cat(nb, p32(offset), p8(0), Bytes(repeating: 0, count: 3), p32(0), p32(0),
               Bytes(repeating: 0, count: 16), dt)
}

let DT_REFLIST: Bytes = cat([0x16, 0x02, 0x00, 0x00], p32(16),
                            compoundMemberV1("dataset", 0, DT_REF),
                            compoundMemberV1("dimension", 8, DT_I32))

let DS_SCALAR: Bytes = [2, 0, 0, 0]

func dsSimple(_ dims: [Int]) -> Bytes {
    var b: Bytes = [2, UInt8(dims.count), 0, 1]
    for d in dims { b += p64(d) }
    return b
}

func msg(_ type: Int, _ body: Bytes) -> Bytes { cat(p8(type), p16(body.count), p8(0), body) }

func attrMsg(_ name: String, _ dt: Bytes, _ ds: Bytes, _ data: Bytes) -> Bytes {
    var nb = ascii(name); nb.append(0)
    let body = cat(p8(3), p8(0), p16(nb.count), p16(dt.count), p16(ds.count), p8(0), nb, dt, ds, data)
    return msg(0x0C, body)
}

/// libmysofa rejects any datatype larger than 64 bytes, strings included.
public let maxTextBytes = 64

func clipUTF8(_ value: String, _ limit: Int = maxTextBytes) -> Bytes {
    var s = value
    while s.utf8.count > limit { s.removeLast() }
    return Bytes(s.utf8)
}

func textAttr(_ name: String, _ value: String) -> Bytes {
    var v = clipUTF8(value)
    if v.isEmpty { v = [0x20] }
    return attrMsg(name, dtStr(v.count), DS_SCALAR, v)
}

func cstrAttr(_ name: String, _ value: String) -> Bytes {
    var v = ascii(value); v.append(0)
    return attrMsg(name, dtStr(v.count), DS_SCALAR, v)
}

func ohdr(_ messages: [Bytes]) -> Bytes {
    var body = Bytes()
    for m in messages { body += m }
    let h = cat(ascii("OHDR"), p8(2), p8(0x02), p32(body.count), body)
    return h + p32u(lookup3(h))
}

let FILL_MSG: Bytes = msg(0x05, [3, 0x09])

func layoutMsg(_ addr: UInt64, _ size: Int) -> Bytes { msg(0x08, cat([3, 1], p64u(addr), p64(size))) }

// MARK: - Writer

public final class SOFAWriter {
    struct Variable {
        let name: String
        let dims: [String]
        let shape: [Int]
        let values: [Double]
        let attrs: [(String, String)]
    }

    var dims: [(String, Int)] = []
    var vars: [Variable] = []
    var gattrs: [(String, String)] = []

    public init() {}

    public func addDim(_ name: String, _ n: Int) { dims.append((name, n)) }

    public func addGlobalAttr(_ name: String, _ value: String) { gattrs.append((name, value)) }

    public func addVar(_ name: String, _ dimNames: [String], _ values: [Double], _ attrs: [(String, String)] = []) {
        let shape = dimNames.map { dn in dims.first(where: { $0.0 == dn })!.1 }
        precondition(shape.reduce(1, *) == values.count, "\(name): \(values.count) values for shape \(shape)")
        vars.append(Variable(name: name, dims: dimNames, shape: shape, values: values, attrs: attrs))
    }

    private func build(_ A: [String: UInt64]) -> [String: Bytes] {
        var blobs: [String: Bytes] = [:]
        func addr(_ k: String) -> UInt64 { A[k]! }

        // global heap: one 8-byte object reference per (variable, dimension position)
        var gobjs: [UInt64] = []
        var gindex: [String: Int] = [:]
        for v in vars {
            for (k, dn) in v.dims.enumerated() {
                gobjs.append(addr("dim:" + dn))
                gindex["\(v.name)#\(k)"] = gobjs.count
            }
        }
        var g = cat(ascii("GCOL"), p8(1), [0, 0, 0], p64(0))
        for (i, ref) in gobjs.enumerated() {
            g += cat(p16(i + 1), p16(0), p32(0), p64(8), p64u(ref))
        }
        let gsize = max(4096, align8(g.count + 16))
        g.replaceSubrange(8..<16, with: p64(gsize))
        g += cat(p16(0), p16(0), p32(0), p64(gsize - g.count))
        g += Bytes(repeating: 0, count: gsize - g.count)
        blobs["gcol"] = g

        // dimension scales
        for (di, (dn, n)) in dims.enumerated() {
            var refs: [(UInt64, Int)] = []
            for v in vars {
                for (k, d) in v.dims.enumerated() where d == dn { refs.append((addr("var:" + v.name), k)) }
            }
            var rl = Bytes()
            for (a, k) in refs { rl += cat(p64u(a), p32(k), p32(0)) }
            let nstr = String(n)
            let name = "This is a netCDF dimension but not a netCDF variable."
                + String(repeating: " ", count: max(0, 10 - nstr.count)) + nstr
            var m: [Bytes] = [msg(0x01, dsSimple([n])), msg(0x03, DT_F32), FILL_MSG,
                              layoutMsg(addr("data:dim:" + dn), 4 * n),
                              cstrAttr("CLASS", "DIMENSION_SCALE"),
                              cstrAttr("NAME", name),
                              attrMsg("_Netcdf4Dimid", DT_I32, DS_SCALAR, p32(di))]
            if !refs.isEmpty {
                m.append(attrMsg("REFERENCE_LIST", DT_REFLIST, dsSimple([refs.count]), rl))
            }
            blobs["dim:" + dn] = ohdr(m)
        }

        // variables
        for v in vars {
            var dl = Bytes()
            for k in 0..<v.dims.count { dl += cat(p32(1), p64u(addr("gcol")), p32(gindex["\(v.name)#\(k)"]!)) }
            var m: [Bytes] = [msg(0x01, dsSimple(v.shape)), msg(0x03, DT_F64), FILL_MSG,
                              layoutMsg(addr("data:var:" + v.name), v.values.count * 8),
                              attrMsg("DIMENSION_LIST", DT_VLEN_REF, dsSimple([v.dims.count]), dl)]
            for (an, av) in v.attrs { m.append(textAttr(an, av)) }
            blobs["var:" + v.name] = ohdr(m)
        }

        // links (dims first: libmysofa resolves DIMENSION_LIST names in this order)
        var links: [(String, UInt64)] = dims.map { ($0.0, addr("dim:" + $0.0)) }
        links += vars.map { ($0.name, addr("var:" + $0.name)) }
        let DBLK = 4096
        let hdrLen = 4 + 1 + 8 + 4
        var dblk = cat(ascii("FHDB"), p8(0), p64u(addr("frhp")), p32(0))
        var heapIDs: [(Bytes, Bytes)] = []
        for (corder, (name, a)) in links.enumerated() {
            let nb = ascii(name)
            let lm = cat(p8(1), p8(0x04), p64(corder), p8(nb.count), nb, p64u(a))
            heapIDs.append((nb, cat(p8(0), p32(dblk.count), p16(lm.count))))
            dblk += lm
        }
        precondition(dblk.count < DBLK - 1, "too many links for one direct block")
        let used = dblk.count - hdrLen
        dblk += Bytes(repeating: 0, count: DBLK - dblk.count)
        blobs["fhdb"] = dblk

        let f = cat(ascii("FRHP"), p8(0), p16(7), p16(0), p8(0), p32(4096),
                    p64(0), p64u(UNDEF),                        // next huge id, huge-object btree
                    p64(DBLK - hdrLen - used), p64u(UNDEF),     // free space, free-space manager
                    p64(DBLK), p64(DBLK), p64(DBLK),            // managed, allocated, iterator offset
                    p64(links.count),                           // managed objects
                    p64(0), p64(0), p64(0), p64(0),             // huge size/count, tiny size/count
                    p16(4), p64(DBLK), p64(65536), p16(32), p16(1),
                    p64u(addr("fhdb")), p16(0))
        blobs["frhp"] = f + p32u(lookup3(f))

        let recs = heapIDs.map { (lookup3($0.0), $0.1) }.sorted { $0.0 < $1.0 }
        precondition(Set(recs.map { $0.0 }).count == recs.count, "link name hash collision")
        var leaf = cat(ascii("BTLF"), p8(0), p8(5))
        for (h, hid) in recs { leaf += cat(p32u(h), hid) }
        leaf += p32u(lookup3(leaf))
        leaf += Bytes(repeating: 0, count: 512 - leaf.count)
        blobs["btlf"] = leaf
        let bh = cat(ascii("BTHD"), p8(0), p8(5), p32(512), p16(11), p16(0), p8(100), p8(40),
                     p64u(addr("btlf")), p16(recs.count), p64(recs.count))
        blobs["bthd"] = bh + p32u(lookup3(bh))

        // root group
        var m: [Bytes] = [msg(0x02, cat(p8(0), p8(0x01), p64(links.count), p64u(addr("frhp")), p64u(addr("bthd")))),
                          msg(0x0A, [0, 0])]
        for (an, av) in gattrs { m.append(textAttr(an, av)) }
        blobs["root"] = ohdr(m)
        return blobs
    }

    public func serialize() -> Data {
        var keys: [String] = ["root"]
        for d in dims { keys.append("dim:" + d.0) }
        for v in vars { keys.append("var:" + v.name) }
        keys += ["frhp", "fhdb", "bthd", "btlf", "gcol"]
        var A0: [String: UInt64] = [:]
        for k in keys { A0[k] = 0 }
        for d in dims { A0["data:dim:" + d.0] = 0 }
        for v in vars { A0["data:var:" + v.name] = 0 }
        let sizes = build(A0).mapValues { $0.count }

        var A: [String: UInt64] = [:]
        var pos = 48
        for k in keys { A[k] = UInt64(pos); pos = align8(pos + sizes[k]!) }
        var rawPos: [(Int, Int)] = []      // (offset, byteCount) for dims, then vars
        for d in dims { A["data:dim:" + d.0] = UInt64(pos); rawPos.append((pos, 4 * d.1)); pos = align8(pos + 4 * d.1) }
        for v in vars {
            A["data:var:" + v.name] = UInt64(pos); rawPos.append((pos, v.values.count * 8)); pos = align8(pos + v.values.count * 8)
        }
        let eof = pos
        let blobs = build(A)
        for k in keys { precondition(blobs[k]!.count == sizes[k]!, "size changed for \(k)") }

        var sb = cat([0x89, 0x48, 0x44, 0x46, 0x0d, 0x0a, 0x1a, 0x0a], p8(2), p8(8), p8(8), p8(0),
                     p64(0), p64u(UNDEF), p64(eof), p64u(A["root"]!))
        sb += p32u(lookup3(sb))

        var out = Data(count: eof)
        out.replaceSubrange(0..<48, with: sb)
        for k in keys {
            let a = Int(A[k]!)
            out.replaceSubrange(a..<(a + blobs[k]!.count), with: blobs[k]!)
        }
        // dimension datasets are zero-filled already; write variable data (little-endian float64)
        for (i, v) in vars.enumerated() {
            let (off, n) = rawPos[dims.count + i]
            let le = v.values.map { $0.bitPattern.littleEndian }
            le.withUnsafeBytes { buf in out.replaceSubrange(off..<(off + n), with: buf) }
        }
        return out
    }

    public func write(to url: URL) throws {
        try serialize().write(to: url, options: .atomic)
    }
}
