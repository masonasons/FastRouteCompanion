//
//  VBANProtocol.swift
//  FastRoute Companion
//
//  VB-Audio's VBAN protocol, as spoken by VoiceMeeter, the VBAN apps and
//  FastRoute. A 28 byte header then up to 1436 bytes of interleaved PCM.
//  Service packets (protocol 0x60) carry the identification "ping" used to
//  find hosts: a request has function 0, and the answer has function 0x80
//  and carries a 676 byte description of the host.
//

import Foundation

enum VBAN {
    static let headerBytes = 28
    static let maxDataBytes = 1436
    static let maxSamplesPerFrame = 256
    static let maxChannels = 256
    static let defaultPort: UInt16 = 6980

    static let sampleRates: [UInt32] = [
        6000, 12000, 24000, 48000, 96000, 192000, 384000,
        8000, 16000, 32000, 64000, 128000, 256000, 512000,
        11025, 22050, 44100, 88200, 176400, 352800, 705600,
    ]

    static func rateIndex(for rate: UInt32) -> UInt8? {
        guard let i = sampleRates.firstIndex(of: rate) else { return nil }
        return UInt8(i)
    }

    enum Proto: UInt8 {
        case audio = 0x00
        case serial = 0x20
        case text = 0x40
        case service = 0x60
    }

    enum DataType: UInt8 {
        case uint8 = 0, int16 = 1, int24 = 2, int32 = 3, float32 = 4, float64 = 5, int12 = 6, int10 = 7

        var bytesPerSample: Int? {
            switch self {
            case .uint8: return 1
            case .int16: return 2
            case .int24: return 3
            case .int32: return 4
            case .float32: return 4
            case .float64: return 8
            case .int12, .int10: return nil
            }
        }
    }

    /// Service functions and types (format_nbs and format_nbc of a service packet).
    static let serviceFunctionPing: UInt8 = 0x00
    static let serviceFunctionReply: UInt8 = 0x80
    static let serviceTypeIdentification: UInt8 = 0x00
    /// The stream name FastRoute puts on its ping requests. Receivers do not
    /// check it, so anything printable works.
    static let serviceStreamName = "FastRoute"

    struct Header: Equatable {
        var proto: Proto = .audio
        var sampleRateIndex: UInt8 = 3            // 48000
        /// 1...256 for audio. For a service packet this byte is the function.
        var samplesPerFrame: Int = 256
        /// 1...256 for audio. For a service packet this byte is the type.
        var channels: Int = 2
        var dataType: DataType = .int16
        /// Upper four bits of format_bit; 0 is PCM.
        var codec: UInt8 = 0
        var streamName: String = "Stream1"
        var frameCounter: UInt32 = 0

        var sampleRate: UInt32? {
            Int(sampleRateIndex) < VBAN.sampleRates.count ? VBAN.sampleRates[Int(sampleRateIndex)] : nil
        }

        /// The raw function byte of a service packet.
        var serviceFunction: UInt8 { UInt8(truncatingIfNeeded: samplesPerFrame - 1) }
        var serviceType: UInt8 { UInt8(truncatingIfNeeded: channels - 1) }

        func encode() -> Data {
            var w = ByteWriter(capacity: VBAN.headerBytes)
            w.bytes(Data("VBAN".utf8))
            w.u8(proto.rawValue | (sampleRateIndex & 0x1F))
            w.u8(UInt8(truncatingIfNeeded: samplesPerFrame - 1))
            w.u8(UInt8(truncatingIfNeeded: channels - 1))
            w.u8((codec << 4) | (dataType.rawValue & 0x07))
            w.asciiField(streamName, width: 16)
            w.u32(frameCounter)
            return w.data
        }

        static func decode(_ data: Data) -> Header? {
            guard data.count >= VBAN.headerBytes else { return nil }
            var r = ByteReader(data)
            guard let magic = r.bytes(4), magic == Data("VBAN".utf8),
                  let sr = r.u8(), let nbs = r.u8(), let nbc = r.u8(), let bit = r.u8(),
                  let name = r.asciiField(width: 16), let counter = r.u32()
            else { return nil }
            guard let proto = Proto(rawValue: sr & 0xE0), let dataType = DataType(rawValue: bit & 0x07) else { return nil }
            return Header(proto: proto, sampleRateIndex: sr & 0x1F, samplesPerFrame: Int(nbs) + 1,
                          channels: Int(nbc) + 1, dataType: dataType, codec: bit >> 4,
                          streamName: name, frameCounter: counter)
        }
    }

    /// The 676 byte body of an identification reply.
    struct Ping0 {
        static let bytes = 676

        static let typeReceptor: UInt32 = 0x0000_0001
        static let typeTransmitter: UInt32 = 0x0000_0002
        static let featureAudio: UInt32 = 0x0000_0001

