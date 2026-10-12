//
//  UDPSocket.swift
//  FastRoute Companion
//
//  A thin BSD socket wrapper for IPv4 UDP: binding with address reuse so
//  several blocks can share a port, multicast membership on every interface,
//  hop limits, blocking receives with a timeout, and host name resolution.
//  Addresses are host-order UInt32 throughout, the way the FastRoute beacon
//  carries them.
//

import Foundation
import Darwin

struct Endpoint: Hashable, CustomStringConvertible {
    var address: UInt32
    var port: UInt16
    var description: String { "\(address.ipv4String):\(port)" }
}

enum SocketError: Error, LocalizedError {
    case failed(String, Int32)
    case unresolvable(String)

    var errorDescription: String? {
        switch self {
        case .failed(let what, let errno):
            return "\(what) failed: \(String(cString: strerror(errno))) (\(errno))"
        case .unresolvable(let host):
            return "\(host) could not be resolved to an IPv4 address."
        }
    }
}

final class UDPSocket {
    private(set) var fd: Int32 = -1
    private(set) var boundPort: UInt16 = 0

    init() throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SocketError.failed("socket", errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var bufferSize: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    func bind(port: UInt16, address: UInt32 = INADDR_ANY) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = address.bigEndian
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw SocketError.failed("bind to port \(port)", errno) }
        if port == 0 {
            var local = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &local) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            }
            boundPort = UInt16(bigEndian: local.sin_port)
        } else {
            boundPort = port
        }
    }

    /// Joins a multicast group on every IPv4 interface that has one, so a
    /// beacon arriving over Wi-Fi is heard as well as one over Ethernet.
    func joinMulticast(group: UInt32) throws {
        var joined = 0
        var lastErrno: Int32 = 0
        for iface in UDPSocket.ipv4Interfaces() {
            var req = ip_mreq()
            req.imr_multiaddr.s_addr = group.bigEndian
            req.imr_interface.s_addr = iface.bigEndian
            let r = setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &req, socklen_t(MemoryLayout<ip_mreq>.size))
            if r == 0 { joined += 1 } else if errno != EADDRINUSE { lastErrno = errno } else { joined += 1 }
        }
        if joined == 0 {
            var req = ip_mreq()
            req.imr_multiaddr.s_addr = group.bigEndian
            req.imr_interface.s_addr = INADDR_ANY.bigEndian
            let r = setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &req, socklen_t(MemoryLayout<ip_mreq>.size))
            guard r == 0 || errno == EADDRINUSE else { throw SocketError.failed("join group \(group.ipv4String)", lastErrno != 0 ? lastErrno : errno) }
        }
    }

    func setMulticastTTL(_ ttl: UInt8) {
        var v = ttl
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &v, socklen_t(MemoryLayout<UInt8>.size))
    }

    func setMulticastLoop(_ on: Bool) {
        var v: UInt8 = on ? 1 : 0
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &v, socklen_t(MemoryLayout<UInt8>.size))
    }

    func setBroadcast(_ on: Bool) {
        var v: Int32 = on ? 1 : 0
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &v, socklen_t(MemoryLayout<Int32>.size))
    }

    func setReceiveTimeout(_ seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Sends one datagram. Returns the number of bytes sent, or -1 with errno set.
    @discardableResult
    func send(_ data: Data, to endpoint: Endpoint) -> Int {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = endpoint.port.bigEndian
        addr.sin_addr.s_addr = endpoint.address.bigEndian
        return data.withUnsafeBytes { buf -> Int in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Blocks until a datagram arrives or the receive timeout passes. Returns
    /// the byte count, 0 on timeout, or -1 on an error other than a timeout.
    func receive(into buffer: UnsafeMutableRawBufferPointer, from: inout Endpoint) -> Int {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, buffer.baseAddress, buffer.count, 0, $0, &len)
            }
        }
        if n < 0 {
            return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? 0 : -1
        }
        from = Endpoint(address: UInt32(bigEndian: addr.sin_addr.s_addr), port: UInt16(bigEndian: addr.sin_port))
        return n
    }

    // MARK: Addresses

    /// Host-order IPv4 addresses of the machine's own interfaces, loopback excluded.
    static func ipv4Interfaces() -> [UInt32] {
        var result: [UInt32] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_MULTICAST != 0 else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if !result.contains(addr) { result.append(addr) }
        }
        return result
    }

    /// Directed broadcast addresses of the machine's interfaces, for finding
    /// VBAN hosts, which have to be asked rather than announcing themselves.
    static func ipv4Broadcasts() -> [UInt32] {
        var result: [UInt32] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0,
                  let ba = entry.pointee.ifa_dstaddr else { continue }
            let addr = ba.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if addr != 0 && !result.contains(addr) { result.append(addr) }
        }
        return result
    }

    /// Resolves a dotted quad or a host name to a host-order IPv4 address.
    static func resolve(_ host: String) throws -> UInt32 {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let literal = UInt32(ipv4String: trimmed) { return literal }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(trimmed, nil, &hints, &info) == 0, let first = info else { throw SocketError.unresolvable(trimmed) }
        defer { freeaddrinfo(info) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if entry.pointee.ai_family == AF_INET, let sa = entry.pointee.ai_addr {
                return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            }
            cursor = entry.pointee.ai_next
        }
        throw SocketError.unresolvable(trimmed)
    }

    /// The name other machines see in beacons and ping replies.
    static let localHostName: String = {
        if let name = Host.current().localizedName, !name.isEmpty { return name }
        let raw = ProcessInfo.processInfo.hostName
        return raw.split(separator: ".").first.map(String.init) ?? raw
    }()
}
