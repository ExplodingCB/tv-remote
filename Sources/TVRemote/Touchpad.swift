import AppKit
import SwiftUI

/// The big touch area. Click-drag works like a finger on the iPhone remote,
/// two-finger trackpad swipes glide the same way, and a click selects.
///
/// With `captureTrackpad` on, the Mac trackpad itself becomes the Siri
/// Remote's touch surface: the cursor is frozen and hidden, every finger
/// position on the trackpad maps straight onto the remote's pad, and a
/// physical click selects.
struct Touchpad: NSViewRepresentable {
    enum Event {
        case touch(TouchPhase, CGPoint)
        case tap(CGPoint)
        case longPress(CGPoint)
        case step(RemoteKey)
        case captureEnded
    }

    var captureTrackpad = false
    var onEvent: (Event) -> Void

    func makeNSView(context: Context) -> TouchpadView {
        let view = TouchpadView()
        view.onEvent = onEvent
        return view
    }

    func updateNSView(_ view: TouchpadView, context: Context) {
        view.onEvent = onEvent
        // Wait a beat so the view is in its window before grabbing the cursor.
        DispatchQueue.main.async { view.setCapture(captureTrackpad) }
    }

    static func dismantleNSView(_ view: TouchpadView, coordinator: ()) {
        view.setCapture(false)
    }
}

final class TouchpadView: NSView {
    var onEvent: ((Touchpad.Event) -> Void)?

    private var downPoint: CGPoint = .zero
    private var downTime: TimeInterval = 0
    private var moved = false
    private var longPressed = false
    private var longPressWork: DispatchWorkItem?
    private var lastHoldSent: TimeInterval = 0

    // Two-finger scrolling is replayed as a finger sliding across the pad.
    private var scrollPoint: CGPoint?
    private var wheelAccumulator: CGFloat = 0

    // Trackpad capture.
    private(set) var isCapturing = false
    private var trackedTouch: (NSCopying & NSObjectProtocol)?
    private var lastTouchSent: TimeInterval = 0
    private var captureObservers: [NSObjectProtocol] = []

    private let tapSlop: CGFloat = 6
    private let holdInterval: TimeInterval = 1.0 / 60

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func normalized(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / max(bounds.width, 1), y: p.y / max(bounds.height, 1))
    }

    override func mouseDown(with event: NSEvent) {
        if isCapturing {
            // A physical trackpad click. The finger itself is already being
            // tracked by the touch handlers, so this is purely the click.
            longPressed = false
            let work = DispatchWorkItem { [weak self] in
                self?.longPressed = true
                self?.onEvent?(.longPress(.zero))
            }
            longPressWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
            return
        }
        let point = normalized(event)
        downPoint = convert(event.locationInWindow, from: nil)
        downTime = event.timestamp
        moved = false
        longPressed = false
        onEvent?(.touch(.press, point))

        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.moved else { return }
            self.longPressed = true
            self.onEvent?(.longPress(point))
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isCapturing else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !moved, hypot(p.x - downPoint.x, p.y - downPoint.y) > tapSlop {
            moved = true
            longPressWork?.cancel()
        }
        guard event.timestamp - lastHoldSent >= holdInterval else { return }
        lastHoldSent = event.timestamp
        onEvent?(.touch(.hold, normalized(event)))
    }

    override func mouseUp(with event: NSEvent) {
        longPressWork?.cancel()
        if isCapturing {
            if !longPressed { onEvent?(.tap(.zero)) }
            return
        }
        let point = normalized(event)
        onEvent?(.touch(.release, point))
        if !moved, !longPressed {
            onEvent?(.tap(point))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // While capturing, raw touches already describe the same fingers.
        guard !isCapturing else { return }
        // Mouse wheels (no gesture phases): step focus one item per notch.
        if event.phase.isEmpty && event.momentumPhase.isEmpty {
            wheelAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 20 : event.scrollingDeltaY
            while abs(wheelAccumulator) >= 1 {
                let up = (wheelAccumulator > 0) != event.isDirectionInvertedFromDevice
                onEvent?(.step(up ? .up : .down))
                wheelAccumulator -= wheelAccumulator > 0 ? 1 : -1
            }
            return
        }
        // Ignore trackpad momentum; tvOS adds its own inertia from the swipe speed.
        guard event.momentumPhase.isEmpty else { return }

        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            if scrollPoint == nil {
                scrollPoint = CGPoint(x: 0.5, y: 0.5)
                onEvent?(.touch(.press, scrollPoint!))
            }
            return
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            if let point = scrollPoint { onEvent?(.touch(.release, point)) }
            scrollPoint = nil
            return
        }
        guard event.phase.contains(.changed), var point = scrollPoint else { return }

        // Direction the fingers actually moved, regardless of natural scrolling.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        point.x += sign * event.scrollingDeltaX / max(bounds.width, 1)
        point.y += sign * event.scrollingDeltaY / max(bounds.height, 1)

        if (0...1).contains(point.x), (0...1).contains(point.y) {
            scrollPoint = point
            onEvent?(.touch(.hold, point))
        } else {
            // Ran off the edge: lift and put the "finger" back in the middle,
            // like re-swiping on a real remote, so long swipes keep going.
            onEvent?(.touch(.release, CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))))
            let center = CGPoint(x: 0.5, y: 0.5)
            scrollPoint = center
            onEvent?(.touch(.press, center))
        }
    }
}

