import Foundation

// Manages the TCP connection lifecycle and handshake with one OpenScan device.
// After the device echoes the config back (command packet >200 bytes), it is
// ready to accept CameraPackets — this is signalled via onReady.

@Observable
final class DeviceSession {
    enum State {
        case disconnected
        case connecting
        case ready
        case scanning
        case failed(String)
    }

    private(set) var state: State = .disconnected
    var isLightOn: Bool = false
    private var sentCameraSetup = false

    let config: HardwareConfig
    let tcp = TCPClient()

    /// Called once when the device echoes the config and is ready for scan commands.
    var onReady: (() -> Void)?

    init(config: HardwareConfig) {
        self.config = config
        tcp.onPacket = { [weak self] type, data in
            self?.handle(type: type, data: data)
        }
    }

    // MARK: - Connect / Disconnect

    func connect() {
        guard case .disconnected = state else { return }
        state = .connecting

        tcp.connect(host: config.hostname, port: config.port)

        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                switch self.tcp.state {
                case .connected:
                    self.sendHandshake()
                    return
                case .failed(let error):
                    self.state = .failed(error.localizedDescription)
                    return
                default:
                    break
                }
            }
        }
    }

    func disconnect() {
        tcp.send(type: .disconnect)
        tcp.disconnect()
        state = .disconnected
        sentCameraSetup = false
    }

    // MARK: - Hardware commands

    func setLight(on: Bool) {
        isLightOn = on
        // Inner ring (index 0) — send one at a time; outer ring sent separately
        tcp.send(type: .light, payload: LightPacket(lightIndex: 0, on: on).encode())
        tcp.send(type: .light, payload: LightPacket(lightIndex: 1, on: on).encode())
    }

    func moveMotor(_ motor: MotorPacket.MotorID, angle: Float, relative: Bool = true) {
        let pkt = MotorPacket(motor: motor, angle: angle, mode: relative ? 0 : 1, setZero: 0)
        tcp.send(type: .motor, payload: pkt.encode())
    }

    /// Marks the current physical position as the 0° reference for this motor.
    /// Does NOT move the motor.
    func zeroMotor(_ motor: MotorPacket.MotorID) {
        let pkt = MotorPacket(motor: motor, angle: 0, mode: 1, setZero: 1)
        tcp.send(type: .motor, payload: pkt.encode())
    }

    // MARK: - Private

    private func sendHandshake() {
        tcp.send(type: .connect, payload: ConnectPacket(protocolVersion: 0, enableLogging: true).encode())
        tcp.send(type: .config, payload: ConfigPacket().encode())
        // State stays .connecting; .ready is set after config echo arrives
    }

    private func handle(type: PacketType, data: Data) {
        switch type {
        case .command:
            if let msg = String(data: data, encoding: .utf8) {
                NSLog("📋 Device command: \(msg.prefix(200))")
            }
            // Config echo is the first large command (>200 bytes) from the daemon.
            // Send camera setup exactly once — guard against re-trigger from later
            // large messages like "Available cameras" (also >200 bytes).
            if case .connecting = state, !sentCameraSetup, data.count > 200 {
                sentCameraSetup = true
                tcp.send(type: .motor, payload: CameraSetupPacket().encode())
            }
            // Camera setup ack contains "camera configuration packet".
            if case .connecting = state,
               let msg = String(data: data, encoding: .utf8),
               msg.contains("camera configuration packet") {
                state = .ready
                onReady?()
            }
        case .info:
            NSLog("ℹ️ Device info packet (\(data.count) bytes)")
        case .status:
            if let status = StatusPacket.decode(from: data) {
                state = status.isScanning ? .scanning : .ready
            }
        case .light:
            isLightOn = data.first == 1
        default:
            break
        }
    }
}
