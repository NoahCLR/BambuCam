import AppKit
@preconcurrency import AVKit
import BambuKit
import CoreMedia
import ImageIO
import os

/// Drives native macOS Picture in Picture for the printer camera.
///
/// System PiP requires an `AVSampleBufferDisplayLayer` living in a real window,
/// so this owns a tiny invisible host window that exists independently of the
/// app's visible scenes — PiP can start from the menu bar with everything else
/// closed. Incoming frames are wrapped in `CMSampleBuffer`s without
/// re-encoding — JPEG stills as `kCMVideoCodecType_JPEG`, H.264 access units
/// against their parameter-set format description — and only while PiP is on
/// screen; the layer decodes in hardware either way.
@MainActor
final class PiPController: NSObject {
    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Fired when the PiP window appears/disappears (drives viewer refcount + UI state).
    var onPresentedChanged: ((Bool) -> Void)?
    /// Fired when the user clicks the PiP "return to app" button.
    var onRestoreRequested: (() -> Void)?
    /// Fired when PiP could not start.
    var onError: (() -> Void)?

    private(set) var isPresented = false

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var hostView: NSView?
    private var hostWindow: NSWindow?
    private var controller: AVPictureInPictureController?
    private var startTask: Task<Void, Never>?
    private var panelResizeObserver: (any NSObjectProtocol)?

    private static let hostSize = CGSize(width: 320, height: 180)

    /// Whether frames should currently be enqueued. Set once PiP begins
    /// starting so the layer has content for the system to grab.
    private var wantsFrames = false
    private var lastFrame: CameraFrame?
    /// The newest independently decodable frame: any JPEG, or the last IDR
    /// access unit. This is what start/resume replays — a non-IDR unit would
    /// render garbage without its preceding GOP.
    private var lastSyncFrame: CameraFrame?
    /// After a replay or a renderer flush, non-IDR H.264 frames are dropped
    /// until the stream reaches its next IDR.
    private var awaitingIDR = false
    private var cachedJPEGFormat: (size: CGSize, description: CMVideoFormatDescription)?
    private var cachedH264Format: (sps: Data, pps: Data, description: CMVideoFormatDescription)?

    /// PiP pause state; read synchronously by nonisolated playback-delegate
    /// callbacks, hence lock-guarded instead of main-actor state.
    private let paused = OSAllocatedUnfairLock(initialState: false)

    // MARK: - Control

    func toggle() {
        isPresented || startTask != nil ? stop() : start()
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        wantsFrames = false
        controller?.stopPictureInPicture()
    }

    private func start() {
        prepareIfNeeded()
        guard let controller else { return }
        hostWindow?.orderFrontRegardless()
        wantsFrames = true
        paused.withLock { $0 = false }
        replayLastFrame()

        // isPictureInPicturePossible flips asynchronously once the layer is
        // in a window and has media; poll briefly rather than KVO plumbing.
        startTask = Task { [weak self] in
            for _ in 0..<20 {
                guard let self, !Task.isCancelled else { return }
                if controller.isPictureInPicturePossible {
                    controller.startPictureInPicture()
                    self.startTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled else { return }
            self.startTask = nil
            self.wantsFrames = false
            self.onError?()
        }
    }

    /// Feed one camera frame. Cheap no-op unless PiP is up.
    func ingest(_ frame: CameraFrame) {
        lastFrame = frame
        switch frame {
        case .jpeg:
            lastSyncFrame = frame
        case .h264(let accessUnit):
            if accessUnit.isIDR { lastSyncFrame = frame }
        }
        guard wantsFrames, !paused.withLock({ $0 }) else { return }
        if case .h264(let accessUnit) = frame, awaitingIDR {
            guard accessUnit.isIDR else { return }
            awaitingIDR = false
        }
        enqueue(frame)
    }

    // MARK: - Frame plumbing

    /// Repaints from the newest decodable frame. If that frame is a stale
    /// IDR the picture holds still until the stream's next IDR — enqueueing
    /// the intervening non-IDR frames would corrupt instead.
    private func replayLastFrame() {
        guard let lastSyncFrame else { return }
        enqueue(lastSyncFrame)
        if case .h264 = lastSyncFrame { awaitingIDR = lastSyncFrame != lastFrame }
    }

    private func enqueue(_ frame: CameraFrame) {
        guard let renderer = displayLayer?.sampleBufferRenderer,
              let sample = makeSampleBuffer(for: frame)
        else { return }
        if renderer.status == .failed {
            renderer.flush()
            if case .h264(let accessUnit) = frame {
                awaitingIDR = !accessUnit.isIDR
                guard accessUnit.isIDR else { return }
            }
        }
        renderer.enqueue(sample)
    }

    private func makeSampleBuffer(for frame: CameraFrame) -> CMSampleBuffer? {
        switch frame {
        case .jpeg(let data):
            guard let format = jpegFormatDescription(for: data) else { return nil }
            return makeSampleBuffer(data: data, format: format, isSync: true)
        case .h264(let accessUnit):
            guard let format = h264FormatDescription(sps: accessUnit.sps, pps: accessUnit.pps)
            else { return nil }
            return makeSampleBuffer(data: accessUnit.data, format: format, isSync: accessUnit.isIDR)
        }
    }

    private static func isPIPPanel(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("PIPPanel")
    }

    /// Pixel dimensions from the JPEG header only (no decode), cached while
    /// the camera resolution is stable.
    private func jpegFormatDescription(for jpeg: Data) -> CMVideoFormatDescription? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let size = CGSize(width: width, height: height)
        if let cachedJPEGFormat, cachedJPEGFormat.size == size { return cachedJPEGFormat.description }

        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                    codecType: kCMVideoCodecType_JPEG,
                                                    width: Int32(width),
                                                    height: Int32(height),
                                                    extensions: nil,
                                                    formatDescriptionOut: &description)
        guard status == noErr, let description else { return nil }
        cachedJPEGFormat = (size, description)
        return description
    }

