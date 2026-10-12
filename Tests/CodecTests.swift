//
//  CodecTests.swift
//  FastRoute Companion
//
//  Each codec survives a trip through its own decoder, and FLAC in
//  particular decodes from the synthesised stream header the way the
//  FastRoute receiver expects.
//

import XCTest

final class CodecTests: XCTestCase {
    private func tone(frames: Int, phase: Int = 0) -> [Float] {
        (0..<frames).flatMap { i -> [Float] in
            let t = Float(i + phase) / 48000
            return [0.5 * sin(2 * .pi * 440 * t), 0.25 * sin(2 * .pi * 660 * t)]
        }
    }

    func testPCMRoundTrips() {
        for codec in [NetCodec.pcm16, .pcm24, .pcmFloat32] {
            let fpp = CodecFactory.framesPerPacket(codec: codec, sampleRate: 48000, packetMs: 10)
            XCTAssertLessThanOrEqual(fpp * codec.pcmBytesPerFrame!, FastRouteNet.maxPayloadBytes - 32)
            let enc = PCMEncoder(codec: codec, sampleRate: 48000, framesPerPacket: fpp)
            let input = tone(frames: fpp)
            let packet = input.withUnsafeBufferPointer { enc.encode($0.baseAddress!) }!
            XCTAssertEqual(packet.payload.count, fpp * codec.pcmBytesPerFrame!)
            var out: [Float] = []
            XCTAssertTrue(PCMDecoder(codec: codec).decode(packet.payload, frames: fpp, into: &out))
            XCTAssertEqual(out.count, input.count)
            let tolerance: Float = codec == .pcm16 ? 1.0 / 32000 : 1e-6
            for (a, b) in zip(input, out) { XCTAssertEqual(a, b, accuracy: tolerance) }
        }
    }

    func testOpusRoundTrip() throws {
        var settings = OpusSettings()
        settings.lossPercent = 10
        let enc = try OpusEncoderWrapper(frameSize: OpusEncoderWrapper.frameSize(forPacketMs: 10), settings: settings)
        XCTAssertEqual(enc.framesPerPacket, 480)
        XCTAssertEqual(OpusEncoderWrapper.frameSize(forPacketMs: 7.3), 240)
        let dec = try OpusDecoderWrapper()
        var packets: [Data] = []
        for i in 0..<10 {
            let input = tone(frames: 480, phase: i * 480)
            let packet = input.withUnsafeBufferPointer { enc.encode($0.baseAddress!) }!
            XCTAssertEqual(packet.frames, 480)
            XCTAssertLessThanOrEqual(packet.payload.count, FastRouteNet.maxPayloadBytes)
            packets.append(packet.payload)
        }
        var out: [Float] = []
        for p in packets.prefix(4) { XCTAssertTrue(dec.decode(p, frames: 480, into: &out)) }
        XCTAssertEqual(out.count, 4 * 960)
        // Packet 4 lost: rebuilt from packet 5's redundancy, then 5 decodes.
        out.removeAll()
        dec.conceal(frames: 480, nextPayload: packets[5], into: &out)
        XCTAssertEqual(out.count, 960)
        XCTAssertTrue(dec.decode(packets[5], frames: 480, into: &out))
        XCTAssertEqual(out.count, 1920)
        // Nothing to rebuild from: plain concealment still yields the frames.
        out.removeAll()
        dec.conceal(frames: 480, nextPayload: nil, into: &out)
        XCTAssertEqual(out.count, 960)
    }

    func testFLACRoundTripAndLoss() throws {
        let block = CodecFactory.framesPerPacket(codec: .flac, sampleRate: 48000, packetMs: 10)
        let enc = try FLACEncoderWrapper(sampleRate: 48000, blockSize: block)
        var inputs: [[Float]] = []
        var packets: [Data] = []
        // The encoder runs one block behind: the first call yields nothing and
        // every later call yields the frame for the block before it.
        for i in 0..<7 {
            let input = tone(frames: block, phase: i * block)
            let packet = input.withUnsafeBufferPointer { enc.encode($0.baseAddress!) }
            if i == 0 {
                XCTAssertNil(packet)
                inputs.append(input)
                continue
            }
            if i < 6 { inputs.append(input) }
            XCTAssertNotNil(packet, "call \(i) produced no packet")
            XCTAssertLessThanOrEqual(packet!.payload.count, FastRouteNet.maxPayloadBytes)
            // A FLAC frame starts with the sync code, no stream header in front.
            XCTAssertEqual(packet!.payload[0], 0xFF)
            XCTAssertEqual(packet!.payload[1] & 0xFC, 0xF8)
            packets.append(packet!.payload)
        }
        XCTAssertEqual(packets.count, 6)
        let dec = try FLACDecoderWrapper(sampleRate: 48000)
        for i in [0, 1, 2, 4, 5] {   // packet 3 never arrives
            var out: [Float] = []
            XCTAssertTrue(dec.decode(packets[i], frames: block, into: &out), "frame \(i) did not decode")
            XCTAssertEqual(out.count, block * 2)
            for (a, b) in zip(inputs[i], out) { XCTAssertEqual(a, b, accuracy: 1.0 / 32000) }
        }
        var gap: [Float] = []
        dec.conceal(frames: block, nextPayload: nil, into: &gap)
        XCTAssertEqual(gap.count, block * 2)
    }

    func testFactoryLimits() {
        XCTAssertEqual(CodecFactory.framesPerPacket(codec: .pcm16, sampleRate: 48000, packetMs: 10), 342)
        XCTAssertEqual(CodecFactory.framesPerPacket(codec: .pcm16, sampleRate: 48000, packetMs: 5), 240)
        XCTAssertEqual(CodecFactory.framesPerPacket(codec: .opus, sampleRate: 48000, packetMs: 20), 960)
    }
}
