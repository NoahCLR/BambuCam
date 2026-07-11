import SwiftUI

/// Camera image that fits inside the window. All zooming — click, scroll
/// wheel, pinch — anchors at the pointer: the image point under the cursor
/// stays put while the rest scales around it. Click toggles between 1x and
/// 2.5x; drag pans while zoomed. Reports whether any zoom is active via
/// `isZoomed` so the container can hide its chrome.
struct CameraView: View {
    let image: NSImage?
    let placeholderText: String
    @Binding var isZoomed: Bool

    @State private var zoom: CGFloat = 1
    @State private var steadyPan: CGSize = .zero
    @State private var pointerLocation: CGPoint?
    @State private var lastMagnification: CGFloat = 1
    @GestureState private var gesturePan: CGSize = .zero

    private let clickZoom: CGFloat = 2.5
    private let maxZoom: CGFloat = 10

    private var effectivePan: CGSize {
        CGSize(width: steadyPan.width + gesturePan.width,
               height: steadyPan.height + gesturePan.height)
    }

    /// Clamps `pan` so the zoomed image always keeps substantial overlap with
    /// the container. The bound per axis is the natural limit for a
    /// scaledToFit image filling the container at the given zoom.
    private func clampedPan(_ pan: CGSize, zoom: CGFloat, in size: CGSize) -> CGSize {
        let maxX = (zoom - 1) * size.width / 2
        let maxY = (zoom - 1) * size.height / 2
        return CGSize(width: min(max(pan.width, -maxX), maxX),
                      height: min(max(pan.height, -maxY), maxY))
    }

    /// Scales by `factor` while keeping the image point under `point` fixed.
    /// With the view rendered as scale(zoom, anchor: center) + offset(pan),
    /// the pan that pins `point` across a zoom change z1 -> z2 is
    /// pan2 = (p - c)(1 - r) + pan1 * r, where r = z2/z1 and c is the center.
    private func zoomToward(_ point: CGPoint?, factor: CGFloat, in size: CGSize) {
        // A NaN would stick forever (every clamp comparison is false, and
        // click-reset checks zoom > 1.001), rendering an unrecoverable black
        // view — MagnifyGesture can report magnification 0, whose incremental
        // division produces one.
        guard factor.isFinite, factor > 0, size.width > 1, size.height > 1 else { return }
        let oldZoom = zoom
        let newZoom = min(max(oldZoom * factor, 1), maxZoom)
        guard newZoom.isFinite, newZoom != oldZoom else { return }
        if newZoom == 1 {
            zoom = 1
            steadyPan = .zero
            return
        }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let p = point ?? center
        let ratio = newZoom / oldZoom
        let pan = CGSize(width: (p.x - center.x) * (1 - ratio) + steadyPan.width * ratio,
                         height: (p.y - center.y) * (1 - ratio) + steadyPan.height * ratio)
        zoom = newZoom
        steadyPan = clampedPan(pan, zoom: newZoom, in: size)
    }

    private func resetZoom() {
        zoom = 1
        steadyPan = .zero
    }

    var body: some View {
        GeometryReader { proxy in
            dragAwareSurface(in: proxy.size) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Color.black.overlay {
                            Text(placeholderText).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(zoom, anchor: .center)
                .offset(effectivePan)
                .clipped()
                .contentShape(Rectangle())
                .background {
                    ScrollWheelCatcher { deltaY in
                        zoomToward(pointerLocation, factor: exp(deltaY * 0.01), in: proxy.size)
                    }
                    .allowsHitTesting(false)
                }
            }
            .simultaneousGesture(cameraMagnifyGesture(in: proxy.size))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    pointerLocation = location
                case .ended:
                    pointerLocation = nil
                }
            }
            .onChange(of: zoom, initial: true) { _, newZoom in
                isZoomed = newZoom > 1.001
            }
        }
        .background(.black)
    }

    /// At 1x the camera itself is the window's drag surface. Once zoomed, the
    /// same drag input pans the image instead, while taps and magnification
    /// continue to work in both states.
    @ViewBuilder
    private func dragAwareSurface<Content: View>(
        in size: CGSize,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if zoom > 1.001 {
            content()
                .gesture(cameraTapGesture(in: size))
                .simultaneousGesture(
                    DragGesture()
                        .updating($gesturePan) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            let candidate = CGSize(
                                width: steadyPan.width + value.translation.width,
                                height: steadyPan.height + value.translation.height
                            )
                            steadyPan = clampedPan(candidate, zoom: zoom, in: size)
                        }
                )
        } else {
            content()
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(WindowDragGesture())
                        .simultaneousGesture(cameraTapGesture(in: size))
                        .allowsWindowActivationEvents()
                }
        }
    }

    private func cameraMagnifyGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let magnification = max(value.magnification, 0.01)
                let factor = magnification / max(lastMagnification, 0.01)
                lastMagnification = magnification
                zoomToward(pointerLocation, factor: factor, in: size)
            }
            .onEnded { _ in
                lastMagnification = 1
            }
    }

    private func cameraTapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                withAnimation(.snappy(duration: 0.18)) {
                    // Last-resort escape hatch: any non-sane state resets
                    // rather than compounding.
                    if zoom > 1.001 || !zoom.isFinite {
                        resetZoom()
                    } else {
                        zoomToward(value.location, factor: clickZoom, in: size)
                    }
                }
            }
    }
}

/// Invisible view that observes scroll-wheel events over its bounds via a local
/// event monitor, without participating in hit testing (so clicks, drags, and
/// hover on the camera keep working).
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class MonitorView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                installMonitorIfNeeded()
            } else {
                removeMonitor()
            }
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(point) {
                    self.onScroll?(event.scrollingDeltaY)
                }
                return event
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
