import AppKit

/// Custom menu bar glyph shaped like an FDM 3D printer (gantry frame, hanging
/// extruder, print bed) — SF Symbols only has office printers. Drawn as a
/// template image so the system tints it for menu bar state and appearance.
@MainActor
enum MenuBarIcon {
    enum State {
        case connected
        case connecting
        case disconnected
    }

    static func image(for state: State) -> NSImage {
        switch state {
        case .connected: connected
        case .connecting: connecting
        case .disconnected: disconnected
        }
    }

    private static let connected = draw(extruderAlpha: 1)
    private static let connecting = draw(extruderAlpha: 0.4)
    private static let disconnected = draw(extruderAlpha: 0)

    /// The extruder fades with connection health: solid when connected,
    /// ghosted while (re)connecting, absent when disconnected.
    private static func draw(extruderAlpha: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            // Frame: top gantry bar bridging two columns.
            let frame = NSBezierPath()
            frame.appendRoundedRect(NSRect(x: 1, y: 1, width: 2.5, height: 14.5),
                                    xRadius: 1, yRadius: 1)
            frame.appendRoundedRect(NSRect(x: 14.5, y: 1, width: 2.5, height: 14.5),
                                    xRadius: 1, yRadius: 1)
            frame.appendRoundedRect(NSRect(x: 1, y: 13, width: 16, height: 2.5),
                                    xRadius: 1, yRadius: 1)

            // Print bed between the columns.
            let bed = NSBezierPath(roundedRect: NSRect(x: 5, y: 1, width: 8, height: 2),
                                   xRadius: 0.75, yRadius: 0.75)

            NSColor.black.setFill()
            frame.fill()
            bed.fill()

            if extruderAlpha > 0 {
                // Carriage hanging from the gantry with a tapered nozzle.
                let extruder = NSBezierPath(roundedRect: NSRect(x: 7, y: 10.5, width: 4, height: 2.5),
                                            xRadius: 0.75, yRadius: 0.75)
                let nozzle = NSBezierPath()
                nozzle.move(to: NSPoint(x: 7.6, y: 10.5))
                nozzle.line(to: NSPoint(x: 10.4, y: 10.5))
                nozzle.line(to: NSPoint(x: 9, y: 8.2))
                nozzle.close()

                NSColor.black.withAlphaComponent(extruderAlpha).setFill()
                extruder.fill()
                nozzle.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "3D printer"
        return image
    }
}
