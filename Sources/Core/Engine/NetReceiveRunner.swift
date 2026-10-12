//
//  NetReceiveRunner.swift
//  FastRoute Companion
//
//  Runs a Net Receive block: joins a group or asks a sender, takes the stream
//  apart, buffers it, decodes it and plays it on the chosen output device.
//  Speaks FastRoute or VBAN depending on the block.
//

import Foundation
import AVFoundation

final class NetReceiveRunner: RunningBlock, UDPPortListener {
    private(set) var block: Block
    var gain: Float

    private var port: UDPPortHandle?
    private var askEndpoint: Endpoint?
    private var lastAsk = Date.distantPast
    private var startedAt = Date()
    private var lastPacket: Date?
    private var latchedStreamID: UInt32 = 0
    private var senderBeacon: Beacon?
    private var vbanSender: Endpoint?

    private var decoder: AudioDecoder?
    private var jitter: JitterBuffer?
    private var output: AudioOutput?
    private var streamCodec: NetCodec?
    private var streamRate: UInt32 = 0
    private var vbanType: VBAN.DataType?
    private var vbanChannels = 0
    private let lock = NSLock()
    private var scratch: [Float] = []
    private(set) var lastError: String?
    private var outputDeviceName = "the default output"

    init(block: Block) {
        self.block = block
        gain = Float(block.volumePercent) / 100
    }

    private var settings: NetReceiveSettings { block.netReceive }

    // MARK: Lifecycle

    func start() throws {
        let s = settings
        if let uid = s.outputDeviceUID {
            guard let d = AudioDevices.device(uid: uid) else {
                throw BlockError.configuration("The output device chosen for \(block.displayName) is not connected.")
            }
            outputDeviceName = d.name
        }
        startedAt = Date()
        if s.asksAHost {
            let address = try UDPSocket.resolve(s.host)
            if address.isMulticastIPv4 {
                port = try UDPPortHub.shared.acquire(port: s.effectivePort)
                try port?.joinGroup(address)
            } else {
                // The sender answers whatever port the ask came from, so a
                // port of this block's own keeps it clear of anything else
                // on the sender's port number, on this Mac included.
                askEndpoint = Endpoint(address: address, port: s.effectivePort)
                port = try UDPPortHub.shared.acquire(port: 0)
            }
        } else {
            port = try UDPPortHub.shared.acquire(port: s.effectivePort)
            if s.proto == .fastRoute {
                try port?.joinGroup(s.effectiveGroup)
            } else if s.group != 0 {
                try port?.joinGroup(s.group)
            }
        }
        latchedStreamID = s.sourceID
        port?.addListener(self)
        if askEndpoint != nil { sendAsk() }
    }

    func stop() {
        if let jitter {
            let st = jitter.stats
            Log.net.info("Net Receive \(self.block.displayName, privacy: .public) stopping: \(st.received) packets, \(st.lost) lost, \(st.outOfOrder) out of order, \(st.late) late, \(st.underruns) underruns, held \(Int(st.maxHoldMs)) ms at most")
        }
        if let port {
            port.removeListener(self)
            UDPPortHub.shared.release(port)
        }
        port = nil
        lock.lock()
        output?.stop()
        output = nil
        jitter = nil
        decoder = nil
        lock.unlock()
    }

    private func sendAsk() {
        guard let port, let askEndpoint else { return }
        lastAsk = Date()
        let request = SubscribeRequest(wantsBeacon: true, streamID: settings.sourceID, streamName: settings.streamName)
        port.send(request.encode(), to: askEndpoint)
    }

    // MARK: Playback chain

