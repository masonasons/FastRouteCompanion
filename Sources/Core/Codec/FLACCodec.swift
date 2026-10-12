//
//  FLACCodec.swift
//  FastRoute Companion
//
//  FLAC over the network, the way FastRoute does it: 16 bit stereo, a fixed
//  block size equal to the frames in a packet, and one FLAC frame per packet.
//  No stream header travels over the wire; the receiver makes its own "fLaC"
//  marker and STREAMINFO block from the packet header and feeds the decoder
//  that before the first frame.
//

import Foundation

final class FLACEncoderWrapper: AudioEncoder {
    let codec: NetCodec = .flac
    let sampleRate: UInt32
    let framesPerPacket: Int
    private var encoder: UnsafeMutablePointer<FLAC__StreamEncoder>?
    private var pending = Data()
    private var inMetadata = true
    private var intBuffer: [Int32]

    init(sampleRate: UInt32, blockSize: Int) throws {
        self.sampleRate = sampleRate
        framesPerPacket = blockSize
        intBuffer = [Int32](repeating: 0, count: blockSize * 2)
        guard let enc = FLAC__stream_encoder_new() else { throw CodecError.flac("The FLAC encoder could not be created.") }
        encoder = enc
        FLAC__stream_encoder_set_channels(enc, 2)
        FLAC__stream_encoder_set_bits_per_sample(enc, 16)
        FLAC__stream_encoder_set_sample_rate(enc, sampleRate)
        FLAC__stream_encoder_set_blocksize(enc, UInt32(blockSize))
        FLAC__stream_encoder_set_streamable_subset(enc, 1)
        FLAC__stream_encoder_set_compression_level(enc, 5)
        FLAC__stream_encoder_set_verify(enc, 0)
        let client = Unmanaged.passUnretained(self).toOpaque()
        let status = FLAC__stream_encoder_init_stream(enc, { _, buffer, bytes, samples, _, clientData in
            guard let clientData, let buffer else { return FLAC__STREAM_ENCODER_WRITE_STATUS_FATAL_ERROR }
            let me = Unmanaged<FLACEncoderWrapper>.fromOpaque(clientData).takeUnretainedValue()
            // Metadata writes report zero samples; the frames carry samples.
            if samples > 0 { me.pending.append(buffer, count: bytes) }
            return FLAC__STREAM_ENCODER_WRITE_STATUS_OK
        }, nil, nil, nil, client)
        guard status == FLAC__STREAM_ENCODER_INIT_STATUS_OK else {
            FLAC__stream_encoder_delete(enc)
            encoder = nil
            throw CodecError.flac("The FLAC encoder would not start (status \(status.rawValue)).")
        }
    }

    deinit {
        if let encoder {
            FLAC__stream_encoder_finish(encoder)
            FLAC__stream_encoder_delete(encoder)
        }
    }

    /// libFLAC only writes a frame once it holds one sample beyond the block,
    /// so each call yields the frame for the block fed the call before, and
    /// the very first call yields nothing. The frames still line up exactly
    /// with the blocks fed in.
    func encode(_ frames: UnsafePointer<Float>) -> EncodedPacket? {
        guard let encoder else { return nil }
        for i in 0..<(framesPerPacket * 2) {
            intBuffer[i] = Int32(max(-32768, min(32767, (frames[i] * 32767).rounded())))
        }
        pending.removeAll(keepingCapacity: true)
        let ok = intBuffer.withUnsafeBufferPointer { buf in
            FLAC__stream_encoder_process_interleaved(encoder, buf.baseAddress, UInt32(framesPerPacket))
        }
        guard ok != 0, !pending.isEmpty else { return nil }
        return EncodedPacket(payload: pending, frames: framesPerPacket)
    }
}

final class FLACDecoderWrapper: AudioDecoder {
    let codec: NetCodec = .flac
    private let sampleRate: UInt32
    private var decoder: UnsafeMutablePointer<FLAC__StreamDecoder>?
    private var input = Data()
    private var inputOffset = 0
    private var output: [Float] = []
    private var blockSize = 0
    private var headerFed = false

