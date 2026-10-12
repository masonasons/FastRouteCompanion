//
//  NetSendRunner.swift
//  FastRoute Companion
//
//  Runs a Net Send block: captures the chosen inputs, mixes them, encodes a
//  packet at a time on a steady clock and sends it where the block says.
//  Over FastRoute it also announces itself twice a second and serves anyone
//  who asks; over VBAN it sends 16 bit PCM to the given address.
//

import Foundation
import AVFoundation
import AppKit

final class NetSendRunner: RunningBlock, UDPPortListener {
    private(set) var block: Block
    var gain: Float

    private var encoder: AudioEncoder?
    private var port: UDPPortHandle?
    private var mic: MicrophoneCapture?
    private var tap: ProcessTapCapture?
    private var micRing: StereoRingBuffer?
    private var tapRing: StereoRingBuffer?
    private var thread: Thread?
    private var running = false

    private var destinationHost: Endpoint?
    private var groupEndpoint: Endpoint?
    private struct Subscriber { var endpoint: Endpoint; var lastSeen: Date }
    private var subscribers: [Endpoint: Subscriber] = [:]
    private let lock = NSLock()

    private var sequence: UInt32 = 0
    private var framePosition: UInt64 = 0
    private var packetsSent: UInt64 = 0
    private var bytesSent: UInt64 = 0
    private var bitrateWindowStart = Date()
    private var bitrateWindowBytes: UInt64 = 0
    private var lastKbps = 0
    private var inputNote = ""
    private(set) var lastError: String?

    init(block: Block) {
        self.block = block
        gain = Float(block.volumePercent) / 100
    }

    private var settings: NetSendSettings { block.netSend }

    // MARK: Lifecycle

    func start() throws {
        let s = settings
        guard !s.inputs.isEmpty else { throw BlockError.configuration("\(block.displayName) has no input. Choose a microphone, system audio or an application.") }
        if s.proto == .fastRoute, s.streamName.trimmingCharacters(in: .whitespaces).isEmpty {
            throw BlockError.configuration("\(block.displayName) has no stream name. A receiver finds it by that name, so it needs one.")
        }

        // Where the packets go.
        switch s.mode {
        case .waitForReceivers:
            if s.proto == .vban { throw BlockError.configuration("VBAN needs an address to send to: a host name, an address or a multicast group.") }
        case .group(let g):
            groupEndpoint = Endpoint(address: g, port: s.effectivePort)
        case .oneHost(let host):
            let address = try UDPSocket.resolve(host)
            if address.isMulticastIPv4 { groupEndpoint = Endpoint(address: address, port: s.effectivePort) }
            else { destinationHost = Endpoint(address: address, port: s.effectivePort) }
        }

        // The encoder.
        let codec: NetCodec = s.proto == .vban ? .pcm16 : s.codec
        var packetMs = s.packetMs
        if s.proto == .vban {
            packetMs = min(packetMs, Double(VBAN.maxSamplesPerFrame) * 1000 / Double(sessionSampleRate))
        }
        let enc = try CodecFactory.makeEncoder(codec: codec, sampleRate: sessionSampleRate, packetMs: packetMs, opus: s.opus)
        encoder = enc

        // The socket: this machine's port, so receivers can ask, with a
        // fallback to any port when something else already has it.
        do {
            port = try UDPPortHub.shared.acquire(port: s.effectivePort)
        } catch {
            if case .waitForReceivers = s.mode { throw error }
            port = try UDPPortHub.shared.acquire(port: 0)
        }
        port?.setMulticastTTL(s.ttl)
        port?.addListener(self)

        // Inputs.
        try startInputs()

        running = true
        Log.net.info("Net Send \(self.block.displayName, privacy: .public): \(self.statusText, privacy: .public)")
        let t = Thread { [weak self] in self?.sendLoop() }
        t.name = "net-send"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        running = false
        thread = nil
        mic?.stop(); mic = nil
        tap?.stop(); tap = nil
        if let port {
            port.removeListener(self)
            UDPPortHub.shared.release(port)
        }
        port = nil
        encoder = nil
    }

