//
//  ScreenshotManager.swift
//  PeakDeck
//
//  1.1.5 region screenshot: a global shortcut dims the screen under the
//  mouse, the user drags out a selection, then fine-tunes it with four
//  corner handles and confirms with the ✓/✗ buttons (ESC cancels).
//  1.1.8: the screen is frozen into a snapshot when capture begins — the
//  selection and the annotation tools (pen/rect/ellipse/line/arrow) work on
//  that frozen frame, so moving content (streams, video) cannot leak into
//  the picture. Confirming crops the snapshot and composites the strokes.
//  The PNG lands in the clipboard-history store, goes on the pasteboard as
//  BOTH a file URL and image data — so ⌘V pastes a real file into any
//  Finder folder and the image into chat apps — and the clipboard history
//  records it.
//

import AppKit
import SwiftUI

// MARK: - Manager

@MainActor
final class ScreenshotManager: ObservableObject {
    static let shared = ScreenshotManager()

    static func debugLog(_ message: String) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("peakdeck_screenshot.log").path
        let line = "\(Date()) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) { handle.write(data) }
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    @Published var rect: CGRect = .zero
    @Published var adjusting = false

    // Window detection (WeChat-style): hovering snaps the selection to the
    // frontmost window; a plain click captures it. Dragging overrides it.
    @Published var windowHint: String?
    var windowDetected = false
    var manualDragStarted = false

    // Annotation state (see ScreenshotAnnotations.swift).
    @Published var activeTool: AnnotationTool = .none
    @Published var activeColor: AnnotationColor = .red
    @Published var strokes: [AnnotationStroke] = []
    private var strokeStart: CGPoint?

    private var panel: CapturePanel?
    var screenFrame: CGRect = .zero
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var dragStart: CGPoint?
    private var moveOriginRect: CGRect?

    /// Frozen frame of the captured screen (pixel size); nil = live capture.
    private(set) var snapshot: CGImage?
    var backingScale: CGFloat = 2

    private var overlayID: CGWindowID = 0

