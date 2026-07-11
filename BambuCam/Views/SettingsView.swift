import SwiftUI
import ServiceManagement
import BambuKit

struct SettingsView: View {
    @Bindable var model: AppModel

    @State private var name = ""
    @State private var hostname = ""
    @State private var accessCode = ""
    @State private var isAccessCodeVisible = false
    @State private var serial = ""
    @State private var testResult: TestResult?
    @State private var testing = false
    @State private var launchAtLoginError: String?
    @State private var isRevertingLaunchAtLogin = false

    enum TestResult {
        case ok
        case trustRequired(PrinterPairing)
        case failed(String)
    }

    private var formValid: Bool {
        ![name, hostname, accessCode, serial].contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            && PrinterHostValidator.isAllowed(hostname.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        Form {
            Section("Printer") {
                TextField("Name", text: $name)
                TextField("Private IPv4 Address", text: $hostname)
                accessCodeField
                TextField("Serial Number", text: $serial)

                Text("Use the printer's private IPv4 address (for example, 192.168.x.x). BambuCam never sends access codes to hostnames or public addresses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Pair Printer") { discoverCertificates() }
                        .disabled(!formValid || testing)
                    if testing { ProgressView().controlSize(.small) }
                    switch testResult {
                    case .ok:
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let message):
                        Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    case .trustRequired:
                        EmptyView()
                    case nil:
                        EmptyView()
                    }
                }

                if case .trustRequired(let pairing) = testResult {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Trust this printer only while you are on a network you control. These TLS fingerprints will be pinned and any later change will block the connection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("MQTT: \(pairing.mqttFingerprint)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Text("Camera (\(pairing.cameraTransport == .rtsp ? "X1 RTSP, port 322" : "port 6000")): \(pairing.cameraFingerprint)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                        Button("Trust & Test Connection") { trustAndTest(pairing) }
                            .disabled(testing)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .onChange(of: name) {
                testResult = nil
                renamePairedPrinter()
            }
            .onChange(of: hostname) { testResult = nil }
            .onChange(of: accessCode) { testResult = nil }
            .onChange(of: serial) { testResult = nil }

            Section("Printer Commands") {
                Toggle("LAN Developer Mode", isOn: developerModeBinding)
                    .disabled(model.activePrinter == nil)
                Text("Recent printer firmware rejects pause, resume, stop and speed commands from local apps unless Developer Mode (with LAN Only Mode) is enabled on the printer's screen. Leave this off to hide those controls; the chamber light always works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Print finished", isOn: $model.config.notifications.finished)
                Toggle("Print failed", isOn: $model.config.notifications.failed)
                Toggle("Connection lost", isOn: $model.config.notifications.connectionLost)
                Toggle("Progress milestones (25/50/75%)", isOn: $model.config.notifications.milestones)
            }

            Section("Slicer") {
                HStack {
                    if let name = model.slicerName {
                        Label(name, systemImage: "cube")
                    } else {
                        Text("No slicer selected")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose…") { chooseSlicer() }
                    if model.config.slicerPath != nil {
                        Button("Clear") { model.config.slicerPath = nil }
                    }
                }
                Text("Opened by the slicer button in the main window and menu bar — pick Bambu Studio, OrcaSlicer, or any other app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $model.config.launchAtLogin)
                    .onChange(of: model.config.launchAtLogin) { _, enabled in
                        if isRevertingLaunchAtLogin {
                            isRevertingLaunchAtLogin = false
                            return
                        }
                        setLaunchAtLogin(enabled)
                    }
                if let launchAtLoginError {
                    Label(launchAtLoginError, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear(perform: loadDraft)
    }

    private func chooseSlicer() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose the slicer app to open from BambuCam"
        if panel.runModal() == .OK, let url = panel.url {
            model.config.slicerPath = url.path
        }
    }

    @ViewBuilder private var accessCodeField: some View {
        if isAccessCodeVisible {
            TextField("Access Code", text: $accessCode)
                .accessCodeVisibilityToggle(isVisible: $isAccessCodeVisible)
        } else {
            SecureField("Access Code", text: $accessCode)
                .accessCodeVisibilityToggle(isVisible: $isAccessCodeVisible)
        }
    }

    private var developerModeBinding: Binding<Bool> {
        Binding(
            get: { model.activePrinter?.developerMode ?? false },
            set: { enabled in
                guard var printer = model.activePrinter else { return }
                printer.developerMode = enabled
                model.config.printers = [printer]
            }
        )
    }

    private func loadDraft() {
        guard let printer = model.activePrinter else {
            // A new code has no secret to protect yet, so make it easy to
            // verify while it is being entered.
            isAccessCodeVisible = true
            return
        }
        name = printer.name
        hostname = printer.hostname
        accessCode = model.accessCode(for: printer) ?? ""
        serial = printer.serial
        isAccessCodeVisible = accessCode.isEmpty
    }

    /// The name is not part of the printer's identity, so edits apply to an
    /// already-paired printer immediately instead of waiting for a re-pair.
    private func renamePairedPrinter() {
        guard var printer = model.activePrinter else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != printer.name else { return }
        printer.name = trimmed
        model.config.printers = [printer]
    }

    private func draftPrinter() -> PrinterConfig {
        var printer = model.activePrinter
            ?? PrinterConfig(name: name, hostname: hostname, serial: serial)
        printer.name = name.trimmingCharacters(in: .whitespaces)
        printer.hostname = hostname.trimmingCharacters(in: .whitespaces)
        printer.serial = serial.trimmingCharacters(in: .whitespaces)
        return printer
    }

    /// Retrieves certificate fingerprints without ever sending the access code.
    private func discoverCertificates() {
        testing = true
        testResult = nil
        Task {
            do {
                let pairing = try await PrinterPairing.discover(
                    hostname: hostname.trimmingCharacters(in: .whitespaces)
                )
                testResult = .trustRequired(pairing)
            } catch PrinterPairingError.cameraUnavailable {
                testResult = .failed("Printer found, but its camera isn't answering — try rebooting the printer. On X1, enable LAN Mode Liveview first.")
            } catch {
                testResult = .failed("Couldn't reach the printer — check the address")
            }
            testing = false
        }
    }

    /// The password is used only after the user has explicitly accepted both
    /// certificate fingerprints shown above.
    private func trustAndTest(_ pairing: PrinterPairing) {
        testing = true
        let printer = draftPrinter()
        let code = accessCode.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try model.savePairedPrinter(printer, accessCode: code, pairing: pairing)
                let client = PrinterClient(hostname: printer.hostname,
                                           accessCode: code,
                                           serial: printer.serial,
                                           certificateDER: pairing.mqttCertificateDER)
                try await client.connect()
                await client.disconnect()
                testResult = .ok
            } catch {
                testResult = .failed("Connection failed")
            }
            testing = false
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Couldn't change launch at login"
            isRevertingLaunchAtLogin = true
            model.config.launchAtLogin = !enabled
        }
    }
}

private extension View {
    func accessCodeVisibilityToggle(isVisible: Binding<Bool>) -> some View {
        padding(.trailing, 30)
            .overlay(alignment: .trailing) {
                Button {
                    isVisible.wrappedValue.toggle()
                } label: {
                    Image(systemName: isVisible.wrappedValue ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(isVisible.wrappedValue ? "Hide access code" : "Show access code")
                .accessibilityLabel(isVisible.wrappedValue ? "Hide access code" : "Show access code")
            }
    }
}
