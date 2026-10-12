//
//  FastRouteProtocol.swift
//  FastRoute Companion
//
//  The wire format FastRoute for Windows uses between its Net Send and Net
//  Receive blocks. Three UDP packet kinds, all little-endian, version 1:
//
//    FRNB  beacon      96 bytes   a sender announcing itself; multicast to
//                                 239.255.77.20:6981 twice a second, and sent
//                                 unicast in answer to a subscribe request.
//    FRND  data        32 + n     one packet of encoded audio.
//    FRNS  subscribe   48 bytes   a receiver asking a sender for the audio,
//                                 repeated every second; the sender keeps the
//                                 asker for six seconds after the last one.
//
//  A sender either multicasts data to a group (default 239.255.77.21:6982),
//  pushes to one named host, or waits on its port for subscribers and sends to
//  each of them. Audio is always two channels.
//

import Foundation

enum FastRouteNet {
    static let version: UInt8 = 1
    static let channels: UInt8 = 2

    /// 239.255.77.20, where every sender announces itself.
    static let beaconGroup: UInt32 = 0xEFFF_4D14
    static let beaconPort: UInt16 = 6981
    /// 239.255.77.21, the group a sender uses when none is given.
    static let defaultGroup: UInt32 = 0xEFFF_4D15
    static let defaultPort: UInt16 = 6982
    static let vbanDefaultPort: UInt16 = 6980

    static let beaconInterval: TimeInterval = 0.5
    static let subscribeInterval: TimeInterval = 1.0
    static let subscriberTimeout: TimeInterval = 6.0
    /// The receiver refuses a data payload longer than this.
    static let maxPayloadBytes = 1400
    static let dataHeaderBytes = 32
    static let beaconBytes = 96
    static let subscribeBytes = 48

    static let magicBeacon = "FRNB"
    static let magicData = "FRND"
    static let magicSubscribe = "FRNS"

    /// A name as it reads after the trip through a 32 byte ASCII field.
    static func wireName(_ name: String) -> String {
        var w = ByteWriter(capacity: 32)
        w.asciiField(name, width: 32)
        var r = ByteReader(w.data)
        return r.asciiField(width: 32) ?? ""
    }
}

/// The codec byte in beacons and data packets.
enum NetCodec: UInt8, Codable, CaseIterable {
    case pcm16 = 0
    case pcm24 = 1
    case pcmFloat32 = 2
    case flac = 3
    case opus = 4

    var displayName: String {
        switch self {
        case .pcm16: return "16 bit PCM, lossless"
        case .pcm24: return "24 bit PCM, lossless"
        case .pcmFloat32: return "32 bit float PCM, lossless"
        case .flac: return "FLAC, lossless and compressed"
        case .opus: return "Opus, lossy and small"
        }
    }
    var shortName: String {
        switch self {
        case .pcm16: return "16 bit PCM"
        case .pcm24: return "24 bit PCM"
        case .pcmFloat32: return "32 bit float"
        case .flac: return "FLAC"
        case .opus: return "Opus"
        }
    }
    /// Bytes per stereo frame for the raw PCM codecs; nil for the compressed ones.
    var pcmBytesPerFrame: Int? {
        switch self {
        case .pcm16: return 4
        case .pcm24: return 6
        case .pcmFloat32: return 8
        case .flac, .opus: return nil
        }
    }
}

/// FRNB. Everything a receiver needs to pick a sender and talk to it.
struct Beacon: Equatable {
    var codec: NetCodec
    var channels: UInt8 = FastRouteNet.channels
    /// Identifies the stream across restarts; a receiver follows the name but
    /// uses this to ignore data from anyone else once it has latched on.
    var streamID: UInt32
    /// Host-order IPv4 multicast group the data goes to, or 0 when the sender
    /// unicasts (to one host, or to whoever asks).
    var group: UInt32
    var port: UInt16
    var framesPerPacket: UInt16
    var sampleRate: UInt32
    var streamName: String
    var hostName: String

    func encode() -> Data {
        var w = ByteWriter(capacity: FastRouteNet.beaconBytes)
        w.bytes(Data(FastRouteNet.magicBeacon.utf8))
        w.u8(FastRouteNet.version)
        w.u8(codec.rawValue)
        w.u8(channels)
        w.u8(0)
        w.u32(streamID)
        w.u32(group)
        w.u16(port)
        w.u16(framesPerPacket)
        w.u32(sampleRate)
        w.asciiField(streamName, width: 32)
        w.asciiField(hostName, width: 32)
        w.zeros(8)
        return w.data
    }

