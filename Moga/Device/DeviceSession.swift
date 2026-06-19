import Foundation

// Orchestrates the full lifecycle of a connection to one OpenScan device.
// Sends the Connect handshake, tracks device state, and routes incoming packets.

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
    private(set) var isLightOn: Bool = false

    let config: HardwareConfig
    let tcp = TCPClient()

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

        // Watch TCP state changes
        Task { @MainActor in
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                switch tcp.state {
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
    }

    // MARK: - Hardware commands

    func setLight(on: Bool) {
        let packet = LightPacket(on: on)
        tcp.send(type: .light, payload: packet.encode())
    }

    func moveMotor(_ motor: MotorPacket.MotorID, angle: Float, mode: MotorPacket.Mode = .relative) {
        let packet = MotorPacket(motor: motor, mode: mode, angle: angle, zeroPosition: false)
        tcp.send(type: .motor, payload: packet.encode())
    }

    // MARK: - Private

    private func sendHandshake() {
        let connect = ConnectPacket(protocolVersion: 0, enableLogging: true)
        tcp.send(type: .connect, payload: connect.encode())

        let cfg = ConfigPacket()
        tcp.send(type: .config, payload: cfg.encode())

        state = .ready
    }

    private func handle(type: PacketType, data: Data) {
        switch type {
        case .command:
            if let msg = String(data: data, encoding: .utf8) {
                NSLog("📋 Device command: \(msg.prefix(200))")
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
