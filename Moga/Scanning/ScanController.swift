import Foundation
import AppKit

// Drives a scan session.
//
// Protocol (from Windows Composer pcap):
//   For each scan position, send ONE CameraPacket with the rotor and turntable
//   angles for that position. The device moves the motors, captures stackCount
//   images, and streams them back as Chunk packets. When the last chunk for a
//   position arrives the controller sends the next CameraPacket.
//
// Scan positions are computed with the Fibonacci / golden-angle spiral, which
// gives uniform sphere coverage. Rotor (azimuth) increments by 137.508° per
// step; turntable (elevation) descends linearly from 0 to -maxElevation.

@Observable
final class ScanController {
    enum State { case idle, connecting, scanning, complete, failed(String) }

    private(set) var state: State = .idle
    private(set) var photosReceived: Int = 0
    private(set) var totalPhotos: Int = 0

    var onPhotoReceived: ((UInt32, Data) -> Void)?   // (positionIndex, jpegData)

    private let session: DeviceSession

    // Scan parameters
    private var positions: [(rotor: Float, turntable: Float)] = []
    private var nextPositionIndex: Int = 0           // 0-based index into positions[]
    private var stackCount: UInt32 = 1

    // Stream reassembly: daemon sends photo data as type=13 header + type=14 stream chunks.
    // Raw bytes are LZ4-compressed YUV420 (2328×1748), decompressed to 6,104,016 bytes.
    private var activeStreamPosition: UInt32? = nil
    private var activeStreamBuffer: Data = Data()
    private var activeStreamCompressedSize: Int = 0   // exact byte count from video header
    private static let captureWidth = 2328
    private static let captureHeight = 1748
    private static let uncompressedSize = captureWidth * captureHeight * 3 / 2  // 6,104,016

    init(session: DeviceSession) {
        self.session = session
        // Intercept all incoming packets (overrides DeviceSession's own handler).
        // We re-handle .command here so we get the ready signal too.
        session.tcp.onPacket = { [weak self] type, data in
            self?.handlePacket(type: type, data: data)
        }
    }

    // MARK: - Start scan

    /// Begin a scan with `photoCount` positions and `stackSize` exposures per position.
    /// `maxElevationDegrees` is the absolute value of the lowest elevation angle
    /// (turntable goes from 0° down to -maxElevationDegrees).
    ///
    /// Note: stackSize > 1 (focus stacking) requires non-zero near/far diopter fields
    /// in the camera packet, which are not yet implemented. Force stackCount=1 until
    /// those fields are wired up.
    func start(photoCount: Int, stackSize: UInt32 = 1, maxElevationDegrees: Float = 44) {
        guard case .idle = state else { return }

        positions = Self.fibonacciPositions(count: photoCount, maxElevation: maxElevationDegrees)
        stackCount = 1   // stackSize ignored until focus diopter fields are implemented
        totalPhotos = photoCount
        photosReceived = 0
        nextPositionIndex = 0
        activeStreamPosition = nil
        activeStreamBuffer = Data()
        state = .connecting

        NSLog("📸 Starting scan: \(photoCount) positions, stack=\(stackSize), maxElevation=\(maxElevationDegrees)°")

        // If already connected and past handshake, jump straight to first camera packet.
        // Otherwise connect and wait for the config-echo command packet.
        if case .ready = session.state {
            sendFirstCameraPacket()
        } else {
            session.connect()
        }
    }

    func cancel() {
        state = .idle
        positions = []
    }

    // MARK: - Camera packet dispatch

    /// Called by DeviceSession when handshake is complete (after config echo).
    func sendFirstCameraPacket() {
        guard case .connecting = state else { return }
        state = .scanning
        sendNextCameraPacket()
    }