    static func decode(_ data: Data) -> Beacon? {
        guard data.count >= FastRouteNet.beaconBytes else { return nil }
        var r = ByteReader(data)
        guard let magic = r.bytes(4), magic == Data(FastRouteNet.magicBeacon.utf8),
              r.u8() == FastRouteNet.version,
              let codecByte = r.u8(), let codec = NetCodec(rawValue: codecByte),
              let channels = r.u8(), r.skip(1),
              let streamID = r.u32(), let group = r.u32(),
              let port = r.u16(), let frames = r.u16(), let rate = r.u32(),
              let name = r.asciiField(width: 32), let host = r.asciiField(width: 32)
        else { return nil }
        return Beacon(codec: codec, channels: channels, streamID: streamID, group: group, port: port,
                      framesPerPacket: frames, sampleRate: rate, streamName: name, hostName: host)
    }
}

/// FRND header. The payload follows immediately: raw PCM, one FLAC frame, or
/// one Opus packet, `frames` stereo frames long.
struct DataPacketHeader {
    var codec: NetCodec
    var channels: UInt8 = FastRouteNet.channels
    var sampleRate: UInt32
    var streamID: UInt32
    var sequence: UInt32
    /// Running count of frames sent before this packet; what the receiver
    /// uses to size the gap when packets go missing.
    var framePosition: UInt64
    var frames: UInt16
    var payloadLength: UInt16

    func encode(payload: Data) -> Data {
        var w = ByteWriter(capacity: FastRouteNet.dataHeaderBytes + payload.count)
        w.bytes(Data(FastRouteNet.magicData.utf8))
        w.u8(FastRouteNet.version)
        w.u8(codec.rawValue)
        w.u8(channels)
        w.u8(0)
        w.u32(sampleRate)
        w.u32(streamID)
        w.u32(sequence)
        w.u64(framePosition)
        w.u16(frames)
        w.u16(UInt16(payload.count))
        w.bytes(payload)
        return w.data
    }

    /// Parses a packet, returning the header and the payload it carries.
    static func decode(_ data: Data) -> (DataPacketHeader, Data)? {
        guard data.count >= FastRouteNet.dataHeaderBytes else { return nil }
        var r = ByteReader(data)
        guard let magic = r.bytes(4), magic == Data(FastRouteNet.magicData.utf8),
              r.u8() == FastRouteNet.version,
              let codecByte = r.u8(), let codec = NetCodec(rawValue: codecByte),
              let channels = r.u8(), (1...8).contains(channels), r.skip(1),
              let rate = r.u32(), let streamID = r.u32(), let seq = r.u32(),
              let pos = r.u64(), let frames = r.u16(), let len = r.u16(),
              Int(len) <= FastRouteNet.maxPayloadBytes,
              let payload = r.bytes(Int(len))
        else { return nil }
        let header = DataPacketHeader(codec: codec, channels: channels, sampleRate: rate, streamID: streamID,
                                      sequence: seq, framePosition: pos, frames: frames, payloadLength: len)
        return (header, payload)
    }
}

/// FRNS. Sent by a receiver to the sender's port. The sender adds the source
/// address as a subscriber, and answers with a unicast beacon when asked to.
struct SubscribeRequest {
    /// True asks the sender to answer with a beacon.
    var wantsBeacon: Bool = true
    /// The stream wanted, or 0 for whichever stream the sender has.
    var streamID: UInt32 = 0
    /// The stream wanted by name, or empty for whichever the sender has.
    var streamName: String = ""

    func encode() -> Data {
        var w = ByteWriter(capacity: FastRouteNet.subscribeBytes)
        w.bytes(Data(FastRouteNet.magicSubscribe.utf8))
        w.u8(FastRouteNet.version)
        w.u8(wantsBeacon ? 1 : 0)
        w.u16(0)
        w.u32(streamID)
        w.asciiField(streamName, width: 32)
        w.zeros(4)
        return w.data
    }

    static func decode(_ data: Data) -> SubscribeRequest? {
        guard data.count >= FastRouteNet.subscribeBytes else { return nil }
        var r = ByteReader(data)
        guard let magic = r.bytes(4), magic == Data(FastRouteNet.magicSubscribe.utf8),
              r.u8() == FastRouteNet.version,
              let flag = r.u8(), r.skip(2),
              let id = r.u32(), let name = r.asciiField(width: 32)
        else { return nil }
        return SubscribeRequest(wantsBeacon: flag != 0, streamID: id, streamName: name)
    }
}

/// Which protocol a net block speaks.
enum NetProtocol: Int, Codable, CaseIterable {
    case fastRoute = 0
    case vban = 1

    var displayName: String {
        switch self {
        case .fastRoute: return "FastRoute"
        case .vban: return "VBAN"
        }
    }
}
