//
//  ByteCoding.swift
//  FastRoute Companion
//
//  Little-endian byte packing helpers for the wire formats. Both the FastRoute
//  protocol and VBAN serialise every multi-byte field little-endian, with
//  fixed-width ASCII name fields padded with zeros.
//

import Foundation

struct ByteWriter {
    private(set) var data = Data()

    init(capacity: Int = 64) { data.reserveCapacity(capacity) }

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) {
        data.append(UInt8(truncatingIfNeeded: v))
        data.append(UInt8(truncatingIfNeeded: v >> 8))
    }
    mutating func u32(_ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: v >> UInt32(shift))) }
    }
    mutating func u64(_ v: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8(truncatingIfNeeded: v >> UInt64(shift))) }
    }
    mutating func zeros(_ count: Int) { data.append(Data(count: count)) }
    mutating func bytes(_ d: Data) { data.append(d) }

    /// Writes `width` bytes: the string reduced to printable ASCII (anything
    /// else becomes "?"), truncated, then zero padded. This is what FastRoute
    /// does with its wide strings, so names round-trip the same both ways.
    mutating func asciiField(_ s: String, width: Int) {
        // Curly quotes, accents and the like become their plain ASCII
        // relatives rather than question marks.
        let plain = s.applyingTransform(StringTransform("Any-Latin; Latin-ASCII"), reverse: false) ?? s
        var written = 0
        for scalar in plain.unicodeScalars where written < width {
            let v = scalar.value
            data.append(v >= 0x20 && v <= 0x7E ? UInt8(v) : 0x3F)
            written += 1
        }
        if written < width { zeros(width - written) }
    }
}

struct ByteReader {
    let data: Data
    private(set) var offset: Int

    init(_ data: Data) { self.data = data; offset = data.startIndex }

    var remaining: Int { data.endIndex - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return data[offset]
    }
    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        let v = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        offset += 2
        return v
    }
    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(data[offset + i]) << UInt32(8 * i) }
        offset += 4
        return v
    }
    mutating func u64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(data[offset + i]) << UInt64(8 * i) }
        offset += 8
        return v
    }
    mutating func skip(_ n: Int) -> Bool {
        guard remaining >= n else { return false }
        offset += n
        return true
    }
    /// Reads a zero padded ASCII field of `width` bytes.
    mutating func asciiField(width: Int) -> String? {
        guard remaining >= width else { return nil }
        let slice = data[offset..<(offset + width)]
        offset += width
        let end = slice.firstIndex(of: 0) ?? slice.endIndex
        return String(decoding: slice[slice.startIndex..<end], as: UTF8.self)
    }
    mutating func bytes(_ n: Int) -> Data? {
        guard remaining >= n else { return nil }
        let d = data.subdata(in: offset..<(offset + n))
        offset += n
        return d
    }
    func rest() -> Data { data.subdata(in: offset..<data.endIndex) }
}

extension UInt32 {
    /// Dotted-quad form of a host-order IPv4 address.
    var ipv4String: String {
        "\(self >> 24 & 0xFF).\(self >> 16 & 0xFF).\(self >> 8 & 0xFF).\(self & 0xFF)"
    }
    var isMulticastIPv4: Bool { (self >> 28) == 0xE }

    init?(ipv4String s: String) {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard let n = UInt8(p) else { return nil }
            v = v << 8 | UInt32(n)
        }
        self = v
    }
}
