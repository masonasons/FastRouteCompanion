//
//  Session.swift
//  FastRoute Companion
//
//  What gets saved: sessions, their blocks, and each block's settings.
//  Mirrors FastRoute's own model where the two overlap, so a session here
//  reads like one there.
//

import Foundation

struct Session: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var blocks: [Block] = []
    var autoRun = false
}

enum BlockKind: String, Codable, CaseIterable {
    case netSend
    case netReceive

    var displayName: String {
        switch self {
        case .netSend: return "Net Send"
        case .netReceive: return "Net Receive"
        }
    }
    var summary: String {
        switch self {
        case .netSend: return "Sends audio from this Mac to another computer, over FastRoute or VBAN."
        case .netReceive: return "Plays audio arriving from another computer on an output device."
        }
    }
}

struct Block: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: BlockKind
    var customName: String?
    var enabled = true
    /// 0...200 percent.
    var volumePercent = 100
    var netSend = NetSendSettings()
    var netReceive = NetReceiveSettings()

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        return kind.displayName
    }

    static func new(kind: BlockKind) -> Block {
        var b = Block(kind: kind)
        if kind == .netSend { b.netSend.streamID = UInt32.random(in: 1...UInt32.max) }
        return b
    }
}

struct InputSelection: Codable, Equatable {
    /// The UID of the input device to capture, "default" for the system
    /// default, or nil for no device.
    var microphoneUID: String? = nil
    var systemAudio = false
    var applicationBundleIDs: [String] = []

    static let defaultDeviceUID = "default"

    var isEmpty: Bool { microphoneUID == nil && !systemAudio && applicationBundleIDs.isEmpty }

    var summary: String {
        var parts: [String] = []
        if let uid = microphoneUID {
            if uid == InputSelection.defaultDeviceUID { parts.append("default input") }
            else { parts.append(AudioDevices.device(uid: uid)?.name ?? "input device") }
        }
        if systemAudio { parts.append("system audio") }
        if !applicationBundleIDs.isEmpty {
            parts.append(applicationBundleIDs.count == 1 ? "1 application" : "\(applicationBundleIDs.count) applications")
        }
        return parts.isEmpty ? "no input" : parts.joined(separator: ", ")
    }
}

struct NetSendSettings: Codable, Equatable {
    var proto: NetProtocol = .fastRoute
    var streamName = "Stream1"
    /// Blank waits for receivers to ask; a group address multicasts; a host
    /// name or address pushes to that one machine.
    var address = ""
    var port: UInt16 = FastRouteNet.defaultPort
    var codec: NetCodec = .pcm16
    var packetMs: Double = 10
    /// Hops a multicast packet may cross.
    var ttl = 1
    var opus = OpusSettings()
    /// Identifies this stream to receivers across restarts.
    var streamID: UInt32 = 0
    var inputs = InputSelection()

    enum Mode {
        case waitForReceivers
        case group(UInt32)
        case oneHost(String)
    }

    var mode: Mode {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .waitForReceivers }
        if let literal = UInt32(ipv4String: trimmed), literal.isMulticastIPv4 { return .group(literal) }
        return .oneHost(trimmed)
    }

    var effectivePort: UInt16 {
        if port != 0 { return port }
        return proto == .vban ? VBAN.defaultPort : FastRouteNet.defaultPort
    }
}

struct NetReceiveSettings: Codable, Equatable {
    var proto: NetProtocol = .fastRoute
    /// The stream wanted by name; blank takes whatever arrives.
    var streamName = ""
    /// The sending machine to ask; blank joins the group instead.
    var host = ""
    /// The group joined when no host is named. 0 means the usual one.
    var group: UInt32 = 0
    var port: UInt16 = FastRouteNet.defaultPort
    var bufferMs = 60
    /// The stream id followed once a sender was chosen from the list; 0 for any.
    var sourceID: UInt32 = 0
    /// The UID of the output device, or nil for the system default.
    var outputDeviceUID: String? = nil

    var effectivePort: UInt16 {
        if port != 0 { return port }
        return proto == .vban ? VBAN.defaultPort : FastRouteNet.defaultPort
    }
    var effectiveGroup: UInt32 { group == 0 ? FastRouteNet.defaultGroup : group }
    var asksAHost: Bool { !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
