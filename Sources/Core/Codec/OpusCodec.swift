//
//  OpusCodec.swift
//  FastRoute Companion
//
//  Opus at 48 kHz stereo through libopus. One Opus packet per network packet.
//  When loss protection is on, the encoder carries a low rate copy of each
//  packet inside the next one, and the decoder asks for it back when a packet
//  goes missing.
//

import Foundation

struct OpusSettings: Codable, Equatable {
    enum Signal: Int, Codable, CaseIterable {
        case auto = 0, voice = 1, music = 2
        var displayName: String {
            switch self {
            case .auto: return "Let Opus decide"
            case .voice: return "Speech"
            case .music: return "Music"
            }
        }
    }
    enum RateMode: Int, Codable, CaseIterable {
        case variable = 0, constrained = 1, constant = 2
        var displayName: String {
            switch self {
            case .variable: return "Variable"
            case .constrained: return "Variable, within one packet size"
            case .constant: return "Constant"
            }
        }
    }

    var bitrateKbps: Int = 128
    var complexity: Int = 10
    var lossPercent: Int = 0
    var signal: Signal = .auto
    var rateMode: RateMode = .variable
    var dtx: Bool = false
}

final class OpusEncoderWrapper: AudioEncoder {
    let codec: NetCodec = .opus
    let sampleRate: UInt32 = 48000
    let framesPerPacket: Int
    private let encoder: OpaquePointer
    private var outBuffer = [UInt8](repeating: 0, count: FastRouteNet.maxPayloadBytes)

    /// Opus frames are 2.5, 5, 10, 20, 40 or 60 ms long; this picks the nearest.
    static func frameSize(forPacketMs ms: Double) -> Int {
        let choices: [Double] = [2.5, 5, 10, 20, 40, 60]
        let best = choices.min { abs($0 - ms) < abs($1 - ms) } ?? 20
        return Int(best * 48)
    }

    init(frameSize: Int, settings: OpusSettings) throws {
        framesPerPacket = frameSize
        var err: Int32 = 0
        let application = settings.signal == .voice ? OPUS_APPLICATION_VOIP : OPUS_APPLICATION_AUDIO
        guard let enc = opus_encoder_create(48000, 2, application, &err), err == OPUS_OK else {
            throw CodecError.opus("The Opus encoder could not be created", err)
        }
        encoder = enc
        opus_encoder_ctl_set(enc, OPUS_SET_BITRATE_REQUEST, Int32(max(6, min(510, settings.bitrateKbps)) * 1000))
        opus_encoder_ctl_set(enc, OPUS_SET_COMPLEXITY_REQUEST, Int32(max(0, min(10, settings.complexity))))
        let loss = Int32(max(0, min(100, settings.lossPercent)))
        opus_encoder_ctl_set(enc, OPUS_SET_PACKET_LOSS_PERC_REQUEST, loss)
        opus_encoder_ctl_set(enc, OPUS_SET_INBAND_FEC_REQUEST, loss > 0 ? 1 : 0)
        opus_encoder_ctl_set(enc, OPUS_SET_DTX_REQUEST, settings.dtx ? 1 : 0)
        switch settings.signal {
        case .auto: opus_encoder_ctl_set(enc, OPUS_SET_SIGNAL_REQUEST, OPUS_AUTO)
        case .voice: opus_encoder_ctl_set(enc, OPUS_SET_SIGNAL_REQUEST, OPUS_SIGNAL_VOICE)
        case .music: opus_encoder_ctl_set(enc, OPUS_SET_SIGNAL_REQUEST, OPUS_SIGNAL_MUSIC)
        }
        switch settings.rateMode {
        case .variable:
            opus_encoder_ctl_set(enc, OPUS_SET_VBR_REQUEST, 1)
            opus_encoder_ctl_set(enc, OPUS_SET_VBR_CONSTRAINT_REQUEST, 0)
        case .constrained:
            opus_encoder_ctl_set(enc, OPUS_SET_VBR_REQUEST, 1)
            opus_encoder_ctl_set(enc, OPUS_SET_VBR_CONSTRAINT_REQUEST, 1)
        case .constant:
            opus_encoder_ctl_set(enc, OPUS_SET_VBR_REQUEST, 0)
        }
    }

    deinit { opus_encoder_destroy(encoder) }

    func encode(_ frames: UnsafePointer<Float>) -> EncodedPacket? {
        let n = outBuffer.withUnsafeMutableBufferPointer { out in
            opus_encode_float(encoder, frames, Int32(framesPerPacket), out.baseAddress!, Int32(out.count))
        }
        guard n > 0 else { return nil }
        return EncodedPacket(payload: Data(outBuffer[0..<Int(n)]), frames: framesPerPacket)
    }
}

final class OpusDecoderWrapper: AudioDecoder {
    let codec: NetCodec = .opus
    private let decoder: OpaquePointer
    private var scratch = [Float](repeating: 0, count: 5760 * 2)

    init() throws {
        var err: Int32 = 0
        guard let dec = opus_decoder_create(48000, 2, &err), err == OPUS_OK else {
            throw CodecError.opus("The Opus decoder could not be created", err)
        }
        decoder = dec
    }

    deinit { opus_decoder_destroy(decoder) }

    func decode(_ payload: Data, frames: Int, into out: inout [Float]) -> Bool {
        let n = payload.withUnsafeBytes { raw -> Int32 in
            scratch.withUnsafeMutableBufferPointer { buf in
                opus_decode_float(decoder, raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count),
                                  buf.baseAddress!, Int32(buf.count / 2), 0)
            }
        }
        guard n > 0 else { return false }
        out.append(contentsOf: scratch[0..<(Int(n) * 2)])
        return true
    }

    func conceal(frames: Int, nextPayload: Data?, into out: inout [Float]) {
        let wanted = max(120, min(5760, frames))
        var n: Int32 = 0
        if let next = nextPayload {
            n = next.withUnsafeBytes { raw -> Int32 in
                scratch.withUnsafeMutableBufferPointer { buf in
                    opus_decode_float(decoder, raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count),
                                      buf.baseAddress!, Int32(wanted), 1)
                }
            }
        }
        if n <= 0 {
            n = scratch.withUnsafeMutableBufferPointer { buf in
                opus_decode_float(decoder, nil, 0, buf.baseAddress!, Int32(wanted), 0)
            }
        }
        if n > 0 {
            out.append(contentsOf: scratch[0..<(Int(n) * 2)])
            if Int(n) < frames { out.append(contentsOf: repeatElement(0, count: (frames - Int(n)) * 2)) }
        } else {
            out.append(contentsOf: repeatElement(0, count: frames * 2))
        }
    }
}

/// opus_encoder_ctl is variadic, which Swift cannot call, so the handful of
/// integer setters go through this.
@discardableResult
private func opus_encoder_ctl_set(_ enc: OpaquePointer, _ request: Int32, _ value: Int32) -> Int32 {
    opus_encoder_ctl_set_int(enc, request, value)
}
