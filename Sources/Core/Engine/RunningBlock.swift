//
//  RunningBlock.swift
//  FastRoute Companion
//
//  A block that has been started: it owns sockets, capture or playback, and
//  reports on itself for the status field.
//

import Foundation

protocol RunningBlock: AnyObject {
    var block: Block { get }
    func start() throws
    func stop()
    /// One line on what the block is doing, for the status field.
    var statusText: String { get }
    /// Gain applied to the audio, 0...2.
    var gain: Float { get set }
}

enum BlockError: Error, LocalizedError {
    case configuration(String)

    var errorDescription: String? {
        switch self {
        case .configuration(let s): return s
        }
    }
}

/// The rate every session runs at. Opus needs 48 kHz and the rest are happy there.
let sessionSampleRate: UInt32 = 48000
