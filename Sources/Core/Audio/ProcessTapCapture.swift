//
//  ProcessTapCapture.swift
//  FastRoute Companion
//
//  Captures system audio or the output of chosen applications with a Core
//  Audio process tap (macOS 14.2 and later). The tap is wrapped in a private
//  aggregate device whose IO proc hands the mixed audio over, converted to
//  interleaved stereo float at the session rate.
//

import Foundation
import AVFoundation
import CoreAudio

final class ProcessTapCapture {
    typealias Sink = (UnsafePointer<Float>, Int) -> Void

    enum Source {
        /// Everything playing, except this app, so a Net Receive block on the
        /// same Mac cannot feed back into a Net Send block.
        case systemAudio
        case processes([AudioObjectID])
    }

    private let source: Source
    private let targetRate: Double
    private let sink: Sink
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: SampleRateConverter?
    private(set) var isRunning = false

    init(source: Source, targetRate: Double, sink: @escaping Sink) {
        self.source = source
        self.targetRate = targetRate
        self.sink = sink
    }

    func start() throws {
        let description: CATapDescription
        switch source {
        case .systemAudio:
            var excluded: [AudioObjectID] = []
            if let own = AudioDevices.processObject(forPID: ProcessInfo.processInfo.processIdentifier) { excluded.append(own) }
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        case .processes(let ids):
            guard !ids.isEmpty else { throw CaptureError.tap("None of the chosen applications is running.") }
            description = CATapDescription(stereoMixdownOfProcesses: ids)
        }
        description.uuid = UUID()
        description.name = "FastRoute Companion"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            throw CaptureError.tap("The audio tap could not be created (\(status)). Check that FastRoute Companion is allowed to record system audio in System Settings, Privacy & Security, Screen & System Audio Recording.")
        }
        tapID = tap

        guard let asbd: AudioStreamBasicDescription = AudioDevices.property(tapID, kAudioTapPropertyFormat),
              let format = AVAudioFormat(streamDescription: withUnsafePointer(to: asbd) { $0 }) else {
            cleanup()
            throw CaptureError.tap("The audio tap has no usable format.")
        }
        converter = SampleRateConverter(inputFormat: format, targetRate: targetRate)

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FastRoute Companion Tap",
            kAudioAggregateDeviceUIDKey: "me.masonasons.FastRouteCompanion.tap.\(description.uuid.uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else {
            cleanup()
            throw CaptureError.tap("The capture device could not be created (\(status)).")
        }
        aggregateID = aggregate

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil) { [weak self] _, inputData, _, _, _ in
            guard let self, let converter = self.converter else { return }
            let frames = converter.convert(bufferList: inputData)
            if frames.count > 0 { self.sink(frames.baseAddress!, frames.count / 2) }
        }
        guard status == noErr, let proc else {
            cleanup()
            throw CaptureError.tap("The capture device would not accept an IO proc (\(status)).")
        }
        procID = proc
        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else {
            cleanup()
            throw CaptureError.tap("The capture device could not be started (\(status)).")
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { cleanup(); return }
        isRunning = false
        cleanup()
    }

    private func cleanup() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { cleanup() }
}