    private func sendNextCameraPacket() {
        guard nextPositionIndex < positions.count else {
            // All positions dispatched — wait for final chunks to arrive
            return
        }
        let pos = positions[nextPositionIndex]
        let posIndex = UInt32(nextPositionIndex + 1)  // 1-based
        nextPositionIndex += 1

        let pkt = CameraPacket(
            positionIndex: posIndex,
            stackCount: stackCount,
            rotorAngle: pos.rotor,
            turntableAngle: pos.turntable
        )
        session.tcp.send(type: .camera, payload: pkt.encode())
        NSLog("📷 CameraPacket \(posIndex)/\(positions.count) rotor=\(pos.rotor)° turntable=\(pos.turntable)°")
    }

    // MARK: - Incoming packet handling

    private func handlePacket(type: PacketType, data: Data) {
        switch type {
        case .command:
            // Config echo from daemon (~600 bytes) = device is ready for camera packets
            if case .connecting = state, data.count > 200 {
                sendFirstCameraPacket()
            }

        case .video:
            // type=0x0D: stream header — marks start of image data for a position
            guard let hdr = VideoHeaderPacket.decode(from: data) else { return }
            NSLog("📹 Stream header: position=\(hdr.positionIndex) stack=\(hdr.stackIndex) compressed=\(hdr.compressedSize)")
            activeStreamPosition = hdr.positionIndex
            activeStreamCompressedSize = Int(hdr.compressedSize)
            activeStreamBuffer = Data()
            activeStreamBuffer.reserveCapacity(activeStreamCompressedSize)

        case .stream:
            // type=0x0E: raw LZ4-compressed image data chunk (up to 65536 bytes each)
            guard let pid = activeStreamPosition else { return }
            activeStreamBuffer.append(data)
            NSLog("📥 Stream chunk \(data.count)b for pos \(pid) (total=\(activeStreamBuffer.count))")
            if activeStreamBuffer.count >= activeStreamCompressedSize {
                finalizeStream()
            }

        case .status:
            if let s = StatusPacket.decode(from: data), !s.isScanning, case .scanning = state {
                // Device reports scan finished before we expected — treat as complete
                if photosReceived == positions.count {
                    state = .complete
                }
            }

        default:
            break
        }
    }

    // MARK: - Stream finalization