    func beginCapture() {
        Self.debugLog("beginCapture preflight=\(CGPreflightScreenCaptureAccess())")
        guard panel == nil else { return }
        // Screen recording permission: without it the capture would silently
        // produce a wallpaper-only image — request access instead.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first!
        screenFrame = screen.frame
        backingScale = screen.backingScaleFactor

        // Freeze the screen now: selection and annotation all happen on this
        // frame, so a moving video cannot change the picture before confirm.
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        snapshot = displayID.flatMap { CGDisplayCreateImage($0) }
        if snapshot == nil {
            Self.debugLog("freeze snapshot failed; falling back to live capture")
        }

        let panel = CapturePanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.contentView = NSHostingView(
            rootView: LocalizedRootView {
                ScreenshotOverlayView(manager: self)
            })
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
        overlayID = CGWindowID(panel.windowNumber)

        adjusting = false
        rect = .zero
        activeTool = .none
        strokes = []

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            if event.keyCode == 53 { // escape
                self.closeOverlay()
                return nil
            }
            return event
        }
        // Cursor: set deterministically from the pointer position on every
        // mouse event — push/pop stacks corrupt when handles move under a
        // moving pointer (the reported stuck left-right arrows).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            let height = self.panel?.frame.height ?? 0
            // Window coords (bottom-left) → view coords (top-left).
            let viewPoint = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
            // Hover-detection runs on pure moves and re-checks on press so
            // a click is always resolved against the window under it.
            if !self.adjusting, self.dragStart == nil,
               event.type == .mouseMoved || event.type == .leftMouseDown {
                self.updateWindowHover(at: viewPoint)
            }
            self.updateCursor(for: viewPoint)
            return event
        }
    }

    // MARK: Window detection (click-to-capture)

    /// Frontmost normal-layer window under the given view point, clamped to
    /// this screen, plus its owner name. CG's window list is ordered
    /// front-to-back, so the first containing match is the right one.
    private func detectedWindow(at point: CGPoint) -> (rect: CGRect, app: String)? {
        // CGWindowBounds use the Quartz global TOP-LEFT space; convert the
        // view point and this screen's frame into that space before comparing
        // (view → screen → global, mirroring capture()'s cgRect math).
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let screenTop = mainTop - screenFrame.maxY
        let globalPoint = CGPoint(x: point.x + screenFrame.minX, y: point.y + screenTop)
        let globalScreenRect = CGRect(
            x: screenFrame.minX, y: screenTop,
            width: screenFrame.width, height: screenFrame.height)
        guard let list = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements, .optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        let myPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? Int, pid != myPID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width >= 60, height >= 60
            else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? CGFloat, alpha < 0.05 { continue }
            let windowRect = CGRect(x: x, y: y, width: width, height: height)
            guard windowRect.contains(globalPoint) else { continue }
            let app = info[kCGWindowOwnerName as String] as? String ?? ""
            // Clamp to this screen — the frozen snapshot only covers it.
            let local = windowRect
                .intersection(globalScreenRect)
                .offsetBy(dx: -screenFrame.minX, dy: -screenTop)
            guard local.width >= 40, local.height >= 40 else { continue }
            return (local, app)
        }
        return nil
    }

    /// Snap the selection to the window under the pointer and remember its
    /// name for the hint label; cleared when the pointer leaves any window.
    func updateWindowHover(at point: CGPoint) {
        if let match = detectedWindow(at: point) {
            windowDetected = true
            if rect != match.rect || windowHint != match.app {
                rect = match.rect
                windowHint = match.app
            }
        } else if windowDetected || !rect.isEmpty {
            windowDetected = false
            windowHint = nil
            rect = .zero
        }
    }

    /// The pointer moved ~10pt while hovering a window: switch to manual
    /// freehand selection from the press origin.
    func beginManualSelection(at point: CGPoint) {
        manualDragStarted = true
        windowDetected = false
        windowHint = nil
        dragStart = point
        adjusting = false
        rect = CGRect(origin: point, size: .zero)
    }

    /// Hint shown above the hover-highlighted window.
    var selectionLabel: String {
        let size = "\(Int(rect.width)) × \(Int(rect.height))"
        if let hint = windowHint, !hint.isEmpty {
            return "\(hint) · \(size)"
        }
        return size
    }

    /// Arrow by default; crosshair near the corner handles; pointing hand
    /// over the ✓/✗ buttons and the annotation toolbar.
    func updateCursor(for viewPoint: CGPoint) {
        guard adjusting else {
            NSCursor.crosshair.set()
            return
        }
        for handle in CornerHandle.allCases {
            let p = handle.point(in: rect)
            if abs(viewPoint.x - p.x) <= 14, abs(viewPoint.y - p.y) <= 14 {
                NSCursor.crosshair.set()
                return
            }
        }
        let buttons = confirmButtonsPosition(for: rect)
        if abs(viewPoint.x - buttons.x) <= 44, abs(viewPoint.y - buttons.y) <= 22 {
            NSCursor.pointingHand.set()
            return
        }
        if toolbarHitRect(for: rect).contains(viewPoint) {
            NSCursor.pointingHand.set()
            return
        }
        NSCursor.arrow.set()
    }

    // MARK: Gesture callbacks (from the overlay view)

    /// Single entry point for the selecting-phase drag: the first callback
    /// records the corner (events may coalesce — never assume a zero-translation
    /// first event), later ones grow the rect.
    func dragUpdated(to point: CGPoint) {
        manualDragStarted = true
        guard let start = dragStart else {
            dragStart = point
            adjusting = false
            rect = CGRect(origin: point, size: .zero)
            return
        }
        rect = CGRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y))
    }

    func dragEnded() {
        dragStart = nil
        manualDragStarted = false
        // A click without a meaningful drag is not a selection — abort.
        if rect.width < 10 || rect.height < 10 {
            closeOverlay()
            return
        }
        withAnimation(.smooth(duration: 0.15)) {
            adjusting = true
        }
    }

    func handleDragged(handle: CornerHandle, to point: CGPoint) {
        // The opposite corner anchors; the dragged corner follows the
        // pointer — width and height adjust together. Dragging across the
        // anchor flips the rect; the minimum size keeps it from collapsing.
        let anchor = handle.anchor(in: rect)
        let minimum: CGFloat = 10
        let x = point.x >= anchor.x
            ? max(anchor.x + minimum, point.x)
            : min(anchor.x - minimum, point.x)
        let y = point.y >= anchor.y
            ? max(anchor.y + minimum, point.y)
            : min(anchor.y - minimum, point.y)
        rect = CGRect(
            x: min(anchor.x, x), y: min(anchor.y, y),
            width: abs(x - anchor.x), height: abs(y - anchor.y))
    }

    func selectionDragged(translation: CGSize) {
        // Snapshot the rect at drag start — applying the cumulative
        // translation to the already-moved rect compounds exponentially and
        // makes the frame fly away.
        if moveOriginRect == nil { moveOriginRect = rect }
        guard let origin = moveOriginRect else { return }
        rect = origin.offsetBy(dx: translation.width, dy: translation.height)
    }

    func moveEnded() {
        moveOriginRect = nil
    }

    // MARK: Annotation gestures (active tool selected on the toolbar)

    /// Drag while an annotation tool is active: start a stroke inside the
    /// selection, extend it while dragging (clamped so sloppy pen strokes
    /// stay usable), commit on release. Strokes are stored in
    /// selection-LOCAL coordinates — the canvas adds rect.origin for display
    /// and the final composite crops at the selection — so storing raw view
    /// coordinates here would offset every stroke by the selection origin.
    func annotationDragged(to point: CGPoint) {
        if strokeStart == nil {
            guard rect.contains(point) else { return }
            strokeStart = point
            strokes.append(
                AnnotationStroke(
                    tool: activeTool, color: activeColor,
                    points: [selectionLocal(clampedToSelection(point))]))
            return
        }
        guard !strokes.isEmpty else { return }
        let local = selectionLocal(clampedToSelection(point))
        if activeTool == .pen {
            strokes[strokes.count - 1].points.append(local)
        } else {
            strokes[strokes.count - 1].points = [selectionLocal(strokeStart!), local]
        }
    }

    func annotationEnded() {
        strokeStart = nil
    }

    func undoAnnotation() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
    }

    func clearAnnotations() {
        strokes.removeAll()
    }

    /// View (top-left, full-screen) coordinates → selection-local.
    private func selectionLocal(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - rect.origin.x, y: point.y - rect.origin.y)
    }

    private func clampedToSelection(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY))
    }

    // MARK: Toolbar geometry (shared by the view and the cursor logic)

    static let annotationToolbarSize = CGSize(width: 400, height: 42)

    /// Below the selection, clamped; above it when the selection reaches the
    /// screen bottom.
    func toolbarPosition(for rect: CGRect) -> CGPoint {
        let halfWidth = Self.annotationToolbarSize.width / 2
        let x = min(max(rect.midX, halfWidth + 8), screenFrame.maxX - halfWidth - 8)
        let belowY = rect.maxY + 36
        let y = belowY + Self.annotationToolbarSize.height / 2 <= screenFrame.maxY - 8
            ? belowY
            : max(rect.minY - 36, 40)
        return CGPoint(x: x, y: y)
    }

    func toolbarHitRect(for rect: CGRect) -> CGRect {
        let position = toolbarPosition(for: rect)
        return CGRect(
            x: position.x - Self.annotationToolbarSize.width / 2,
            y: position.y - Self.annotationToolbarSize.height / 2 - 4,
            width: Self.annotationToolbarSize.width,
            height: Self.annotationToolbarSize.height + 8)
    }

    func captureSelection() {
        let selection = rect
        let frame = screenFrame
        let pendingStrokes = strokes
        // Render from the frozen snapshot BEFORE tearing the overlay down —
        // closeOverlay() nils the snapshot, and re-capturing live would let
        // moving content (streams) leak into the picture.
        guard let image = renderedCapture(
            selection: selection, screenFrame: frame, strokes: pendingStrokes)
        else {
            Self.debugLog("capture produced no image")
            closeOverlay()
            return
        }
        closeOverlay()
        store(image: image)
    }

    func closeOverlay() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        adjusting = false
        rect = .zero
        activeTool = .none
        strokes = []
        strokeStart = nil
        snapshot = nil
        windowDetected = false
        windowHint = nil
        manualDragStarted = false

        // The pointer may already be resting on a window when the shortcut
        // fires — seed the hover state so a plain click captures right away.
        let mouse = NSEvent.mouseLocation
        updateWindowHover(
            at: CGPoint(x: mouse.x - screenFrame.minX, y: screenFrame.maxY - mouse.y))
    }

    // MARK: Capture & store

    private func store(image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        // Store the PNG in the clipboard store under a friendly name —
        // pasting into a Finder folder copies this file out.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let file = "\(L10n.string("Screenshot"))-\(formatter.string(from: Date())).png"
        let storeURL = ClipboardManager.storeDirectory
            .appendingPathComponent(file)
        do {
            try FileManager.default.createDirectory(
                at: ClipboardManager.storeDirectory, withIntermediateDirectories: true)
            try png.write(to: storeURL)
        } catch {
            Self.debugLog("screenshot save failed: \(error.localizedDescription)")
            return
        }
        ClipboardManager.shared.recordImageFile(file)

        // Pasteboard carries BOTH a file reference and the image data:
        // ⌘V in a Finder folder pastes the file; ⌘V in a chat app pastes
        // the image.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([storeURL as NSURL])
        pasteboard.setData(png, forType: .png)
        ClipboardManager.shared.suppressNextCapture()
    }

    /// Crop the frozen snapshot to the selection and composite the
    /// annotations; falls back to a live capture when no snapshot exists.
    private func renderedCapture(
        selection: CGRect,
        screenFrame: CGRect,
        strokes: [AnnotationStroke]
    ) -> CGImage? {
        if let snapshot {
            let scaleX = CGFloat(snapshot.width) / screenFrame.width
            let scaleY = CGFloat(snapshot.height) / screenFrame.height
            // Selection is in view coordinates whose (0, 0) is this screen's
            // top-left corner — same origin convention as the CGImage.
            let pixelRect = CGRect(
                x: selection.minX * scaleX,
                y: selection.minY * scaleY,
                width: selection.width * scaleX,
                height: selection.height * scaleY)
            guard let cropped = snapshot.cropping(to: pixelRect) else { return nil }
            guard !strokes.isEmpty else { return cropped }
            return Self.composite(
                strokes: strokes, on: cropped,
                scale: CGPoint(x: scaleX, y: scaleY))
        }

        // Live fallback: the view's top-left-origin rect maps to CG's global
        // top-left space with a vertical offset of (main top − this top).
        let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
        let cgRect = CGRect(
            x: screenFrame.origin.x + selection.minX,
            y: mainTop - screenFrame.maxY + selection.minY,
            width: selection.width,
            height: selection.height)
        // The overlay window sits above everything; capturing only the
        // windows below it excludes the dimming layer from the image.
        guard let image = CGWindowListCreateImage(
            cgRect, [.optionOnScreenBelowWindow], overlayID,
            [.bestResolution]) else { return nil }
        // Annotations live in selection-local points; the live capture is
        // exactly selection-sized, so the scale is direct.
        guard !strokes.isEmpty else { return image }
        return Self.composite(
            strokes: strokes, on: image,
            scale: CGPoint(
                x: CGFloat(image.width) / max(selection.width, 1),
                y: CGFloat(image.height) / max(selection.height, 1)))
    }

    /// Draws the strokes (selection-local points, top-left origin) over the
    /// cropped snapshot at native resolution.
    private static func composite(
        strokes: [AnnotationStroke],
        on base: CGImage,
        scale: CGPoint
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: base.width,
            height: base.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return base }

        context.draw(base, in: CGRect(x: 0, y: 0, width: CGFloat(base.width), height: CGFloat(base.height)))
        // Stroke coordinates are top-left points; map them into the
        // bottom-left pixel space of the context.
        context.translateBy(x: 0, y: CGFloat(base.height))
        context.scaleBy(x: scale.x, y: -scale.y)
        context.setLineWidth(3)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            let color = stroke.color.cgColor
            context.setStrokeColor(color)
            context.setFillColor(color)
            if stroke.points.count < 2, let single = stroke.points.first {
                context.fillEllipse(in: CGRect(
                    x: single.x - 1.5, y: single.y - 1.5, width: 3, height: 3))
                continue
            }
            context.addPath(stroke.path(offset: .zero).cgPath)
            context.strokePath()
        }
        return context.makeImage() ?? base
    }



    /// Confirms/cancels button pair position: the selection's bottom-right
    /// corner, clamped to the screen.
    func confirmButtonsPosition(for rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(rect.maxX - 8, 80), screenFrame.maxX - 90),
            y: min(rect.maxY + 30, screenFrame.maxY - 40))
    }
}