    init(sampleRate: UInt32) throws {
        self.sampleRate = sampleRate
        guard let dec = FLAC__stream_decoder_new() else { throw CodecError.flac("The FLAC decoder could not be created.") }
        decoder = dec
        let client = Unmanaged.passUnretained(self).toOpaque()
        let status = FLAC__stream_decoder_init_stream(dec, { _, buffer, bytes, clientData in
            guard let clientData, let bytes, let buffer else { return FLAC__STREAM_DECODER_READ_STATUS_ABORT }
            let me = Unmanaged<FLACDecoderWrapper>.fromOpaque(clientData).takeUnretainedValue()
            let available = me.input.count - me.inputOffset
            if available <= 0 {
                bytes.pointee = 0
                return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM
            }
            let n = min(available, bytes.pointee)
            me.input.withUnsafeBytes { raw in
                buffer.update(from: raw.bindMemory(to: UInt8.self).baseAddress! + me.inputOffset, count: n)
            }
            me.inputOffset += n
            bytes.pointee = n
            return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE
        }, nil, nil, nil, nil, { _, frame, buffer, clientData in
            guard let clientData, let frame, let buffer else { return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT }
            let me = Unmanaged<FLACDecoderWrapper>.fromOpaque(clientData).takeUnretainedValue()
            let n = Int(frame.pointee.header.blocksize)
            let channels = Int(frame.pointee.header.channels)
            // libFLAC writes a silent frame of its own for each frame it sees
            // missing before this one. Gaps are the jitter buffer's job, so
            // only the last frame written in a call is kept.
            me.output.removeAll(keepingCapacity: true)
            let scale = 1 / Float(1 << (Int(frame.pointee.header.bits_per_sample) - 1))
            let left = buffer[0]!
            let right = channels > 1 ? buffer[1]! : left
            let start = me.output.count
            me.output.append(contentsOf: repeatElement(0, count: n * 2))
            for i in 0..<n {
                me.output[start + 2 * i] = Float(left[i]) * scale
                me.output[start + 2 * i + 1] = Float(right[i]) * scale
            }
            return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE
        }, nil, { _, _, _ in }, client)
        guard status == FLAC__STREAM_DECODER_INIT_STATUS_OK else {
            FLAC__stream_decoder_delete(dec)
            decoder = nil
            throw CodecError.flac("The FLAC decoder would not start.")
        }
    }

    deinit {
        if let decoder {
            FLAC__stream_decoder_finish(decoder)
            FLAC__stream_decoder_delete(decoder)
        }
    }

    /// "fLaC" plus a STREAMINFO block describing a fixed-blocksize 16 bit
    /// stereo stream, which is what the sender's frames belong to.
    private func streamHeader(blockSize: Int) -> Data {
        var d = Data("fLaC".utf8)
        d.append(contentsOf: [0x80, 0x00, 0x00, 0x22])     // last metadata block, STREAMINFO, 34 bytes
        var info = [UInt8](repeating: 0, count: 34)
        info[0] = UInt8(blockSize >> 8 & 0xFF); info[1] = UInt8(blockSize & 0xFF)
        info[2] = info[0]; info[3] = info[1]
        // bytes 4..9: min/max frame size, unknown
        let rate = Int(sampleRate), channels = 2, bps = 16
        info[10] = UInt8(rate >> 12 & 0xFF)
        info[11] = UInt8(rate >> 4 & 0xFF)
        info[12] = UInt8((rate & 0xF) << 4 | (channels - 1) << 1 | (bps - 1) >> 4)
        info[13] = UInt8(((bps - 1) & 0xF) << 4)
        d.append(contentsOf: info)
        return d
    }

    private func restart(blockSize: Int) {
        guard let decoder else { return }
        FLAC__stream_decoder_reset(decoder)
        input = streamHeader(blockSize: blockSize)
        inputOffset = 0
        self.blockSize = blockSize
        headerFed = false
        output.removeAll(keepingCapacity: true)
        // Reads the metadata so the next call decodes a frame.
        _ = FLAC__stream_decoder_process_until_end_of_metadata(decoder)
        headerFed = true
    }

    func decode(_ payload: Data, frames: Int, into out: inout [Float]) -> Bool {
        guard let decoder else { return false }
        if !headerFed || frames != blockSize { restart(blockSize: frames) }
        input = payload
        inputOffset = 0
        output.removeAll(keepingCapacity: true)
        let ok = FLAC__stream_decoder_process_single(decoder)
        let state = FLAC__stream_decoder_get_state(decoder)
        if ok == 0 || output.isEmpty || state == FLAC__STREAM_DECODER_ABORTED || state == FLAC__STREAM_DECODER_END_OF_STREAM
            || state == FLAC__STREAM_DECODER_MEMORY_ALLOCATION_ERROR {
            headerFed = false
            return false
        }
        out.append(contentsOf: output)
        return true
    }

    func conceal(frames: Int, nextPayload: Data?, into out: inout [Float]) {
        out.append(contentsOf: repeatElement(0, count: frames * 2))
    }
}