        var bitType: UInt32 = 0
        var bitFeature: UInt32 = 0
        var bitFeatureEx: UInt32 = 0
        var preferredRate: UInt32 = 48000
        var minRate: UInt32 = 6000
        var maxRate: UInt32 = 705600
        var colorRGB: UInt32 = 0
        var version: (UInt8, UInt8, UInt8, UInt8) = (0, 1, 0, 0)
        var gpsPosition = ""
        var userPosition = ""
        var langCode = "en"
        var distantIP = ""
        var distantPort: UInt16 = 0
        var deviceName = ""
        var manufacturerName = ""
        var applicationName = ""
        var hostName = ""
        var userName = ""
        var userComment = ""

        func encode() -> Data {
            var w = ByteWriter(capacity: Ping0.bytes)
            w.u32(bitType)
            w.u32(bitFeature)
            w.u32(bitFeatureEx)
            w.u32(preferredRate)
            w.u32(minRate)
            w.u32(maxRate)
            w.u32(colorRGB)
            w.u8(version.0); w.u8(version.1); w.u8(version.2); w.u8(version.3)
            w.asciiField(gpsPosition, width: 8)
            w.asciiField(userPosition, width: 8)
            w.asciiField(langCode, width: 8)
            w.zeros(8)      // reserved_ascii
            w.zeros(64)     // reservedEx
            w.asciiField(distantIP, width: 32)
            w.u16(distantPort)
            w.u16(0)
            w.asciiField(deviceName, width: 64)
            w.asciiField(manufacturerName, width: 64)
            w.asciiField(applicationName, width: 64)
            w.asciiField(hostName, width: 64)
            w.bytes(Ping0.utf8Field(userName, width: 128))
            w.bytes(Ping0.utf8Field(userComment, width: 128))
            return w.data
        }

        static func decode(_ data: Data) -> Ping0? {
            guard data.count >= bytes else { return nil }
            var r = ByteReader(data)
            var p = Ping0()
            guard let t = r.u32(), let f = r.u32(), let fx = r.u32(), let pr = r.u32(),
                  let mn = r.u32(), let mx = r.u32(), let c = r.u32(),
                  let v0 = r.u8(), let v1 = r.u8(), let v2 = r.u8(), let v3 = r.u8(),
                  let gps = r.asciiField(width: 8), let up = r.asciiField(width: 8),
                  let lang = r.asciiField(width: 8), r.skip(8), r.skip(64),
                  let dip = r.asciiField(width: 32), let dport = r.u16(), r.skip(2),
                  let dev = r.asciiField(width: 64), let man = r.asciiField(width: 64),
                  let app = r.asciiField(width: 64), let host = r.asciiField(width: 64),
                  let user = r.bytes(128), let comment = r.bytes(128)
            else { return nil }
            p.bitType = t; p.bitFeature = f; p.bitFeatureEx = fx; p.preferredRate = pr
            p.minRate = mn; p.maxRate = mx; p.colorRGB = c; p.version = (v0, v1, v2, v3)
            p.gpsPosition = gps; p.userPosition = up; p.langCode = lang
            p.distantIP = dip; p.distantPort = dport
            p.deviceName = dev; p.manufacturerName = man; p.applicationName = app; p.hostName = host
            p.userName = Ping0.string(fromUTF8Field: user)
            p.userComment = Ping0.string(fromUTF8Field: comment)
            return p
        }

        private static func utf8Field(_ s: String, width: Int) -> Data {
            var d = Data(s.utf8.prefix(width - 1))
            d.append(Data(count: width - d.count))
            return d
        }
        private static func string(fromUTF8Field d: Data) -> String {
            let end = d.firstIndex(of: 0) ?? d.endIndex
            return String(decoding: d[d.startIndex..<end], as: UTF8.self)
        }
    }

    /// Builds an identification request.
    static func pingRequest(counter: UInt32) -> Data {
        var h = Header()
        h.proto = .service
        h.sampleRateIndex = 0
        h.samplesPerFrame = Int(serviceFunctionPing) + 1
        h.channels = Int(serviceTypeIdentification) + 1
        h.dataType = .uint8
        h.codec = 0
        h.streamName = serviceStreamName
        h.frameCounter = counter
        return h.encode()
    }

    /// Builds the answer to an identification request.
    static func pingReply(to request: Header, streamName: String, body: Ping0) -> Data {
        var h = Header()
        h.proto = .service
        h.sampleRateIndex = 0
        h.samplesPerFrame = Int(serviceFunctionReply) + 1
        h.channels = Int(serviceTypeIdentification) + 1
        h.dataType = .uint8
        h.codec = 0
        h.streamName = streamName.isEmpty ? serviceStreamName : streamName
        h.frameCounter = request.frameCounter
        var d = h.encode()
        d.append(body.encode())
        return d
    }
}
