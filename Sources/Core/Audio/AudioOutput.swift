//
//  AudioOutput.swift
//  FastRoute Companion
//
//  Plays interleaved stereo float at a given rate to a chosen output device
//  through AVAudioEngine, which converts to whatever rate the device runs at.
//  Audio is pulled from a callback on the render thread.
//

import Foundation
import AVFoundation
import CoreAudio

final class AudioOutput {
    /// Fills `frameCount` interleaved stereo frames into `out`.
    typealias Puller = (UnsafeMutablePointer<Float>, Int) -> Void

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let deviceID: AudioObjectID?
    private let sampleRate: Double
    private let puller: Puller
    private var scratch = [Float](repeating: 0, count: 8192)
    private(set) var isRunning = false

    init(deviceID: AudioObjectID?, sampleRate: Double, puller: @escaping Puller) {
        self.deviceID = deviceID
        self.sampleRate = sampleRate
        self.puller = puller
    }

    func start() throws {
        let output = engine.outputNode
        if var id = deviceID, let unit = output.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioObjectID>.size))
            guard status == noErr else { throw CaptureError.device("The output device could not be opened (\(status)).") }
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList -> OSStatus in
            guard let self else { return noErr }
            let n = Int(frameCount)
            let list = UnsafeMutableAudioBufferListPointer(bufferList)
            guard list.count >= 2, let left = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            if self.scratch.count < n * 2 { self.scratch = [Float](repeating: 0, count: n * 2) }
            self.scratch.withUnsafeMutableBufferPointer { buf in
                self.puller(buf.baseAddress!, n)
                for i in 0..<n {
                    left[i] = buf[2 * i]
                    right[i] = buf[2 * i + 1]
                }
            }
            return noErr
        }
        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: output, format: nil)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.detach(node)
            sourceNode = nil
            throw CaptureError.device("The output device could not be started: \(error.localizedDescription)")
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        isRunning = false
    }
}