    private func h264FormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        if let cachedH264Format, cachedH264Format.sps == sps, cachedH264Format.pps == pps {
            return cachedH264Format.description
        }

        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { (spsBytes: UnsafeRawBufferPointer) in
            pps.withUnsafeBytes { (ppsBytes: UnsafeRawBufferPointer) in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                                ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                // 4-byte NAL length prefixes, matching the AVCC access units.
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else { return nil }
        cachedH264Format = (sps, pps, description)
        return description
    }

    private func makeSampleBuffer(data: Data, format: CMVideoFormatDescription,
                                  isSync: Bool) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: data.count,
                                                 flags: 0,
                                                 blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let blockBuffer
        else { return nil }

        let copied = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: data.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                        dataBuffer: blockBuffer,
                                        formatDescription: format,
                                        sampleCount: 1,
                                        sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer
        else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [CFMutableDictionary],
           let first = attachments.first {
            CFDictionarySetValue(first,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !isSync {
                CFDictionarySetValue(first,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sampleBuffer
    }

    // MARK: - Host window

    private func prepareIfNeeded() {
        guard hostWindow == nil else { return }

        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect

        // AVKit's PIPPanel wraps this view in an
        // AVPictureInPictureSampleBufferDisplayLayerHostView that drives all
        // geometry itself. It needs the display layer as the view's backing
        // layer and autoresizing enabled; manual frame management here fights
        // its layout pass (SIGTRAP in _updateGeometryIfNeeded) and leaves
        // stale black regions in the panel.
        let contentRect = NSRect(origin: .zero, size: Self.hostSize)
        let view = NSView(frame: contentRect)
        view.layer = layer
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]

        let window = NSWindow(contentRect: contentRect,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = view

        displayLayer = layer
        hostView = view
        hostWindow = window

        // The PIP panel renders a CALayerHost *mirror* of our layer, verbatim
        // at source size — it never scales. The hidden source window has to
        // track the panel size for the video to fill it. Deferred a runloop
        // turn so we never mutate geometry inside the panel's layout pass
        // (doing so traps in AVKit's _updateGeometryIfNeeded).
        panelResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow, Self.isPIPPanel(window) else { return }
            let size = window.contentView?.bounds.size ?? window.frame.size
            Task { @MainActor [weak self] in self?.syncSource(to: size) }
        }

        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer,
                                                                playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.requiresLinearPlayback = true
        controller.delegate = self
        self.controller = controller
    }

    private func syncSource(to panelSize: CGSize) {
        neutralizeStrayPanelChrome()
        guard isPresented || wantsFrames,
              let hostWindow,
              panelSize.width > 1, panelSize.height > 1,
              hostWindow.frame.size != panelSize
        else { return }
        hostWindow.setContentSize(panelSize)
    }

    /// AVKit leaves an AVPictureInPictureCALayerHostView in the panel with an
    /// opaque black backing layer frozen at the source's initial size (its
    /// geometry updater doesn't handle sample-buffer sources properly) — it
    /// renders as a stationary black box above the video. It carries no
    /// content for us; hide it. Idempotent, re-checked on every panel resize.
    private func neutralizeStrayPanelChrome() {
        guard let panel = NSApp.windows.first(where: { Self.isPIPPanel($0) }),
              let content = panel.contentView else { return }
        hideStrayChrome(in: content)
    }

    private func hideStrayChrome(in view: NSView) {
        for sub in view.subviews {
            if String(describing: type(of: sub)) == "AVPictureInPictureCALayerHostView" {
                sub.isHidden = true
            } else {
                hideStrayChrome(in: sub)
            }
        }
    }

    private func handlePresented(_ presented: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented
        if presented {
            if let panel = NSApp.windows.first(where: { Self.isPIPPanel($0) }) {
                syncSource(to: panel.contentView?.bounds.size ?? panel.frame.size)
            }
        } else {
            wantsFrames = false
            hostWindow?.orderOut(nil)
            hostWindow?.setContentSize(Self.hostSize)
        }
        onPresentedChanged?(presented)
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.handlePresented(true) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.handlePresented(false) }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: any Error) {
        Task { @MainActor in
            self.wantsFrames = false
            self.onError?()
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // AVKit calls this on the main thread but the handler isn't @Sendable.
        nonisolated(unsafe) let handler = completionHandler
        Task { @MainActor in
            self.onRestoreRequested?()
            handler(true)
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                setPlaying playing: Bool) {
        paused.withLock { $0 = !playing }
        pictureInPictureController.invalidatePlaybackState()
        if playing {
            // Repaint with the newest frame immediately instead of waiting
            // for the camera's next one.
            Task { @MainActor in
                if wantsFrames { replayLastFrame() }
            }
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // Infinite range = live content; the system shows live-style controls.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        paused.withLock { $0 }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
