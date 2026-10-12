//
//  AudioDevices.swift
//  FastRoute Companion
//
//  Core Audio device and process enumeration: the input and output devices a
//  block can pick, and the processes whose audio a tap can capture.
//

import Foundation
import CoreAudio
import AppKit

struct AudioDevice: Hashable, Identifiable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
}

struct AudioProcess: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningOutput: Bool
}

enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func all() -> [AudioDevice] {
        guard let ids: [AudioObjectID] = propertyArray(system, kAudioHardwarePropertyDevices) else { return [] }
        return ids.compactMap { id in
            guard let uid: String = propertyString(id, kAudioDevicePropertyDeviceUID),
                  let name: String = propertyString(id, kAudioObjectPropertyName) else { return nil }
            let inputs = channelCount(id, scope: kAudioObjectPropertyScopeInput)
            let outputs = channelCount(id, scope: kAudioObjectPropertyScopeOutput)
            guard inputs > 0 || outputs > 0 else { return nil }
            return AudioDevice(id: id, uid: uid, name: name, inputChannels: inputs, outputChannels: outputs)
        }
    }

    static func inputDevices() -> [AudioDevice] { all().filter { $0.inputChannels > 0 } }
    static func outputDevices() -> [AudioDevice] { all().filter { $0.outputChannels > 0 } }

    static func defaultInputID() -> AudioObjectID? {
        let id: AudioObjectID? = property(system, kAudioHardwarePropertyDefaultInputDevice)
        return id == kAudioObjectUnknown ? nil : id
    }

    static func defaultOutputID() -> AudioObjectID? {
        let id: AudioObjectID? = property(system, kAudioHardwarePropertyDefaultOutputDevice)
        return id == kAudioObjectUnknown ? nil : id
    }

    static func device(uid: String) -> AudioDevice? { all().first { $0.uid == uid } }

    static func name(of id: AudioObjectID) -> String {
        propertyString(id, kAudioObjectPropertyName) ?? "Device \(id)"
    }

    static func nominalSampleRate(_ id: AudioObjectID) -> Double {
        let rate: Double? = property(id, kAudioDevicePropertyNominalSampleRate)
        return rate ?? 48000
    }

    // MARK: Processes

    /// Every process Core Audio knows about, which is every process that has
    /// opened an audio device, playing or not.
    static func processes() -> [AudioProcess] {
        guard let ids: [AudioObjectID] = propertyArray(system, kAudioHardwarePropertyProcessObjectList) else { return [] }
        return ids.compactMap { id in
            let pid: pid_t? = property(id, kAudioProcessPropertyPID)
            guard let pid else { return nil }
            let bundle: String = propertyString(id, kAudioProcessPropertyBundleID) ?? ""
            let running: UInt32? = property(id, kAudioProcessPropertyIsRunningOutput)
            return AudioProcess(objectID: id, pid: pid, bundleID: bundle, isRunningOutput: (running ?? 0) != 0)
        }
    }

    /// The Core Audio object for a process id, if that process has used audio.
    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var input = pid
        var output = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &input) { inPtr in
            AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), inPtr, &size, &output)
        }
        guard status == noErr, output != kAudioObjectUnknown else { return nil }
        return output
    }

    // MARK: Property helpers

    private static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func property<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return nil }
        return raw.load(as: T.self)
    }

    static func propertyArray<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<T>.size
        guard count > 0 else { return [] }
        var result = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = 0 }
        result.reserveCapacity(count)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return nil }
        let buffer = UnsafeBufferPointer(start: raw.assumingMemoryBound(to: T.self), count: Int(size) / MemoryLayout<T>.size)
        result = Array(buffer)
        return result
    }

    static func propertyString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }
}

/// A running application that can be captured, matched to its audio process.
struct CapturableApplication: Hashable {
    let bundleID: String
    let name: String
    let pid: pid_t
    let isPlayingAudio: Bool

    /// Regular applications first, each matched against Core Audio's process
    /// list so the ones playing right now can be marked.
    static func running() -> [CapturableApplication] {
        let processes = AudioDevices.processes()
        var playingByPID: [pid_t: Bool] = [:]
        for p in processes { playingByPID[p.pid] = p.isRunningOutput }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var seen = Set<String>()
        var apps: [CapturableApplication] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, app.processIdentifier != ownPID,
                  let bundleID = app.bundleIdentifier, !bundleID.isEmpty, !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            apps.append(CapturableApplication(bundleID: bundleID, name: app.localizedName ?? bundleID,
                                              pid: app.processIdentifier, isPlayingAudio: playingByPID[app.processIdentifier] ?? false))
        }
        // Background processes that are playing audio are worth listing too.
        for p in processes where p.isRunningOutput && !p.bundleID.isEmpty && !seen.contains(p.bundleID) {
            guard p.pid != ownPID else { continue }
            seen.insert(p.bundleID)
            let name = NSRunningApplication(processIdentifier: p.pid)?.localizedName ?? p.bundleID
            apps.append(CapturableApplication(bundleID: p.bundleID, name: name, pid: p.pid, isPlayingAudio: true))
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