    private func startInputs() throws {
        let inputs = settings.inputs
        var notes: [String] = []
        let capacity = Int(sessionSampleRate)   // a second of lead at most
        if let uid = inputs.microphoneUID {
            let deviceID: AudioObjectID?
            if uid == InputSelection.defaultDeviceUID { deviceID = nil }
            else if let d = AudioDevices.device(uid: uid) { deviceID = d.id }
            else { throw BlockError.configuration("The input device chosen for \(block.displayName) is not connected.") }
            let ring = StereoRingBuffer(capacityFrames: capacity)
            micRing = ring
            let capture = MicrophoneCapture(deviceID: deviceID, targetRate: Double(sessionSampleRate)) { frames, count in
                ring.write(frames, frameCount: count)
            }
            try capture.start()
            mic = capture
        }
        if inputs.systemAudio || !inputs.applicationBundleIDs.isEmpty {
            let source: ProcessTapCapture.Source
            if inputs.systemAudio {
                source = .systemAudio
            } else {
                var ids: [AudioObjectID] = []
                var missing: [String] = []
                for bundleID in inputs.applicationBundleIDs {
                    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    var found = false
                    for app in apps {
                        if let obj = AudioDevices.processObject(forPID: app.processIdentifier) { ids.append(obj); found = true }
                    }
                    if !found { missing.append(bundleID) }
                }
                if !missing.isEmpty {
                    let names = missing.map { $0.split(separator: ".").last.map(String.init) ?? $0 }
                    notes.append(ids.isEmpty ? "none of the chosen applications is running or has used audio"
                                             : "not running: \(names.joined(separator: ", "))")
                }
                if ids.isEmpty && !missing.isEmpty {
                    if mic == nil { throw BlockError.configuration("None of the applications chosen for \(block.displayName) is running, or none has played audio yet.") }
                    inputNote = notes.joined(separator: "; ")
                    return
                }
                source = .processes(ids)
            }
            let ring = StereoRingBuffer(capacityFrames: capacity)
            tapRing = ring
            let capture = ProcessTapCapture(source: source, targetRate: Double(sessionSampleRate)) { frames, count in
                ring.write(frames, frameCount: count)
            }
            do {
                try capture.start()
                tap = capture
            } catch {
                mic?.stop(); mic = nil
                throw error
            }
        }
        inputNote = notes.joined(separator: "; ")
    }

    // MARK: Sending

    private func sendLoop() {
        guard let encoder, let port else { return }
        let fpp = encoder.framesPerPacket
        let packetInterval = Double(fpp) / Double(sessionSampleRate)
        var mix = [Float](repeating: 0, count: fpp * 2)
        let rings = [micRing, tapRing].compactMap { $0 }
        let leadFrames = fpp * 2
        let maxFrames = fpp * 8

        // Let the inputs get ahead by two packets before the clock starts.
        let waitUntil = Date().addingTimeInterval(0.5)
        while running && Date() < waitUntil && rings.contains(where: { $0.availableFrames < leadFrames }) {
            Thread.sleep(forTimeInterval: 0.002)
        }

        let start = Date()
        var packetsDue: Double = 0
        var lastBeacon = Date.distantPast
        var lastExpire = Date()
        let isVBAN = settings.proto == .vban
        var vbanCounter: UInt32 = 0

        while running {
            let elapsed = Date().timeIntervalSince(start)
            packetsDue = elapsed / packetInterval
            while running && Double(packetsSent) < packetsDue {
                // Mix the inputs. A ring that has run ahead is trimmed back.
                mix.withUnsafeMutableBufferPointer { buf in
                    buf.update(repeating: 0)
                    for ring in rings {
                        let excess = ring.availableFrames - maxFrames
                        if excess > 0 { ring.skip(excess) }
                        ring.mix(into: buf.baseAddress!, frameCount: fpp, gain: gain)
                    }
                }
                let packet: EncodedPacket? = mix.withUnsafeBufferPointer { encoder.encode($0.baseAddress!) }
                guard let packet else { packetsSent += 1; continue }
                let datagram: Data
                if isVBAN {
                    var header = VBAN.Header()
                    header.proto = .audio
                    header.sampleRateIndex = VBAN.rateIndex(for: sessionSampleRate) ?? 3
                    header.samplesPerFrame = packet.frames
                    header.channels = 2
                    header.dataType = .int16
                    header.streamName = settings.streamName
                    header.frameCounter = vbanCounter
                    vbanCounter &+= 1
                    var d = header.encode()
                    d.append(packet.payload)
                    datagram = d
                } else {
                    let header = DataPacketHeader(codec: encoder.codec, sampleRate: encoder.sampleRate,
                                                  streamID: settings.streamID, sequence: sequence,
                                                  framePosition: framePosition, frames: UInt16(packet.frames),
                                                  payloadLength: UInt16(packet.payload.count))
                    datagram = header.encode(payload: packet.payload)
                    sequence &+= 1
                    framePosition &+= UInt64(packet.frames)
                }
                deliver(datagram, via: port)
                packetsSent += 1
                bytesSent += UInt64(datagram.count)
                bitrateWindowBytes += UInt64(datagram.count)
            }

            let now = Date()
            if !isVBAN && now.timeIntervalSince(lastBeacon) >= FastRouteNet.beaconInterval {
                lastBeacon = now
                port.send(beacon().encode(), to: Endpoint(address: FastRouteNet.beaconGroup, port: FastRouteNet.beaconPort))
            }
            if now.timeIntervalSince(lastExpire) >= 1 {
                lastExpire = now
                lock.lock()
                subscribers = subscribers.filter { now.timeIntervalSince($0.value.lastSeen) < FastRouteNet.subscriberTimeout }
                lock.unlock()
                let window = now.timeIntervalSince(bitrateWindowStart)
                if window >= 1 {
                    lastKbps = Int(Double(bitrateWindowBytes) * 8 / window / 1000)
                    bitrateWindowBytes = 0
                    bitrateWindowStart = now
                }
            }

            let nextDue = start.addingTimeInterval(Double(packetsSent) * packetInterval)
            let sleep = nextDue.timeIntervalSinceNow
            if sleep > 0.0005 { Thread.sleep(forTimeInterval: min(sleep, 0.02)) }
        }
    }

