//
//  BufferTests.swift
//  FastRoute Companion
//
//  The ring buffer and the jitter buffer keep audio in order, fill gaps,
//  and only start once the buffer is full.
//

import XCTest

/// A decoder whose "audio" is the packet's sequence number, so order is visible.
private final class TagDecoder: AudioDecoder {
    let codec: NetCodec = .pcm16
    func decode(_ payload: Data, frames: Int, into out: inout [Float]) -> Bool {
        let tag = Float(payload[0])
        out.append(contentsOf: repeatElement(tag, count: frames * 2))
        return true
    }
    func conceal(frames: Int, nextPayload: Data?, into out: inout [Float]) {
        out.append(contentsOf: repeatElement(-1, count: frames * 2))
    }
}

final class BufferTests: XCTestCase {
    func testRingBufferWrapAndOverflow() {
        let ring = StereoRingBuffer(capacityFrames: 8)
        let a: [Float] = (0..<12).map(Float.init)       // 6 frames
        a.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, frameCount: 6) }
        XCTAssertEqual(ring.availableFrames, 6)
        var out = [Float](repeating: 99, count: 8)
        out.withUnsafeMutableBufferPointer { XCTAssertEqual(ring.read(into: $0.baseAddress!, frameCount: 4), 4) }
        XCTAssertEqual(Array(out.prefix(8)), [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(ring.availableFrames, 2)
        // Write 8 more frames: wraps around and drops the oldest 2.
        let b: [Float] = (100..<116).map(Float.init)
        var dropped = 0
        b.withUnsafeBufferPointer { dropped = ring.write($0.baseAddress!, frameCount: 8) }
        XCTAssertEqual(dropped, 2)
        XCTAssertEqual(ring.availableFrames, 8)
        var all = [Float](repeating: 0, count: 16)
        all.withUnsafeMutableBufferPointer { XCTAssertEqual(ring.read(into: $0.baseAddress!, frameCount: 8), 8) }
        XCTAssertEqual(all, b)
        // Reading from empty zero-fills.
        all.withUnsafeMutableBufferPointer { XCTAssertEqual(ring.read(into: $0.baseAddress!, frameCount: 2), 0) }
        XCTAssertEqual(Array(all.prefix(4)), [0, 0, 0, 0])
    }

    func testJitterBufferOrdersAndConceals() {
        let jb = JitterBuffer(sampleRate: 1000, bufferMs: 40, decoder: TagDecoder())   // target 40 frames
        let frames = 10
        func push(_ seq: UInt32) { jb.push(sequence: seq, frames: frames, payload: Data([UInt8(seq)])) }
        var out = [Float](repeating: 0, count: frames * 2)
        func pull() -> Float {
            out.withUnsafeMutableBufferPointer { jb.pull(into: $0.baseAddress!, frameCount: frames) }
            return out[0]
        }
        // Not primed until the buffer holds 40 frames: silence until then.
        push(0); push(1); push(2)
        XCTAssertEqual(pull(), 0)
        push(3)
        XCTAssertEqual(jb.bufferedMs, 40)
        // Out of order: 5 before 4.
        push(5); push(4)
        XCTAssertEqual(pull(), 0)
        XCTAssertEqual(pull(), 1)
        XCTAssertEqual(pull(), 2)
        XCTAssertEqual(pull(), 3)
        XCTAssertEqual(pull(), 4)
        XCTAssertEqual(pull(), 5)
        XCTAssertEqual(jb.stats.outOfOrder, 1)
        XCTAssertEqual(jb.stats.lost, 0)
        // 6 lost; 7 and 8 arrive and are held, then the ring runs low and 6 is concealed.
        push(7); push(8)
        _ = pull()   // underrun, unprimed again
        jb.tick()
        XCTAssertEqual(jb.stats.lost, 1)
        // A duplicate and a late packet are counted, not played.
        push(7)
        push(2)
        XCTAssertEqual(jb.stats.duplicates + jb.stats.late, 2)
    }
}
