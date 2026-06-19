import Foundation

// MARK: - Packet type identifiers (8-byte header: type UInt32 + length UInt32)

enum PacketType: UInt32 {
    case connect    = 0x00
    case disconnect = 0x01
    case config     = 0x02
    case hardware   = 0x03
    case pin        = 0x04
    case light      = 0x05
    case motor      = 0x06
    case camera     = 0x07
    case params     = 0x08
    case photo      = 0x09
    case capture    = 0x0A
    case data       = 0x0B
    case chunk      = 0x0C
    case video      = 0x0D
    case stream     = 0x0E
    case metadata   = 0x0F
    case command    = 0x10
    case info       = 0x11
    case status     = 0x12
}

// MARK: - Packet header

struct PacketHeader {
    let type: PacketType
    let totalSize: UInt32   // total packet size including this 8-byte header

    static let size = 8

    var payloadSize: Int { max(0, Int(totalSize) - Self.size) }

    func encode() -> Data {
        var data = Data(count: 8)
        data.writeUInt32(type.rawValue, at: 0)
        data.writeUInt32(totalSize, at: 4)
        return data
    }

    static func decode(from data: Data) -> PacketHeader? {
        guard data.count >= size,
              let type = PacketType(rawValue: data.readUInt32(at: 0)) else { return nil }
        return PacketHeader(type: type, totalSize: data.readUInt32(at: 4))
    }
}

// MARK: - Individual packet payloads

struct ConnectPacket {
    let protocolVersion: UInt32  // 0 as observed in Windows client capture
    let enableLogging: Bool      // 1 byte bool

    func encode() -> Data {
        var d = Data(count: 5)
        d.writeUInt32(protocolVersion, at: 0)
        d[4] = enableLogging ? 1 : 0
        return d
    }
}

// ConfigPacket — sent immediately after Connect. Layout verified by Wireshark capture.
// Field order in binary differs from echo display order.
struct ConfigPacket {
    var controllerType: UInt32 = 0
    var cameraType: UInt32 = 1
    var pinExternalCamera: UInt32 = 10
    var pinLight1: UInt32 = 17
    var pinLight2: UInt32 = 27
    var pinRotorDirection: UInt32 = 5
    var pinRotorStep: UInt32 = 6
    var pinRotorEnable: UInt32 = 0
    var pinTurntableDirection: UInt32 = 9
    var pinTurntableStep: UInt32 = 11
    var pinTurntableEnable: UInt32 = 0
    var pinEndstopLo: UInt32 = 0
    var pinEndstopHi: UInt32 = 0
    var pinLightFan: UInt32 = 0
    var pinCaseFan: UInt32 = 0
    var rotorStepsPerRotation: UInt32 = 48000
    var rotorDelay: UInt32 = 50
    var rotorAcceleration: Float = 1.0
    var rotorRamp: UInt32 = 1000
    var rotorReversed: Bool = false
    var turntableStepsPerRotation: UInt32 = 3200
    var turntableDelay: UInt32 = 50
    var turntableAcceleration: Float = 1.0
    var turntableRamp: UInt32 = 500
    var turntableReversed: Bool = false
    var caseFanThreshold: UInt32 = 50
    var transferCompression: Bool = true

    func encode() -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) }) }
        func f32(_ v: Float)  { var x = v.bitPattern.littleEndian; d.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) }) }
        func u8 (_ v: Bool)   { d.append(v ? 1 : 0) }

        u32(controllerType); u32(cameraType)
        u32(pinExternalCamera); u32(pinLight1); u32(pinLight2)
        u32(pinRotorDirection); u32(pinRotorStep); u32(pinRotorEnable)
        u32(pinTurntableDirection); u32(pinTurntableStep); u32(pinTurntableEnable)
        u32(pinEndstopLo); u32(pinEndstopHi); u32(pinLightFan); u32(pinCaseFan)
        u32(rotorStepsPerRotation); u32(rotorDelay); f32(rotorAcceleration); u32(rotorRamp); u8(rotorReversed)
        u32(turntableStepsPerRotation); u32(turntableDelay); f32(turntableAcceleration); u32(turntableRamp); u8(turntableReversed)
        u32(caseFanThreshold); u8(transferCompression)
        d.append(1) // observed trailing byte in Windows client capture
        return d   // 100 bytes
    }
}

struct DisconnectPacket {
    func encode() -> Data { Data() }
}

struct LightPacket {
    let on: Bool
    func encode() -> Data { Data([on ? 1 : 0]) }
}

struct MotorPacket {
    enum MotorID: UInt8 { case rotor = 0, turntable = 1 }
    enum Mode: UInt8 { case relative = 0, absolute = 1 }

    let motor: MotorID
    let mode: Mode
    let angle: Float   // degrees
    let zeroPosition: Bool

    func encode() -> Data {
        var d = Data(count: 7)
        d[0] = motor.rawValue
        d[1] = mode.rawValue
        d.writeFloat(angle, at: 2)
        d[6] = zeroPosition ? 1 : 0
        return d
    }
}

struct PhotoPacket {
    let focusDiopters: Float   // focus distance in diopters
    let rotorAngle: Float
    let turntableAngle: Float
    let delayMs: UInt16
    let stackIndex: UInt16

    func encode() -> Data {
        var d = Data(count: 18)
        d.writeFloat(focusDiopters, at: 0)
        d.writeFloat(rotorAngle, at: 4)
        d.writeFloat(turntableAngle, at: 8)
        d.writeUInt16(delayMs, at: 12)
        d.writeUInt16(stackIndex, at: 14)
        return d
    }
}

struct CapturePacket {
    let positionIndex: UInt32
    func encode() -> Data {
        var d = Data(count: 4)
        d.writeUInt32(positionIndex, at: 0)
        return d
    }
}

struct ChunkPacket {
    let positionIndex: UInt32
    let stackIndex: UInt16
    let chunkIndex: UInt16
    let totalChunks: UInt16
    let payload: Data

    static func decode(from data: Data) -> ChunkPacket? {
        guard data.count >= 10 else { return nil }
        return ChunkPacket(
            positionIndex: data.readUInt32(at: 0),
            stackIndex:    data.readUInt16(at: 4),
            chunkIndex:    data.readUInt16(at: 6),
            totalChunks:   data.readUInt16(at: 8),
            payload:       data.subdata(in: 10..<data.count)
        )
    }
}

struct StatusPacket {
    let isScanning: Bool
    let isConnected: Bool

    static func decode(from data: Data) -> StatusPacket? {
        guard data.count >= 2 else { return nil }
        return StatusPacket(isScanning: data[0] == 1, isConnected: data[1] == 1)
    }
}

// MARK: - Data helpers (little-endian, matching Windows/RPi native byte order)

extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: offset..<offset+4) }
        return UInt32(littleEndian: value)
    }

    func readUInt16(at offset: Int) -> UInt16 {
        var value: UInt16 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: offset..<offset+2) }
        return UInt16(littleEndian: value)
    }

    func readFloat(at offset: Int) -> Float {
        let bits = readUInt32(at: offset)
        return Float(bitPattern: bits)
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { bytes in
            replaceSubrange(offset..<offset+4, with: bytes)
        }
    }

    mutating func writeUInt16(_ value: UInt16, at offset: Int) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { bytes in
            replaceSubrange(offset..<offset+2, with: bytes)
        }
    }

    mutating func writeFloat(_ value: Float, at offset: Int) {
        writeUInt32(value.bitPattern, at: offset)
    }
}
