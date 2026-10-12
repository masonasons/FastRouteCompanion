//
//  MicrophoneCapture.swift
//  FastRoute Companion
//
//  Captures an input device through AVAudioEngine and delivers interleaved
//  stereo float at the session rate.
//

import Foundation
import AVFoundation
import CoreAudio

final class MicrophoneCapture {
    typealias Sink = (UnsafePointer<Float>, Int) -> Void

    private let engine = AVAudioEngine()
    private let deviceID: AudioObjectID?
    private let targetRate: Double
    private let sink: Sink
    private var converter: SampleRateConverter?
    private(set) var isRunning = false

    init(deviceID: AudioObjectID?, targetRate: Double, sink: @escaping Sink) {
        self.deviceID = deviceID
        self.targetRate = targetRate
        self.sink = sink
    }

    func start() throws {
        let input = engine.inputNode
        if var id = deviceID, let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioObjectID>.size))
            guard status == noErr else { throw CaptureError.device("The input device could not be opened (\(status)).") }
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.device("The input device has no usable format.")
        }
        let converter = SampleRateConverter(inputFormat: format, targetRate: targetRate)
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let frames = converter.convert(buffer)
            if frames.count > 0 { self.sink(frames.baseAddress!, frames.count / 2) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.device("The input device could not be started: \(error.localizedDescription)")
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}

enum CaptureError: Error, LocalizedError {
    case device(String)
    case tap(String)
    case permission(String)

    var errorDescription: String? {
        switch self {
        case .device(let s), .tap(let s), .permission(let s): return s
        }
    }
}
