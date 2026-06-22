import SwiftUI
import AppKit

struct ScanView: View {
    let session: DeviceSession
    let focusConfig: FocusStackConfig
    let projectManager: ProjectManager

    @State private var selectedPattern: ScanPattern = .fibonacci
    @State private var photoCount: Int = 100
    @State private var photoCountText: String = "100"
    @State private var projectName: String = ""
    @State private var outputFolder: URL? = nil
    @State private var controller: ScanController? = nil
    @State private var currentProject: MogaProject? = nil
    @State private var progress: Double = 0

    private var outputFolderLabel: String {
        outputFolder?.path(percentEncoded: false) ?? "~/Documents/Moga Projects (default)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("New Scan").font(.title2).bold()

                // Project name + output folder
                GroupBox("Project") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Project name", text: $projectName)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(outputFolderLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Choose…") { chooseOutputFolder() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            if outputFolder != nil {
                                Button("Reset") { outputFolder = nil }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                    .padding(4)
                }

                // Scan pattern
                GroupBox("Scan Pattern") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Pattern", selection: $selectedPattern) {
                            ForEach(ScanPattern.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 8) {
                            Text("Photos")
                            TextField("", text: $photoCountText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                                .onSubmit { commitPhotoCount() }
                                .onChange(of: photoCountText) { _, _ in commitPhotoCount() }
                            Stepper("", value: $photoCount, in: 1...999)
                                .labelsHidden()
                                .onChange(of: photoCount) { _, v in
                                    photoCountText = "\(v)"
                                }
                        }
                    }
                    .padding(4)
                }

                // Focus stacking
                FocusStackConfigView(config: focusConfig)

                // Motor controls
                MotorControlsView(session: session)

                // Light control
                GroupBox("Lighting") {
                    HStack {
                        Text("Ring Light")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { session.isLightOn },
                            set: { session.setLight(on: $0) }
                        ))
                    }
                    .padding(4)
                }

                // Scan progress
                if let ctrl = controller {
                    GroupBox("Progress") {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: progress)
                            Text("\(ctrl.photosReceived) / \(photoCount) photos")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(4)
                    }
                }

                // Start button
                HStack {
                    Spacer()
                    Button(controller == nil ? "Start Scan" : "Cancel") {
                        controller == nil ? startScan() : cancelScan()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(controller == nil ? .accentColor : .red)
                    .disabled(projectName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
        }
    }

    private func commitPhotoCount() {
        if let n = Int(photoCountText), n >= 1, n <= 999 {
            photoCount = n
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Output Folder"
        panel.message = "Photos from this scan will be saved inside the chosen folder."
        if panel.runModal() == .OK {
            outputFolder = panel.url
        }
    }

    private func startScan() {
        guard let project = try? projectManager.createProject(
            name: projectName.trimmingCharacters(in: .whitespaces),
            photoCount: photoCount,
            pattern: selectedPattern.rawValue,
            focusStack: focusConfig.enabled,
            stackSize: focusConfig.clampedStackSize,
            outputFolder: outputFolder
        ) else { return }

        currentProject = project
        let ctrl = ScanController(session: session)
        ctrl.onPhotoReceived = { (photoIndex: UInt32, jpeg: Data) in
            progress = min(1.0, Double(ctrl.photosReceived) / Double(photoCount))
            try? projectManager.savePhoto(jpeg, project: project,
                                          positionIndex: Int(photoIndex), stackIndex: 0)
        }
        ctrl.onScanComplete = {
            // Return rotor to 0° (absolute) after scan finishes
            session.moveMotor(.rotor, angle: 0, mode: .absolute)
            controller = nil
        }
        controller = ctrl
        ctrl.start(photoCount: photoCount,
                   stackSize: UInt32(focusConfig.clampedStackSize))
    }

    private func cancelScan() {
        controller?.cancel()
        controller = nil
        progress = 0
    }
}

// MARK: - Motor controls

struct MotorControlsView: View {
    let session: DeviceSession
    @State private var rotorTarget: String = "0"
    @State private var turntableTarget: String = "0"

    var body: some View {
        GroupBox("Motor Controls") {
            VStack(spacing: 0) {
                Text("Use these to position the rotor at the equator (0°) before starting a scan. The rotor returns to 0° automatically after the scan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 10)

                motorRow(label: "Rotor", motor: .rotor, targetText: $rotorTarget)
                Divider().padding(.vertical, 6)
                motorRow(label: "Turntable", motor: .turntable, targetText: $turntableTarget)
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private func motorRow(label: String, motor: MotorPacket.MotorID, targetText: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .frame(width: 72, alignment: .leading)
                .font(.caption.bold())

            // Zero
            Button("Z") { session.moveMotor(motor, angle: 0, mode: .absolute) }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Move to 0°")

            Divider().frame(height: 20)

            // Step back
            ForEach([-45, -10, -1], id: \.self) { deg in
                Button("\(deg)°") { session.moveMotor(motor, angle: Float(deg), mode: .relative) }
                    .buttonStyle(.bordered).controlSize(.small)
            }

            Divider().frame(height: 20)

            // Step forward
            ForEach([1, 10, 45], id: \.self) { deg in
                Button("+\(deg)°") { session.moveMotor(motor, angle: Float(deg), mode: .relative) }
                    .buttonStyle(.bordered).controlSize(.small)
            }

            Divider().frame(height: 20)

            // Absolute move
            TextField("0", text: targetText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
            Text("°").foregroundStyle(.secondary)
            Button("Move") {
                if let deg = Float(targetText.wrappedValue) {
                    session.moveMotor(motor, angle: deg, mode: .absolute)
                }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
    }
}
