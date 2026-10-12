//
//  RingBuffer.swift
//  FastRoute Companion
//
//  A lock-protected ring of interleaved stereo float frames, written by
//  capture or network threads and read by the audio or sender thread. The
//  lock is held only for the copy, which is short enough for the audio thread.
//

import Foundation
import os

final class StereoRingBuffer {
    private var storage: [Float]
    private let capacityFrames: Int
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private var lock = os_unfair_lock()

    init(capacityFrames: Int) {
        self.capacityFrames = max(1, capacityFrames)
        storage = [Float](repeating: 0, count: self.capacityFrames * 2)
    }

    var capacity: Int { capacityFrames }

    var availableFrames: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return count
    }

    func clear() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        readIndex = 0; writeIndex = 0; count = 0
    }

    /// Appends frames, discarding the oldest when full. Returns how many were dropped.
    @discardableResult
    func write(_ frames: UnsafePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        var src = frames
        var n = frameCount
        var dropped = 0
        if n > capacityFrames {
            src += (n - capacityFrames) * 2
            dropped += n - capacityFrames
            n = capacityFrames
        }
        let overflow = count + n - capacityFrames
        if overflow > 0 {
            readIndex = (readIndex + overflow) % capacityFrames
            count -= overflow
            dropped += overflow
        }
        var remaining = n
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - writeIndex)
            storage.withUnsafeMutableBufferPointer { buf in
                (buf.baseAddress! + writeIndex * 2).update(from: src, count: chunk * 2)
            }
            src += chunk * 2
            writeIndex = (writeIndex + chunk) % capacityFrames
            remaining -= chunk
        }
        count += n
        return dropped
    }

    func write(_ frames: [Float]) {
        guard !frames.isEmpty else { return }
        frames.withUnsafeBufferPointer { _ = write($0.baseAddress!, frameCount: $0.count / 2) }
    }

    /// Copies up to `frameCount` frames out, zero filling what is not there.
    /// Returns the number of real frames copied.
    @discardableResult
    func read(into out: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let n = min(frameCount, count)
        var dst = out
        var remaining = n
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - readIndex)
            storage.withUnsafeBufferPointer { buf in
                dst.update(from: buf.baseAddress! + readIndex * 2, count: chunk * 2)
            }
            dst += chunk * 2
            readIndex = (readIndex + chunk) % capacityFrames
            remaining -= chunk
        }
        count -= n
        if n < frameCount { dst.update(repeating: 0, count: (frameCount - n) * 2) }
        return n
    }

    /// Mixes up to `frameCount` frames into `out` with a gain instead of
    /// overwriting it. Returns the number of real frames mixed.
    @discardableResult
    func mix(into out: UnsafeMutablePointer<Float>, frameCount: Int, gain: Float) -> Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let n = min(frameCount, count)
        var dst = out
        var remaining = n
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - readIndex)
            storage.withUnsafeBufferPointer { buf in
                let src = buf.baseAddress! + readIndex * 2
                for i in 0..<(chunk * 2) { dst[i] += src[i] * gain }
            }
            dst += chunk * 2
            readIndex = (readIndex + chunk) % capacityFrames
            remaining -= chunk
        }
        count -= n
        return n
    }

    /// Throws away the oldest `frameCount` frames.
    func skip(_ frameCount: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let n = min(frameCount, count)
        readIndex = (readIndex + n) % capacityFrames
        count -= n
    }
}
