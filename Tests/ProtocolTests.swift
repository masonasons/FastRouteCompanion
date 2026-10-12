//
//  ProtocolTests.swift
//  FastRoute Companion
//
//  The wire formats round-trip and have the sizes FastRoute checks for.
//

import XCTest

final class ProtocolTests: XCTestCase {
    func testBeaconRoundTrip() {
        let b = Beacon(codec: .opus, streamID: 0xDEADBEEF, group: FastRouteNet.defaultGroup, port: 6982,
                       framesPerPacket: 480, sampleRate: 48000, streamName: "Stream1", hostName: "Brün's Mac")
        let data = b.encode()
        XCTAssertEqual(data.count, 96)
        XCTAssertEqual(Array(data.prefix(4)), Array("FRNB".utf8))
        XCTAssertEqual(data[4], 1)
        XCTAssertEqual(data[5], 4)
        XCTAssertEqual(data[6], 2)
        // Group address goes out little-endian from the host-order value.
        XCTAssertEqual(Array(data[12..<16]), [0x15, 0x4D, 0xFF, 0xEF])
        let back = Beacon.decode(data)!
        XCTAssertEqual(back.streamID, 0xDEADBEEF)
        XCTAssertEqual(back.group, FastRouteNet.defaultGroup)
        XCTAssertEqual(back.port, 6982)
        XCTAssertEqual(back.framesPerPacket, 480)
        XCTAssertEqual(back.sampleRate, 48000)
        XCTAssertEqual(back.streamName, "Stream1")
        XCTAssertEqual(back.hostName, "Brun's Mac")
        XCTAssertNil(Beacon.decode(data.prefix(95)))
    }

    func testDataPacketRoundTrip() {
        let payload = Data((0..<1400).map { UInt8($0 & 0xFF) })
        let h = DataPacketHeader(codec: .flac, sampleRate: 44100, streamID: 7, sequence: 123456,
                                 framePosition: 1 << 40, frames: 334, payloadLength: 1400)
        let data = h.encode(payload: payload)
        XCTAssertEqual(data.count, 32 + 1400)
        let (back, p) = DataPacketHeader.decode(data)!
        XCTAssertEqual(back.codec, .flac)
        XCTAssertEqual(back.sampleRate, 44100)
        XCTAssertEqual(back.streamID, 7)
        XCTAssertEqual(back.sequence, 123456)
        XCTAssertEqual(back.framePosition, 1 << 40)
        XCTAssertEqual(back.frames, 334)
        XCTAssertEqual(p, payload)
        // A payload longer than a datagram holds is refused, as FastRoute does.
        var tooLong = h
        tooLong.payloadLength = 1401
        XCTAssertNil(DataPacketHeader.decode(tooLong.encode(payload: Data(count: 1401))))
    }

    func testSubscribeRoundTrip() {
        let r = SubscribeRequest(wantsBeacon: true, streamID: 99, streamName: "Mic")
        let data = r.encode()
        XCTAssertEqual(data.count, 48)
        XCTAssertEqual(data[5], 1)
        let back = SubscribeRequest.decode(data)!
        XCTAssertTrue(back.wantsBeacon)
        XCTAssertEqual(back.streamID, 99)
        XCTAssertEqual(back.streamName, "Mic")
    }

    func testVBANHeader() {
        var h = VBAN.Header()
        h.sampleRateIndex = VBAN.rateIndex(for: 44100)!
        h.samplesPerFrame = 256
        h.channels = 2
        h.dataType = .int16
        h.streamName = "Stream1"
        h.frameCounter = 42
        let data = h.encode()
        XCTAssertEqual(data.count, 28)
        XCTAssertEqual(data[4], 16)        // audio protocol, 44100 index
        XCTAssertEqual(data[5], 255)
        XCTAssertEqual(data[6], 1)
        XCTAssertEqual(data[7], 1)
        let back = VBAN.Header.decode(data)!
        XCTAssertEqual(back, h)
        XCTAssertEqual(back.sampleRate, 44100)
    }

    func testVBANPing() {
        let request = VBAN.pingRequest(counter: 5)
        let h = VBAN.Header.decode(request)!
        XCTAssertEqual(h.proto, .service)
        XCTAssertEqual(h.serviceFunction, 0)
        XCTAssertEqual(h.serviceType, 0)
        XCTAssertEqual(h.frameCounter, 5)
        let body = DiscoveryService.pingReplyBody(isReceiver: true, isSender: false)
        let reply = VBAN.pingReply(to: h, streamName: "", body: body)
        XCTAssertEqual(reply.count, 28 + 676)
        let rh = VBAN.Header.decode(reply)!
        XCTAssertEqual(rh.serviceFunction, 0x80)
        XCTAssertEqual(rh.frameCounter, 5)
        let back = VBAN.Ping0.decode(reply.subdata(in: 28..<reply.count))!
        XCTAssertEqual(back.applicationName, "FastRoute Companion")
        XCTAssertEqual(back.bitType, VBAN.Ping0.typeReceptor)
    }

    func testIPv4Helpers() {
        XCTAssertEqual(UInt32(ipv4String: "239.255.77.21"), 0xEFFF4D15)
        XCTAssertEqual(UInt32(0xEFFF4D14).ipv4String, "239.255.77.20")
        XCTAssertTrue(UInt32(ipv4String: "224.0.0.1")!.isMulticastIPv4)
        XCTAssertFalse(UInt32(ipv4String: "192.168.1.1")!.isMulticastIPv4)
        XCTAssertNil(UInt32(ipv4String: "1.2.3"))
        XCTAssertNil(UInt32(ipv4String: "1.2.3.256"))
    }
}