    private func finalizeStream() {
        guard let pid = activeStreamPosition else { return }
        let lz4Data = activeStreamBuffer
        activeStreamPosition = nil
        activeStreamBuffer = Data()
        activeStreamCompressedSize = 0

        NSLog("🗜️ Position \(pid): decompressing \(lz4Data.count)b → \(Self.uncompressedSize) expected")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let jpeg = Self.lz4YuvToJpeg(lz4Data) else {
                NSLog("❌ Decompression/conversion failed for position \(pid)")
                return
            }
            NSLog("🖼️ Position \(pid) complete (\(jpeg.count)b JPEG)")
            DispatchQueue.main.async {
                self.photosReceived += 1
                self.onPhotoReceived?(pid, jpeg)
                self.sendNextCameraPacket()
                if self.photosReceived == self.positions.count {
                    self.state = .complete
                    NSLog("✅ Scan complete, \(self.photosReceived) photos")
                }
            }
        }
    }

    // MARK: - Image decoding

    /// Decompresses raw LZ4 block (from liblz4 LZ4_compress_default) → YUV420 → JPEG.
    private static func lz4YuvToJpeg(_ lz4Data: Data) -> Data? {
        // 1. Raw LZ4 block decompression (Apple COMPRESSION_LZ4 uses a different framing)
        var yuv = Data(count: uncompressedSize)
        let decompressed = lz4Data.withUnsafeBytes { src -> Int in
            yuv.withUnsafeMutableBytes { dst -> Int in
                lz4BlockDecompress(
                    src: src.bindMemory(to: UInt8.self).baseAddress!,
                    srcLen: lz4Data.count,
                    dst: dst.bindMemory(to: UInt8.self).baseAddress!,
                    dstLen: uncompressedSize
                )
            }
        }
        guard decompressed == uncompressedSize else {
            NSLog("❌ LZ4 decode: expected \(uncompressedSize), got \(decompressed)")
            return nil
        }

        // 2. YUV420 (I420) → JPEG via CGImage
        return yuv420ToJpeg(yuv, width: captureWidth, height: captureHeight)
    }

    /// Raw LZ4 block decompressor — compatible with liblz4 LZ4_compress_default output.
    private static func lz4BlockDecompress(src: UnsafePointer<UInt8>, srcLen: Int,
                                           dst: UnsafeMutablePointer<UInt8>, dstLen: Int) -> Int {
        var si = 0, di = 0
        while si < srcLen {
            let token = src[si]; si += 1

            // Literal length
            var litLen = Int(token >> 4)
            if litLen == 15 {
                while si < srcLen { let e = Int(src[si]); si += 1; litLen += e; if e < 255 { break } }
            }
            guard si + litLen <= srcLen, di + litLen <= dstLen else { return -1 }
            memcpy(dst + di, src + si, litLen); si += litLen; di += litLen

            if si >= srcLen { break }  // last sequence has no match part

            // Match offset (16-bit LE)
            guard si + 1 < srcLen else { return -1 }
            let offset = Int(src[si]) | (Int(src[si + 1]) << 8); si += 2
            guard offset > 0, di >= offset else { return -1 }

            // Match length
            var matchLen = Int(token & 0x0F) + 4
            if (token & 0x0F) == 15 {
                while si < srcLen { let e = Int(src[si]); si += 1; matchLen += e; if e < 255 { break } }
            }
            guard di + matchLen <= dstLen else { return -1 }

            // Copy match (may overlap — copy byte-by-byte)
            let base = dst + di - offset
            for i in 0..<matchLen { dst[di + i] = base[i] }
            di += matchLen
        }
        return di
    }

    private static func yuv420ToJpeg(_ yuv: Data, width: Int, height: Int) -> Data? {
        let yLen = width * height
        let uvLen = (width / 2) * (height / 2)
        guard yuv.count >= yLen + 2 * uvLen else { return nil }

        // Build RGBA pixel buffer from YUV420 (I420/YV12 plane layout)
        var rgba = Data(count: width * height * 4)
        yuv.withUnsafeBytes { src in
            rgba.withUnsafeMutableBytes { dst in
                let y = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let cb = y.advanced(by: yLen)
                let cr = cb.advanced(by: uvLen)
                let out = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)

                for row in 0..<height {
                    for col in 0..<width {
                        let yi = row * width + col
                        let uvi = (row / 2) * (width / 2) + (col / 2)
                        let yv = Int(y[yi])
                        let u  = Int(cb[uvi]) - 128
                        let v  = Int(cr[uvi]) - 128
                        let r = min(255, max(0, yv + Int(1.402 * Float(v))))
                        let g = min(255, max(0, yv - Int(0.344136 * Float(u)) - Int(0.714136 * Float(v))))
                        let b = min(255, max(0, yv + Int(1.772 * Float(u))))
                        let idx = (row * width + col) * 4
                        out[idx]   = UInt8(r)
                        out[idx+1] = UInt8(g)
                        out[idx+2] = UInt8(b)
                        out[idx+3] = 255
                    }
                }
            }
        }

        // 3. Encode RGBA → JPEG
        guard let provider = CGDataProvider(data: rgba as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        guard let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    // MARK: - Fibonacci sphere position calculation

    /// Returns `count` (rotor, turntable) angle pairs using the golden-angle spiral.
    /// Rotor (azimuth) increments by 137.508° per step.
    /// Turntable (elevation) descends linearly from 0° to -maxElevation.
    static func fibonacciPositions(count: Int, maxElevation: Float) -> [(rotor: Float, turntable: Float)] {
        guard count > 0 else { return [] }
        let goldenAngle: Float = 137.50776
        return (0..<count).map { i in
            let rotor = fmod(Float(i) * goldenAngle, 360.0)
            let turntable = count > 1 ? -(Float(i) / Float(count - 1)) * maxElevation : 0
            return (rotor: rotor, turntable: turntable)
        }
    }
}