private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Handles

enum CornerHandle: CaseIterable {
    case topLeft, topTrailing, bottomLeading, bottomTrailing

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .topTrailing: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeading: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomTrailing: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// The corner that stays fixed while this handle drags.
    func anchor(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .topTrailing: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeading: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomTrailing: return CGPoint(x: rect.minX, y: rect.minY)
        }
    }
}

// MARK: - Overlay view

struct ScreenshotOverlayView: View {
    @ObservedObject var manager: ScreenshotManager

    var body: some View {
        ZStack {
            // Frozen frame captured at beginCapture: the selection happens
            // against a still image, so moving content (streams, video)
            // cannot change the picture before the user confirms.
            if let snapshot = manager.snapshot {
                Image(decorative: snapshot, scale: manager.backingScale, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: manager.screenFrame.width, height: manager.screenFrame.height)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }

            // Dimming with a transparent hole at the selection. VISUAL ONLY —
            // gestures never attach to the masked view (the mask breaks
            // SwiftUI hit-testing and swallows every mouse event).
            Color.black.opacity(0.35)
                .inverseMask(selectionHole)
                .ignoresSafeArea()

            selectionBorder

            AnnotationCanvasView(manager: manager)

            // Full-screen interaction layer ABOVE the dimming: receives all
            // mouse events deterministically (no mask in its hit path).
            Color.clear
                .contentShape(Rectangle())
                .gesture(interactionGesture)

            if manager.adjusting {
                selectionHandles
                AnnotationToolbarView(manager: manager)
                confirmButtons
            }
        }
    }

