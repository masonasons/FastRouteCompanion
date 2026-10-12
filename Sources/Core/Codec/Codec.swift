//
//  Codec.swift
//  FastRoute Companion
//
//  Encoders turn interleaved stereo float frames into the payload of one
//  FastRoute data packet at a time; decoders do the reverse and conceal the
//  packets that never arrived. Every codec works on two channels, which is
//  all the protocol carries.
//

import Foundation

struct EncodedPacket {
    var payload: Data
    /// Stereo frames the payload represents.
    var frames: Int
}

protocol AudioEncoder: AnyObject {
    var codec: NetCodec { get }
    /// The rate the encoder wants its input at. Opus works at 48 kHz only.
    var sampleRate: UInt32 { get }
    /// Frames the encoder consumes per packet.
    var framesPerPacket: Int { get }
    /// Encodes exactly `framesPerPacket` interleaved stereo frames.
    func encode(_ frames: UnsafePointer<Float>) -> EncodedPacket?
}

protocol AudioDecoder: AnyObject {
    var codec: NetCodec { get }
    /// Decodes one payload into `out`, appending interleaved stereo frames.
    /// `frames` is what the packet header says the payload holds.
    func decode(_ payload: Data, frames: Int, into out: inout [Float]) -> Bool
    /// Appends `frames` frames standing in for a packet that was lost.
    /// `nextPayload` is the packet after the gap when it is already in hand,
    /// which Opus can rebuild the lost one from.
    func conceal(frames: Int, nextPayload: Data?, into out: inout [Float])
}

enum CodecError: Error, LocalizedError {
    case opus(String, Int32)
    case flac(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .opus(let what, let code): return "\(what) (Opus error \(code): \(String(cString: opus_strerror(code))))."
        case .flac(let what): return what
        case .unsupported(let what): return what
        }
    }
}

enum CodecFactory {
    /// The largest number of stereo frames one packet of `codec` can carry at
    /// `sampleRate`, so the payload still fits one datagram.
    static func maxFramesPerPacket(codec: NetCodec, sampleRate: UInt32) -> Int {
        switch codec {
        case .pcm16: return (FastRouteNet.maxPayloadBytes - 32) / 4
        case .pcm24: return (FastRouteNet.maxPayloadBytes - 32) / 6
        case .pcmFloat32: return (FastRouteNet.maxPayloadBytes - 32) / 8
        case .flac: return (FastRouteNet.maxPayloadBytes - 32) / 4
        case .opus: return 2880
        }
    }

    /// Frames per packet for a requested packet length, clamped to what fits.
    /// Opus only knows certain frame lengths, so it rounds to the nearest.
    static func framesPerPacket(codec: NetCodec, sampleRate: UInt32, packetMs: Double) -> Int {
        if codec == .opus {
            return OpusEncoderWrapper.frameSize(forPacketMs: packetMs)
        }
        let wanted = Int((Double(sampleRate) * packetMs / 1000.0).rounded())
        return max(1, min(wanted, maxFramesPerPacket(codec: codec, sampleRate: sampleRate)))
    }

    static func makeEncoder(codec: NetCodec, sampleRate: UInt32, packetMs: Double, opus: OpusSettings) throws -> AudioEncoder {
        switch codec {
        case .pcm16, .pcm24, .pcmFloat32:
            return PCMEncoder(codec: codec, sampleRate: sampleRate,
                              framesPerPacket: framesPerPacket(codec: codec, sampleRate: sampleRate, packetMs: packetMs))
        case .flac:
            return try FLACEncoderWrapper(sampleRate: sampleRate,
                                          blockSize: framesPerPacket(codec: codec, sampleRate: sampleRate, packetMs: packetMs))
        case .opus:
            return try OpusEncoderWrapper(frameSize: OpusEncoderWrapper.frameSize(forPacketMs: packetMs), settings: opus)
        }
    }

    static func makeDecoder(codec: NetCodec, sampleRate: UInt32) throws -> AudioDecoder {
        switch codec {
        case .pcm16, .pcm24, .pcmFloat32:
            return PCMDecoder(codec: codec)
        case .flac:
            return try FLACDecoderWrapper(sampleRate: sampleRate)
        case .opus:
            return try OpusDecoderWrapper()
        }
    }
}
