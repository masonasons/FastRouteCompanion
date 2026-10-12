//
//  SampleRateConverter.swift
//  FastRoute Companion
//
//  Turns whatever a capture source delivers (any rate, channel count or
//  layout) into interleaved stereo float at the session rate. Rate conversion
//  is AVAudioConverter's; the channel fold is done here so mono sources come
//  out on both sides and anything wider keeps its first two channels.
//

import Foundation
import AVFoundation

final class SampleRateConverter {
    let inputFormat: AVAudioFormat
    let targetRate: Double
    private let converter: AVAudioConverter?
    private let intermediateFormat: AVAudioFormat
    private var intermediate: AVAudioPCMBuffer
    private var out: [Float] = []

    init(inputFormat: AVAudioFormat, targetRate: Double) {
        self.inputFormat = inputFormat
        self.targetRate = targetRate
        let channels = max(1, inputFormat.channelCount)
        intermediateFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                           channels: channels, interleaved: false)!
        let needsConversion = inputFormat.sampleRate != targetRate || inputFormat.commonFormat != .pcmFormatFloat32 || inputFormat.isInterleaved
        converter = needsConversion ? AVAudioConverter(from: inputFormat, to: intermediateFormat) : nil
        intermediate = AVAudioPCMBuffer(pcmFormat: intermediateFormat, frameCapacity: 8192)!
    }

    /// Converts one capture buffer. The result is valid until the next call.
    func convert(_ input: AVAudioPCMBuffer) -> UnsafeBufferPointer<Float> {
        let source: AVAudioPCMBuffer
        if let converter {
            let expected = AVAudioFrameCount(Double(input.frameLength) * targetRate / inputFormat.sampleRate) + 64
            if intermediate.frameCapacity < expected {
                intermediate = AVAudioPCMBuffer(pcmFormat: intermediateFormat, frameCapacity: expected * 2)!
            }
            intermediate.frameLength = 0
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: intermediate, error: &error) { _, outStatus in
                if consumed { outStatus.pointee = .noDataNow; return nil }
                consumed = true
                outStatus.pointee = .haveData
                return input
            }
            if status == .error { intermediate.frameLength = 0 }
            source = intermediate
        } else {
            source = input
        }
        let n = Int(source.frameLength)
        if out.count < n * 2 { out = [Float](repeating: 0, count: max(n * 2, 4096)) }
        guard n > 0, let channels = source.floatChannelData else { return UnsafeBufferPointer(start: nil, count: 0) }
        let channelCount = Int(source.format.channelCount)
        out.withUnsafeMutableBufferPointer { buf in
            let left = channels[0]
            let right = channelCount > 1 ? channels[1] : channels[0]
            for i in 0..<n {
                buf[2 * i] = left[i]
                buf[2 * i + 1] = right[i]
            }
        }
        return out.withUnsafeBufferPointer { UnsafeBufferPointer(start: $0.baseAddress, count: n * 2) }
    }

    /// Converts a raw buffer list in the input format, as an IO proc delivers.
    func convert(bufferList: UnsafePointer<AudioBufferList>) -> UnsafeBufferPointer<Float> {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: bufferList, deallocator: nil) else {
            return UnsafeBufferPointer(start: nil, count: 0)
        }
        return convert(buffer)
    }
}