    /// Builds the decoder, buffer and output for a stream, replacing any
    /// earlier chain when the format changes.
    private func ensureChain(codec: NetCodec, sampleRate: UInt32) -> Bool {
        if jitter != nil, streamCodec == codec, streamRate == sampleRate { return true }
        lock.lock(); defer { lock.unlock() }
        output?.stop()
        output = nil
        jitter = nil
        decoder = nil
        do {
            let dec = try CodecFactory.makeDecoder(codec: codec, sampleRate: sampleRate)
            let jb = JitterBuffer(sampleRate: Int(sampleRate), bufferMs: settings.bufferMs, decoder: dec)
            let deviceID = settings.outputDeviceUID.flatMap { AudioDevices.device(uid: $0)?.id }
            let out = AudioOutput(deviceID: deviceID, sampleRate: Double(sampleRate)) { [weak self] buffer, frames in
                guard let self else { buffer.update(repeating: 0, count: frames * 2); return }
                jb.pull(into: buffer, frameCount: frames)
                let g = self.gain
                if g != 1 { for i in 0..<(frames * 2) { buffer[i] *= g } }
            }
            try out.start()
            decoder = dec
            jitter = jb
            output = out
            streamCodec = codec
            streamRate = sampleRate
            lastError = nil
            Log.net.info("Net Receive \(self.block.displayName, privacy: .public): playing \(codec.shortName, privacy: .public) at \(sampleRate) Hz on \(self.outputDeviceName, privacy: .public)")
            return true
        } catch {
            lastError = error.localizedDescription
            Log.net.error("Net Receive \(self.block.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: UDPPortListener

    func port(_ port: UDPPortHandle, didReceive data: Data, from endpoint: Endpoint) {
        if settings.proto == .vban {
            handleVBAN(data, from: endpoint, port: port)
            return
        }
        if let (header, payload) = DataPacketHeader.decode(data) {
            if latchedStreamID == 0 { latchedStreamID = header.streamID }
            guard header.streamID == latchedStreamID else { return }
            guard ensureChain(codec: header.codec, sampleRate: header.sampleRate) else { return }
            lastPacket = Date()
            jitter?.push(sequence: header.sequence, frames: Int(header.frames), payload: payload)
        } else if let beacon = Beacon.decode(data) {
            // A unicast answer from the sender we asked.
            if latchedStreamID == 0 || beacon.streamID == latchedStreamID { senderBeacon = beacon }
        } else if let header = VBAN.Header.decode(data), header.proto == .service,
                  header.serviceType == VBAN.serviceTypeIdentification, header.serviceFunction & VBAN.serviceFunctionReply == 0 {
            replyToPing(header, from: endpoint, port: port)
        }
    }

    private func handleVBAN(_ data: Data, from endpoint: Endpoint, port: UDPPortHandle) {
        guard let header = VBAN.Header.decode(data) else { return }
        switch header.proto {
        case .service:
            if header.serviceType == VBAN.serviceTypeIdentification, header.serviceFunction & VBAN.serviceFunctionReply == 0 {
                replyToPing(header, from: endpoint, port: port)
            }
        case .audio:
            let wanted = settings.streamName.trimmingCharacters(in: .whitespaces)
            if !wanted.isEmpty && header.streamName != wanted { return }
            if let askEndpoint, endpoint.address != askEndpoint.address { return }
            if let vbanSender, vbanSender != endpoint { return }
            guard header.codec == 0 else { lastError = "\"\(header.streamName)\" is using one of VB-Audio's own codecs, which this cannot decode. Set the sender to PCM."; return }
            guard let rate = header.sampleRate, let bytesPerSample = header.dataType.bytesPerSample else {
                lastError = "\"\(header.streamName)\" is in a sample format this does not handle (VBAN data type \(header.dataType.rawValue))."
                return
            }
            let frames = header.samplesPerFrame
            let channels = header.channels
            let payload = data.subdata(in: VBAN.headerBytes..<data.count)
            guard payload.count >= frames * channels * bytesPerSample else { return }
            guard ensureChain(codec: .pcmFloat32, sampleRate: rate) else { return }
            vbanSender = endpoint
            vbanType = header.dataType
            vbanChannels = channels
            lastPacket = Date()
            // Unpack to stereo float and hand the buffer a float payload.
            let floats = unpackVBAN(payload, frames: frames, channels: channels, type: header.dataType)
            jitter?.push(sequence: header.frameCounter, frames: frames, payload: floats)
        default:
            break
        }
    }

    private func unpackVBAN(_ payload: Data, frames: Int, channels: Int, type: VBAN.DataType) -> Data {
        var out = Data(count: frames * 8)
        payload.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            out.withUnsafeMutableBytes { outRaw in
                let o = outRaw.bindMemory(to: Float.self)
                func sample(_ frame: Int, _ ch: Int) -> Float {
                    let idx = frame * channels + ch
                    switch type {
                    case .uint8: return (Float(p[idx]) - 128) / 128
                    case .int16:
                        let v = Int16(bitPattern: UInt16(p[2 * idx]) | UInt16(p[2 * idx + 1]) << 8)
                        return Float(v) / 32768
                    case .int24:
                        var v = Int32(p[3 * idx]) | Int32(p[3 * idx + 1]) << 8 | Int32(p[3 * idx + 2]) << 16
                        if v & 0x80_0000 != 0 { v -= 0x100_0000 }
                        return Float(v) / 8_388_608
                    case .int32:
                        let v = Int32(bitPattern: UInt32(p[4 * idx]) | UInt32(p[4 * idx + 1]) << 8 | UInt32(p[4 * idx + 2]) << 16 | UInt32(p[4 * idx + 3]) << 24)
                        return Float(Double(v) / 2_147_483_648)
                    case .float32:
                        let bits = UInt32(p[4 * idx]) | UInt32(p[4 * idx + 1]) << 8 | UInt32(p[4 * idx + 2]) << 16 | UInt32(p[4 * idx + 3]) << 24
                        return Float(bitPattern: bits)
                    case .float64:
                        var bits: UInt64 = 0
                        for i in 0..<8 { bits |= UInt64(p[8 * idx + i]) << UInt64(8 * i) }
                        return Float(Double(bitPattern: bits))
                    case .int12, .int10: return 0
                    }
                }
                for f in 0..<frames {
                    let l = sample(f, 0)
                    let r = channels > 1 ? sample(f, 1) : l
                    o[2 * f] = l
                    o[2 * f + 1] = r
                }
            }
        }
        return out
    }

    private func replyToPing(_ header: VBAN.Header, from endpoint: Endpoint, port: UDPPortHandle) {
        let reply = VBAN.pingReply(to: header, streamName: settings.streamName,
                                   body: DiscoveryService.pingReplyBody(isReceiver: true, isSender: false))
        port.send(reply, to: endpoint)
    }

    func portTick(_ port: UDPPortHandle) {
        jitter?.tick()
        if askEndpoint != nil && Date().timeIntervalSince(lastAsk) >= FastRouteNet.subscribeInterval { sendAsk() }
    }

    // MARK: Status

    var statusText: String {
        let s = settings
        let name = block.displayName
        let from: String
        if let askEndpoint { from = "from \(s.host) (\(askEndpoint))" }
        else if s.proto == .vban { from = s.group != 0 ? "on the group \(s.group.ipv4String) port \(s.effectivePort)" : "on port \(s.effectivePort)" }
        else { from = "on the group \(s.effectiveGroup.ipv4String) port \(s.effectivePort)" }
        guard let jitter, let codec = streamCodec else {
            var line = "\(name) \(from): nothing has arrived yet"
            if askEndpoint != nil && lastPacket == nil && Date().timeIntervalSince(startedAt) > 15 {
                line = "\(name): \(s.host) did not answer within fifteen seconds."
            }
            if let lastError { line += "; \(lastError)" }
            return line
        }
        let st = jitter.stats
        let codecName = s.proto == .vban ? (vbanType.map { "VBAN \($0)" } ?? "VBAN") : codec.shortName
        var line = "\(name) \(from): \(codecName) at \(streamRate) Hz, \(s.bufferMs) ms buffer to \(outputDeviceName)"
        line += String(format: "; %.2f%% lost", st.lossPercent)
        if st.outOfOrder > 0 { line += ", \(st.outOfOrder) out of order" }
        if st.late > 0 { line += ", \(st.late) too late" }
        if st.underruns > 0 { line += ", \(st.underruns) underruns" }
        if st.maxHoldMs > 0 { line += String(format: ", held %.0f ms at most", st.maxHoldMs) }
        if let lastPacket, Date().timeIntervalSince(lastPacket) > 2 { line += "; nothing for \(Int(Date().timeIntervalSince(lastPacket))) s" }
        if let lastError { line += "; \(lastError)" }
        return line
    }
}
