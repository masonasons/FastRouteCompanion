//
//  PCMCodec.swift
//  FastRoute Companion
//
//  The three raw formats: 16 bit, 24 bit packed and 32 bit float, all little
//  endian, interleaved left then right.
//

import Foundation

final class PCMEncoder: AudioEncoder {
    let codec: NetCodec
    let sampleRate: UInt32
    let framesPerPacket: Int

    init(codec: NetCodec, sampleRate: UInt32, framesPerPacket: Int) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.framesPerPacket = framesPerPacket
    }

    func encode(_ frames: UnsafePointer<Float>) -> EncodedPacket? {
        let samples = framesPerPacket * 2
        var data = Data(count: samples * (codec.pcmBytesPerFrame! / 2))
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            switch codec {
            case .pcm16:
                for i in 0..<samples {
                    let v = Int16(max(-32768, min(32767, (frames[i] * 32767).rounded())))
                    out[2 * i] = UInt8(truncatingIfNeeded: v)
                    out[2 * i + 1] = UInt8(truncatingIfNeeded: v >> 8)
                }
            case .pcm24:
                for i in 0..<samples {
                    let v = Int32(max(-8_388_608, min(8_388_607, (frames[i] * 8_388_607).rounded())))
                    out[3 * i] = UInt8(truncatingIfNeeded: v)
                    out[3 * i + 1] = UInt8(truncatingIfNeeded: v >> 8)
                    out[3 * i + 2] = UInt8(truncatingIfNeeded: v >> 16)
                }
            case .pcmFloat32:
                for i in 0..<samples {
                    let bits = frames[i].bitPattern
                    out[4 * i] = UInt8(truncatingIfNeeded: bits)
                    out[4 * i + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                    out[4 * i + 2] = UInt8(truncatingIfNeeded: bits >> 16)
                    out[4 * i + 3] = UInt8(truncatingIfNeeded: bits >> 24)
                }
            default:
                break
            }
        }
        return EncodedPacket(payload: data, frames: framesPerPacket)
    }
}

final class PCMDecoder: AudioDecoder {
    let codec: NetCodec

    init(codec: NetCodec) { self.codec = codec }

    func decode(_ payload: Data, frames: Int, into out: inout [Float]) -> Bool {
        guard let bytesPerFrame = codec.pcmBytesPerFrame, payload.count >= frames * bytesPerFrame else { return false }
        let samples = frames * 2
        let start = out.count
        out.append(contentsOf: repeatElement(0, count: samples))
        payload.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            switch codec {
            case .pcm16:
                for i in 0..<samples {
                    let v = Int16(bitPattern: UInt16(p[2 * i]) | UInt16(p[2 * i + 1]) << 8)
                    out[start + i] = Float(v) / 32768
                }
            case .pcm24:
                for i in 0..<samples {
                    var v = Int32(p[3 * i]) | Int32(p[3 * i + 1]) << 8 | Int32(p[3 * i + 2]) << 16
                    if v & 0x80_0000 != 0 { v -= 0x100_0000 }
                    out[start + i] = Float(v) / 8_388_608
                }
            case .pcmFloat32:
                for i in 0..<samples {
                    let bits = UInt32(p[4 * i]) | UInt32(p[4 * i + 1]) << 8 | UInt32(p[4 * i + 2]) << 16 | UInt32(p[4 * i + 3]) << 24
                    out[start + i] = Float(bitPattern: bits)
                }
            default:
                break
            }
        }
        return true
    }

    func conceal(frames: Int, nextPayload: Data?, into out: inout [Float]) {
        out.append(contentsOf: repeatElement(0, count: frames * 2))
    }
}