    private var interactionGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if manager.adjusting {
                    if manager.activeTool != .none {
                        // A tool is selected: the drag draws an annotation.
                        manager.annotationDragged(to: value.location)
                    } else if manager.rect.contains(value.startLocation) {
                        // No tool: dragging inside the selection moves it.
                        manager.selectionDragged(translation: value.translation)
                    }
                } else if manager.windowDetected && !manager.manualDragStarted {
                    // Hover-snapped to a window: a plain click captures it.
                    // Moving past a small threshold switches to manual drag.
                    let distance = hypot(value.translation.width, value.translation.height)
                    if distance > 10 {
                        manager.beginManualSelection(at: value.startLocation)
                        manager.dragUpdated(to: value.location)
                    }
                } else {
                    manager.dragUpdated(to: value.location)
                }
            }
            .onEnded { _ in
                if manager.adjusting {
                    if manager.activeTool != .none {
                        manager.annotationEnded()
                    } else {
                        manager.moveEnded()
                    }
                } else if manager.windowDetected && !manager.manualDragStarted {
                    // Click on a highlighted window → capture immediately.
                    manager.captureSelection()
                } else {
                    manager.dragEnded()
                }
            }
    }

    private var selectionHole: some View {
        Rectangle()
            .frame(width: max(0, manager.rect.width), height: max(0, manager.rect.height))
            .position(x: manager.rect.midX, y: manager.rect.midY)
    }

    private var selectionBorder: some View {
        Rectangle()
            .strokeBorder(Color.white, lineWidth: 1.5)
            .background(
                Rectangle().strokeBorder(Color.black.opacity(0.4), lineWidth: 0.5)
            )
            .frame(width: max(0, manager.rect.width), height: max(0, manager.rect.height))
            .position(x: manager.rect.midX, y: manager.rect.midY)
            .overlay(alignment: .bottom) {
                if manager.adjusting || manager.windowHint != nil {
                    Text(manager.selectionLabel)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .offset(y: 16)
                        .allowsHitTesting(false)
                }
            }
    }

    /// ✓ capture / ✗ cancel, at the selection's bottom-right corner.
    private var confirmButtons: some View {
        let position = manager.confirmButtonsPosition(for: manager.rect)
        return HStack(spacing: 12) {
            Button {
                manager.captureSelection()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .help("Capture")

            Button {
                manager.closeOverlay()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.gray.opacity(0.9)))
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .position(position)
    }

    private var selectionHandles: some View {
        ForEach(Array(CornerHandle.allCases.enumerated()), id: \.element) { _, handle in
            CornerView(handle: handle, manager: manager)
        }
    }
}

private struct CornerView: View {
    let handle: CornerHandle
    @ObservedObject var manager: ScreenshotManager

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white)
            .frame(width: 14, height: 14)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor, lineWidth: 2))
            .shadow(radius: 1)
            .position(handle.point(in: manager.rect))
            .onHover { hovering in
                NSCursor.crosshair.set()
                if !hovering { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        manager.handleDragged(handle: handle, to: value.location)
                    }
            )
    }
}

// MARK: - Helpers

extension View {
    /// Inverts the given shape mask (used to dim everything but the hole).
    @ViewBuilder
    func inverseMask<Mask: View>(_ mask: Mask) -> some View {
        self.mask {
            Rectangle().overlay(mask.foregroundStyle(.white).blendMode(.destinationOut))
        }
    }
}
