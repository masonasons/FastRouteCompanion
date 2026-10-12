//
//  DiscoveryService.swift
//  FastRoute Companion
//
//  Listens for FastRoute senders announcing themselves on the beacon group,
//  and asks the local network for VBAN hosts, which only speak when spoken to.
//  Runs for the life of the app so the Net Receive dialog has a list ready.
//

import Foundation

struct DiscoveredSender: Identifiable, Equatable {
    let beacon: Beacon
    let source: Endpoint
    var lastSeen: Date

    var id: String { "\(beacon.streamID)@\(source.address)" }

    var summary: String {
        let where_ = beacon.group != 0 ? "group \(beacon.group.ipv4String)" : "asks \(source.address.ipv4String)"
        return "\(beacon.streamName) on \(beacon.hostName): \(beacon.codec.shortName) at \(beacon.sampleRate) Hz, \(where_) port \(beacon.port)"
    }
}

struct DiscoveredVBANHost: Identifiable, Equatable {
    let endpoint: Endpoint
    let info: VBAN.Ping0
    let streamName: String
    var lastSeen: Date

    var id: String { "\(endpoint.address)" }

    var summary: String {
        let name = info.hostName.isEmpty ? endpoint.address.ipv4String : info.hostName
        let app = info.applicationName.isEmpty ? "VBAN host" : info.applicationName
        return "\(name): \(app), \(endpoint.address.ipv4String) port \(endpoint.port)"
    }

    static func == (a: DiscoveredVBANHost, b: DiscoveredVBANHost) -> Bool {
        a.endpoint == b.endpoint && a.lastSeen == b.lastSeen
    }
}

final class DiscoveryService: UDPPortListener {
    static let shared = DiscoveryService()

    private let lock = NSLock()
    private var beaconPort: UDPPortHandle?
    private var pingPort: UDPPortHandle?
    private var senderTable: [String: DiscoveredSender] = [:]
    private var vbanTable: [String: DiscoveredVBANHost] = [:]
    private var lastPing = Date.distantPast
    private var pingCounter: UInt32 = 0
    private var lastNotify = Date.distantPast
    private(set) var startError: String?

    /// Posted on the main thread when the lists change.
    static let didUpdate = Notification.Name("DiscoveryServiceDidUpdate")

    static let senderTimeout: TimeInterval = 3
    static let vbanTimeout: TimeInterval = 8
    static let pingInterval: TimeInterval = 2

    func start() {
        guard beaconPort == nil else { return }
        do {
            let b = try UDPPortHub.shared.acquire(port: FastRouteNet.beaconPort)
            try b.joinGroup(FastRouteNet.beaconGroup)
            b.addListener(self)
            beaconPort = b
        } catch {
            startError = "Senders cannot be listed: \(error.localizedDescription)"
        }
        do {
            let p = try UDPPortHub.shared.acquire(port: 0)
            p.addListener(self)
            pingPort = p
        } catch {
            startError = (startError.map { $0 + " " } ?? "") + "VBAN hosts cannot be listed: \(error.localizedDescription)"
        }
    }

    func stop() {
        if let beaconPort { beaconPort.removeListener(self); UDPPortHub.shared.release(beaconPort) }
        if let pingPort { pingPort.removeListener(self); UDPPortHub.shared.release(pingPort) }
        beaconPort = nil
        pingPort = nil
    }

    var senders: [DiscoveredSender] {
        lock.lock(); defer { lock.unlock() }
        return senderTable.values.sorted { $0.beacon.streamName.localizedCaseInsensitiveCompare($1.beacon.streamName) == .orderedAscending }
    }

    var vbanHosts: [DiscoveredVBANHost] {
        lock.lock(); defer { lock.unlock() }
        return vbanTable.values.sorted { $0.summary.localizedCaseInsensitiveCompare($1.summary) == .orderedAscending }
    }

    /// Asks for VBAN hosts right now rather than at the next interval.
    func refreshVBANHosts() {
        lastPing = .distantPast
        sendPingsIfDue()
    }

    // MARK: UDPPortListener

    func port(_ port: UDPPortHandle, didReceive data: Data, from endpoint: Endpoint) {
        if port === beaconPort, let beacon = Beacon.decode(data) {
            lock.lock()
            let entry = DiscoveredSender(beacon: beacon, source: endpoint, lastSeen: Date())
            let changed = senderTable[entry.id]?.beacon != beacon
            senderTable[entry.id] = entry
            lock.unlock()
            if changed { notify() }
        } else if port === pingPort, let header = VBAN.Header.decode(data), header.proto == .service,
                  header.serviceType == VBAN.serviceTypeIdentification, header.serviceFunction & VBAN.serviceFunctionReply != 0,
                  let info = VBAN.Ping0.decode(data.subdata(in: VBAN.headerBytes..<data.count)) {
            lock.lock()
            let entry = DiscoveredVBANHost(endpoint: Endpoint(address: endpoint.address, port: VBAN.defaultPort),
                                           info: info, streamName: header.streamName, lastSeen: Date())
            let isNew = vbanTable[entry.id] == nil
            vbanTable[entry.id] = entry
            lock.unlock()
            if isNew { notify() }
        }
    }

    func portTick(_ port: UDPPortHandle) {
        guard port === pingPort else { return }
        sendPingsIfDue()
        expire()
    }

    private func sendPingsIfDue() {
        guard let pingPort, Date().timeIntervalSince(lastPing) >= DiscoveryService.pingInterval else { return }
        lastPing = Date()
        pingCounter &+= 1
        let packet = VBAN.pingRequest(counter: pingCounter)
        var targets = UDPSocket.ipv4Broadcasts()
        targets.append(0xFFFF_FFFF)
        for t in targets { pingPort.send(packet, to: Endpoint(address: t, port: VBAN.defaultPort)) }
    }

    private func expire() {
        let now = Date()
        lock.lock()
        let beforeSenders = senderTable.count, beforeHosts = vbanTable.count
        senderTable = senderTable.filter { now.timeIntervalSince($0.value.lastSeen) < DiscoveryService.senderTimeout }
        vbanTable = vbanTable.filter { now.timeIntervalSince($0.value.lastSeen) < DiscoveryService.vbanTimeout }
        let changed = beforeSenders != senderTable.count || beforeHosts != vbanTable.count
        lock.unlock()
        if changed { notify() }
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: DiscoveryService.didUpdate, object: nil) }
    }

    // MARK: Ping replies

    /// The description of this Mac that answers a VBAN identification request.
    static func pingReplyBody(isReceiver: Bool, isSender: Bool) -> VBAN.Ping0 {
        var body = VBAN.Ping0()
        body.bitType = (isReceiver ? VBAN.Ping0.typeReceptor : 0) | (isSender ? VBAN.Ping0.typeTransmitter : 0)
        body.bitFeature = VBAN.Ping0.featureAudio
        body.preferredRate = 48000
        body.minRate = 6000
        body.maxRate = 705600
        body.version = (0, 1, 0, 0)
        body.deviceName = "Mac"
        body.manufacturerName = "Apple"
        body.applicationName = "FastRoute Companion"
        body.hostName = UDPSocket.localHostName
        body.userName = NSFullUserName()
        return body
    }
}
