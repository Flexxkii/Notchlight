import AppKit
import CoreGraphics

/// Availability of the optional passive DockControl event monitor.
public enum SwipeMonitoringStatus: Equatable, Sendable {
    case disabled
    case permissionRequired
    case monitoring
    case unavailable
}

enum SwipeGesturePhase: Equatable, Sendable {
    case began
    case changed
    case ended
    case cancelled
}

/// Metadata-only classifier for the private DockControl event. The numeric
/// fields are undocumented WindowServer/HID values observed by the reference
/// implementation at https://raw.githubusercontent.com/joshuarli/iss/master/iss.c.
/// No pointer position, key state, or ordinary mouse event is consumed.
enum SwipeGestureEventParser {
    static let dockControlType: UInt32 = 30
    static let eventTypeField: Int64 = 55
    static let hidTypeField: Int64 = 110
    static let horizontalMotionField: Int64 = 123
    static let phaseField: Int64 = 132
    static let dockSwipeHIDType: Int64 = 23
    static let horizontalMotion: Int64 = 1

    static func classify(
        eventType: UInt32,
        eventTypeField: Int64,
        hidType: Int64,
        motion: Int64,
        phase: Int64
    ) -> SwipeGesturePhase? {
        guard eventType == dockControlType,
              eventTypeField == dockControlType,
              hidType == dockSwipeHIDType,
              motion == horizontalMotion,
              phase >= 0 else { return nil }
        if phase & 8 != 0 { return .cancelled }
        if phase & 4 != 0 { return .ended }
        if phase & 2 != 0 { return .changed }
        if phase & 1 != 0 { return .began }
        return nil
    }
}

/// A listen-only event tap attached to the main run loop. It is deliberately
/// internal: callers use BorderOverlayController's permission/status API.
@MainActor
final class SwipeEventTapSession {
    var onPhase: ((SwipeGesturePhase) -> Void)?
    var onUnavailable: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1) << SwipeGestureEventParser.dockControlType
        let retainedSelf = Unmanaged.passUnretained(self)
        let info = retainedSelf.toOpaque()
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: info
        ) else {
            return false
        }
        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            CFMachPortInvalidate(created)
            return false
        }
        tap = created
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }

    func stop() {
        guard let tap else { return }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        source = nil
        self.tap = nil
    }

    isolated deinit {
        if let source, let tap {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }

    private func receive(type: UInt32, typeField: Int64, hid: Int64, motion: Int64, phase: Int64) {
        if type == CGEventType.tapDisabledByTimeout.rawValue || type == CGEventType.tapDisabledByUserInput.rawValue {
            onUnavailable?()
            stop()
            return
        }
        if let phase = SwipeGestureEventParser.classify(
            eventType: type,
            eventTypeField: typeField,
            hidType: hid,
            motion: motion,
            phase: phase
        ) {
            onPhase?(phase)
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        let typeField = event.getIntegerValueField(CGEventField(rawValue: UInt32(SwipeGestureEventParser.eventTypeField))!)
        let hid = event.getIntegerValueField(CGEventField(rawValue: UInt32(SwipeGestureEventParser.hidTypeField))!)
        let motion = event.getIntegerValueField(CGEventField(rawValue: UInt32(SwipeGestureEventParser.horizontalMotionField))!)
        let phase = event.getIntegerValueField(CGEventField(rawValue: UInt32(SwipeGestureEventParser.phaseField))!)
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let session = Unmanaged<SwipeEventTapSession>.fromOpaque(userInfo).takeUnretainedValue()
        // The source is installed on the main run loop, so this callback is
        // main-actor isolated without dispatching or retaining the session.
        MainActor.assumeIsolated {
            session.receive(type: type.rawValue, typeField: typeField, hid: hid, motion: motion, phase: phase)
        }
        return Unmanaged.passUnretained(event)
    }
}