// MARK: - Trackpad capture

extension TouchpadView {
    func setCapture(_ on: Bool) {
        guard on != isCapturing else { return }
        if on {
            guard let window, window.isKeyWindow else {
                onEvent?(.captureEnded)
                return
            }
            isCapturing = true
            allowedTouchTypes = [.indirect]

            // Park the cursor in the middle of the pad and pin it there, so
            // touch events keep coming to this view no matter where the
            // finger goes on the trackpad.
            let frame = window.convertToScreen(convert(bounds, to: nil))
            let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
            CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: primaryHeight - frame.midY))
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()

            // Leaving the window (⌘-Tab, clicking elsewhere) hands the cursor back.
            let center = NotificationCenter.default
            let end: (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent?(.captureEnded) }
            }
            captureObservers = [
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: end),
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: end),
            ]
        } else {
            isCapturing = false
            allowedTouchTypes = []
            releaseTrackedTouch(at: nil)
            captureObservers.forEach(NotificationCenter.default.removeObserver)
            captureObservers = []
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
    }

    /// Trackpad coordinates have their origin bottom-left; the remote's pad is top-left.
    private func padPoint(_ touch: NSTouch) -> CGPoint {
        CGPoint(x: touch.normalizedPosition.x, y: 1 - touch.normalizedPosition.y)
    }

    private func tracked(in touches: Set<NSTouch>) -> NSTouch? {
        guard let trackedTouch else { return nil }
        return touches.first { $0.identity.isEqual(trackedTouch) }
    }

    private func releaseTrackedTouch(at touch: NSTouch?) {
        guard trackedTouch != nil else { return }
        trackedTouch = nil
        onEvent?(.touch(.release, touch.map(padPoint) ?? CGPoint(x: 0.5, y: 0.5)))
    }

    override func touchesBegan(with event: NSEvent) {
        guard isCapturing, trackedTouch == nil,
              let touch = event.touches(matching: .began, in: self).first else { return }
        // Like the real remote, only one finger drives the pad.
        trackedTouch = touch.identity
        lastTouchSent = event.timestamp
        onEvent?(.touch(.press, padPoint(touch)))
    }

    override func touchesMoved(with event: NSEvent) {
        guard isCapturing, let touch = tracked(in: event.touches(matching: .moved, in: self)),
              event.timestamp - lastTouchSent >= holdInterval else { return }
        lastTouchSent = event.timestamp
        onEvent?(.touch(.hold, padPoint(touch)))
    }

    override func touchesEnded(with event: NSEvent) {
        guard isCapturing, let touch = tracked(in: event.touches(matching: .ended, in: self)) else { return }
        releaseTrackedTouch(at: touch)
    }

    override func touchesCancelled(with event: NSEvent) {
        guard isCapturing, let touch = tracked(in: event.touches(matching: .cancelled, in: self)) else { return }
        releaseTrackedTouch(at: touch)
    }
}
