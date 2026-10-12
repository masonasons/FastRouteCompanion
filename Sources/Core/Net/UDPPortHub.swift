//
//  UDPPortHub.swift
//  FastRoute Companion
//
//  One socket per UDP port for the whole app. A Net Send waiting on 6982 and
//  a Net Receive joined to a group on 6982 both get every packet that
//  arrives, which two separate sockets on one port would not guarantee.
//  Each port runs a receive thread that hands packets to every listener and
//  ticks them regularly, so a jitter buffer can fill gaps while nothing
//  arrives.
//

import Foundation

protocol UDPPortListener: AnyObject {
    func port(_ port: UDPPortHandle, didReceive data: Data, from endpoint: Endpoint)
    /// Called about every 20 ms on the port's thread whether or not anything arrived.
    func portTick(_ port: UDPPortHandle)
}

final class UDPPortHandle {
    let port: UInt16
    fileprivate let socket: UDPSocket
    private var listeners: [ObjectIdentifier: WeakListener] = [:]
    private var joinedGroups = Set<UInt32>()
    private let lock = NSLock()
    private var thread: Thread?
    private var running = false
    fileprivate var refCount = 0

    private struct WeakListener { weak var value: UDPPortListener? }

    fileprivate init(port: UInt16) throws {
        socket = try UDPSocket()
        try socket.bind(port: port)
        self.port = socket.boundPort
        socket.setReceiveTimeout(0.02)
        socket.setMulticastLoop(true)
        socket.setBroadcast(true)
    }

    fileprivate func startThread() {
        guard thread == nil else { return }
        running = true
        let t = Thread { [weak self] in self?.receiveLoop() }
        t.name = "udp-port-\(port)"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    fileprivate func stopThread() {
        running = false
        thread = nil
    }

    func addListener(_ listener: UDPPortListener) {
        lock.lock(); defer { lock.unlock() }
        listeners[ObjectIdentifier(listener)] = WeakListener(value: listener)
    }

    func removeListener(_ listener: UDPPortListener) {
        lock.lock(); defer { lock.unlock() }
        listeners.removeValue(forKey: ObjectIdentifier(listener))
    }

    func joinGroup(_ group: UInt32) throws {
        lock.lock(); defer { lock.unlock() }
        guard !joinedGroups.contains(group) else { return }
        try socket.joinMulticast(group: group)
        joinedGroups.insert(group)
    }

    func setMulticastTTL(_ ttl: Int) { socket.setMulticastTTL(UInt8(max(1, min(255, ttl)))) }

    @discardableResult
    func send(_ data: Data, to endpoint: Endpoint) -> Int { socket.send(data, to: endpoint) }

    private func receiveLoop() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 65536, alignment: 16)
        defer { buffer.deallocate() }
        var lastTick = Date()
        while running {
            var from = Endpoint(address: 0, port: 0)
            let n = socket.receive(into: buffer, from: &from)
            if n > 0 {
                let data = Data(bytes: buffer.baseAddress!, count: n)
                for l in currentListeners() { l.port(self, didReceive: data, from: from) }
            } else if n < 0 {
                Thread.sleep(forTimeInterval: 0.01)
            }
            let now = Date()
            if now.timeIntervalSince(lastTick) >= 0.01 {
                lastTick = now
                for l in currentListeners() { l.portTick(self) }
            }
        }
    }

    private func currentListeners() -> [UDPPortListener] {
        lock.lock(); defer { lock.unlock() }
        return listeners.values.compactMap { $0.value }
    }
}

final class UDPPortHub {
    static let shared = UDPPortHub()
    private var handles: [UInt16: UDPPortHandle] = [:]
    private let lock = NSLock()

    /// Opens or shares the socket on `port`; 0 picks a free port of its own.
    func acquire(port: UInt16) throws -> UDPPortHandle {
        lock.lock(); defer { lock.unlock() }
        if port != 0, let existing = handles[port] {
            existing.refCount += 1
            return existing
        }
        let handle = try UDPPortHandle(port: port)
        handle.refCount = 1
        handles[handle.port] = handle
        handle.startThread()
        return handle
    }

    func release(_ handle: UDPPortHandle) {
        lock.lock(); defer { lock.unlock() }
        handle.refCount -= 1
        if handle.refCount <= 0 {
            handle.stopThread()
            handles.removeValue(forKey: handle.port)
            // The receive loop finishes its current timeout and the socket closes with the handle.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { handle.socket.close() }
        }
    }
}
