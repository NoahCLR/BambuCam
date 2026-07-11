import AppKit
import BambuKit
import Observation
import SwiftUI

/// Owns only the behavior SwiftUI's window-style MenuBarExtra does not expose:
/// distinct primary and secondary clicks on the status item.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private lazy var contextMenu = makeContextMenu()

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureStatusItem()
        configurePopover()
        observeStatusLabel()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "BambuCam"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(model: model) { [weak self] in
                self?.closePopover()
            }
        )
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
            return
        }

        if let hostingView = popover.contentViewController?.view {
            hostingView.layoutSubtreeIfNeeded()
            popover.contentSize = hostingView.fittingSize
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // The popover window has no collection behavior by default, so when a
        // fullscreen app owns the active space macOS shows it on the desktop
        // space instead. The window only exists after show(), so fix it here.
        popover.contentViewController?.view.window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        DispatchQueue.main.async { [weak self] in
            self?.popover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        closePopover()
        contextMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 2), in: button)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings),
                                  keyEquivalent: ",")
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit BambuCam",
                              action: #selector(quitApplication),
                              keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit BambuCam")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func openSettings() {
        if let openSettings = model.openSettings {
            openSettings()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    private func observeStatusLabel() {
        withObservationTracking {
            updateStatusLabel(connectionState: model.connectionState,
                              progress: model.status?.mcPercent,
                              gcodeState: model.status?.gcodeState)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeStatusLabel()
            }
        }
    }

    private func updateStatusLabel(connectionState: PrinterConnection.ConnectionState,
                                   progress: Int?,
                                   gcodeState: String?) {
        guard let button = statusItem.button else { return }

        if connectionState == .connected,
           gcodeState?.uppercased() == "RUNNING",
           let progress {
            statusItem.length = NSStatusItem.variableLength
            button.image = nil
            button.title = "\(progress)%"
            button.setAccessibilityLabel("BambuCam, printing \(progress) percent")
            return
        }

        statusItem.length = NSStatusItem.squareLength
        button.title = ""
        switch connectionState {
        case .connected:
            button.image = MenuBarIcon.image(for: .connected)
            button.setAccessibilityLabel("BambuCam, connected")
        case .connecting, .degraded:
            button.image = MenuBarIcon.image(for: .connecting)
            button.setAccessibilityLabel("BambuCam, connecting")
        case .disconnected:
            button.image = MenuBarIcon.image(for: .disconnected)
            button.setAccessibilityLabel("BambuCam, disconnected")
        }
        button.imagePosition = .imageOnly
    }
}