    private func deliver(_ datagram: Data, via port: UDPPortHandle) {
        if let groupEndpoint {
            if port.send(datagram, to: groupEndpoint) < 0 { lastError = "the network refused a packet for \(groupEndpoint)" }
        } else if let destinationHost {
            if port.send(datagram, to: destinationHost) < 0 { lastError = "the network refused a packet for \(destinationHost)" }
        } else {
            lock.lock()
            let targets = subscribers.keys
            lock.unlock()
            for t in targets { port.send(datagram, to: t) }
        }
    }

    private func beacon() -> Beacon {
        let s = settings
        var group: UInt32 = 0
        if let groupEndpoint { group = groupEndpoint.address }
        return Beacon(codec: encoder?.codec ?? s.codec, streamID: s.streamID, group: group,
                      port: port?.port ?? s.effectivePort,
                      framesPerPacket: UInt16(encoder?.framesPerPacket ?? 0),
                      sampleRate: encoder?.sampleRate ?? sessionSampleRate,
                      streamName: s.streamName, hostName: UDPSocket.localHostName)
    }

    // MARK: UDPPortListener

    func port(_ port: UDPPortHandle, didReceive data: Data, from endpoint: Endpoint) {
        if let request = SubscribeRequest.decode(data) {
            if request.streamID != 0 && request.streamID != settings.streamID { return }
            if !request.streamName.isEmpty && request.streamName != FastRouteNet.wireName(settings.streamName) { return }
            lock.lock()
            let isNew = subscribers[endpoint] == nil
            subscribers[endpoint] = Subscriber(endpoint: endpoint, lastSeen: Date())
            lock.unlock()
            if isNew { Log.net.info("Net Send \(self.block.displayName, privacy: .public): receiver \(endpoint.description, privacy: .public) asked") }
            if request.wantsBeacon { port.send(beacon().encode(), to: endpoint) }
        } else if let header = VBAN.Header.decode(data), header.proto == .service,
                  header.serviceType == VBAN.serviceTypeIdentification, header.serviceFunction & VBAN.serviceFunctionReply == 0 {
            let reply = VBAN.pingReply(to: header, streamName: settings.streamName,
                                       body: DiscoveryService.pingReplyBody(isReceiver: false, isSender: true))
            port.send(reply, to: endpoint)
        }
    }

    func portTick(_ port: UDPPortHandle) {}

    // MARK: Status

    var statusText: String {
        let s = settings
        let codecName = encoder?.codec.shortName ?? s.codec.shortName
        let where_: String
        if let groupEndpoint { where_ = "to the group \(groupEndpoint)" }
        else if let destinationHost { where_ = "to \(destinationHost)" }
        else {
            lock.lock(); let n = subscribers.count; lock.unlock()
            where_ = n == 0 ? "waiting for a receiver to ask on port \(port?.port ?? s.effectivePort)" : "to \(n) receiver\(n == 1 ? "" : "s")"
        }
        var line = "\(block.displayName) \"\(s.streamName)\" \(codecName) over \(s.proto.displayName) \(where_): \(packetsSent) packets, \(lastKbps) kbps"
        if !inputNote.isEmpty { line += " (\(inputNote))" }
        if let lastError { line += "; \(lastError)" }
        return line
    }
}
