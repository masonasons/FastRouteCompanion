//
//  JitterBuffer.swift
//  FastRoute Companion
//
//  Holds arriving packets, plays them in sequence order, and stands in for the
//  ones that never come. A packet that is missing is waited for until half the
//  buffer has passed, which is most of what "late" means on a real link; then
//  it is concealed, using the packet after the gap when the codec can rebuild
//  from it. Decoded audio goes into a ring the output pulls from, and playback
//  does not start until the ring holds the configured buffer.
//

import Foundation

struct JitterStats {
    var received = 0
    var lost = 0
    var outOfOrder = 0
    var late = 0
    var duplicates = 0
    var underruns = 0
    var dropped = 0
    var maxHoldMs: Double = 0

    var lossPercent: Double {
        let total = received + lost
        return total == 0 ? 0 : Double(lost) * 100 / Double(total)
    }
}

final class JitterBuffer {
    let sampleRate: Int
    let targetFrames: Int
    private let decoder: AudioDecoder
    private let ring: StereoRingBuffer
    private let lock = NSLock()

    private struct Pending {
        let payload: Data
        let frames: Int
        let arrived: Date
    }
    private var pending: [UInt32: Pending] = [:]
    private var nextSequence: UInt32 = 0
    private var started = false
    private var lastFrames = 480
    private var primed = false
    private var decoded: [Float] = []
    private(set) var stats = JitterStats()

    init(sampleRate: Int, bufferMs: Int, decoder: AudioDecoder) {
        self.sampleRate = sampleRate
        self.decoder = decoder
        targetFrames = max(1, sampleRate * max(10, bufferMs) / 1000)
        ring = StereoRingBuffer(capacityFrames: max(targetFrames * 4, sampleRate / 2))
    }

    var bufferedMs: Double { Double(ring.availableFrames) * 1000 / Double(sampleRate) }

    // MARK: Network side

    func push(sequence: UInt32, frames: Int, payload: Data) {
        lock.lock(); defer { lock.unlock() }
        stats.received += 1
        if frames > 0 { lastFrames = frames }
        if !started {
            started = true
            nextSequence = sequence
        }
        let delta = Int32(bitPattern: sequence &- nextSequence)
        if delta == 0 {
            emit(payload: payload, frames: frames)
            nextSequence &+= 1
            drainPending()
        } else if delta < 0 {
            if delta > -1000 {
                stats.late += 1
            } else {
                // A new stream, or the sender restarted: follow it.
                pending.removeAll()
                nextSequence = sequence
                emit(payload: payload, frames: frames)
                nextSequence &+= 1
            }
        } else {
            if pending[sequence] != nil {
                stats.duplicates += 1
            } else {
                stats.outOfOrder += 1
                pending[sequence] = Pending(payload: payload, frames: frames, arrived: Date())
                if delta > 2000 {
                    // Far ahead: the sender jumped. Start over from here.
                    pending.removeAll()
                    nextSequence = sequence
                    emit(payload: payload, frames: frames)
                    nextSequence &+= 1
                }
            }
        }
        service()
    }

    /// Fills gaps that have waited long enough. Called on every push and on
    /// the port's tick, so a stall still gets concealment.
    func tick() {
        lock.lock(); defer { lock.unlock() }
        service()
    }

    private func service() {
        guard started, !pending.isEmpty else { return }
        let halfBuffer = Double(targetFrames) / Double(sampleRate) / 2
        let now = Date()
        while let oldest = pending.keys.min(by: { Int32(bitPattern: $0 &- nextSequence) < Int32(bitPattern: $1 &- nextSequence) }) {
            guard let entry = pending[oldest] else { break }
            let ringLow = ring.availableFrames < targetFrames / 2
            let waited = now.timeIntervalSince(entry.arrived)
            if waited < halfBuffer && !ringLow && pending.count < 64 { break }
            stats.maxHoldMs = max(stats.maxHoldMs, waited * 1000)
            // Conceal everything between nextSequence and the oldest held packet.
            var missing = Int32(bitPattern: oldest &- nextSequence)
            while missing > 0 {
                let next: Data? = missing == 1 ? entry.payload : nil
                decoded.removeAll(keepingCapacity: true)
                decoder.conceal(frames: lastFrames, nextPayload: next, into: &decoded)
                ring.write(decoded)
                stats.lost += 1
                nextSequence &+= 1
                missing -= 1
            }
            drainPending()
        }
    }

    private func drainPending() {
        while let entry = pending.removeValue(forKey: nextSequence) {
            emit(payload: entry.payload, frames: entry.frames)
            nextSequence &+= 1
        }
    }

    private func emit(payload: Data, frames: Int) {
        decoded.removeAll(keepingCapacity: true)
        if !decoder.decode(payload, frames: frames, into: &decoded) {
            decoded.removeAll(keepingCapacity: true)
            decoder.conceal(frames: frames, nextPayload: nil, into: &decoded)
        }
        ring.write(decoded)
        // Keep latency from creeping up: anything beyond twice the buffer goes.
        let excess = ring.availableFrames - (targetFrames * 2 + frames)
        if excess > 0 {
            ring.skip(excess)
            stats.dropped += 1
        }
    }

    // MARK: Audio side

    func pull(into out: UnsafeMutablePointer<Float>, frameCount: Int) {
        if !primed {
            if ring.availableFrames >= targetFrames {
                primed = true
            } else {
                out.update(repeating: 0, count: frameCount * 2)
                return
            }
        }
        let got = ring.read(into: out, frameCount: frameCount)
        if got < frameCount {
            primed = false
            lock.lock(); stats.underruns += 1; lock.unlock()
        }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll()
        started = false
        primed = false
        ring.clear()
    }
}
