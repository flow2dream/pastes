import AppKit
import OSLog

/// Development-only observation at the application dequeue/dispatch boundaries.
/// Every event follows AppKit's original path without conversion or consumption.
@objc(PastesApplication)
final class PastesApplication: NSApplication {
    private let observesGestureEvents = AppEnvironment.isDevelopment
    private let gestureLog = Logger(subsystem: "com.pastes.capture", category: "pinch")
    private var dequeued = GestureCounts()
    private var dispatched = GestureCounts()
    private var lastRequestMask: NSEvent.EventTypeMask?
    private var lastRequestMode: RunLoop.Mode?

    override func nextEvent(matching mask: NSEvent.EventTypeMask, until expiration: Date?,
                            inMode mode: RunLoop.Mode, dequeue deqFlag: Bool) -> NSEvent? {
        let event = super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: deqFlag)
        guard observesGestureEvents, deqFlag, let event, Self.isRelated(event.type) else { return event }

        if lastRequestMask != mask || lastRequestMode != mode {
            lastRequestMask = mask; lastRequestMode = mode
            let includesMagnify = mask.contains(.magnify)
            let rawMask = mask.rawValue
            let runLoopMode = mode.rawValue
            gestureLog.notice("APP INPUT REQUEST mask=\(rawMask) includesMagnify=\(includesMagnify) mode=\(runLoopMode, privacy: .public)")
        }
        if event.type == .magnify {
            CaptureZoomLiveLog.shared.record(.application, window: event.windowNumber,
                "dequeued magnify phase=\(CaptureZoomDiagnostics.phaseName(event.phase)) delta=\(event.magnification) maskIncludesMagnify=\(mask.contains(.magnify))")
        }
        if let counts = dequeued.record(event.type) {
            emit(counts, boundary: "DEQUEUED", event: event)
        }
        return event
    }

    override func sendEvent(_ event: NSEvent) {
        if observesGestureEvents, CaptureZoomLiveLog.shared.isRecording, Self.isRelated(event.type) {
            let responder = event.window?.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "nil"
            let input: String
            if let surface = event.window?.contentView as? CaptureReferenceDragView {
                let point = surface.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                let observedHit = surface.hitTest(point).map { NSStringFromClass(type(of: $0)) } ?? "nil"
                input = " \(surface.systemInputStatus) observedHit=\(observedHit)"
            } else { input = "" }
            CaptureZoomLiveLog.shared.record(.application, window: event.windowNumber,
                "dispatch type=\(CaptureZoomDiagnostics.eventName(event.type)) phase=\(CaptureZoomDiagnostics.phaseName(event.phase)) key=\(keyWindow?.windowNumber ?? 0) appActive=\(isActive) firstResponder=\(responder)\(input) \(CaptureZoomDiagnostics.eventDetails(event))")
        }
        if observesGestureEvents, Self.isRelated(event.type),
           let counts = dispatched.record(event.type) {
            emit(counts, boundary: "DISPATCHED", event: event)
        }
        super.sendEvent(event)
    }

    private static func isRelated(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .gesture, .magnify, .rotate, .swipe, .smartMagnify, .scrollWheel: true
        default: false
        }
    }

    private func emit(_ counts: GestureCounts, boundary: String, event: NSEvent) {
        let eventWindow = event.windowNumber
        let key = keyWindow?.windowNumber ?? 0
        let responder = event.window?.firstResponder ?? keyWindow?.firstResponder
        let responderName = responder.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        let phase = event.phase.rawValue
        let type = event.type.rawValue
        let active = isActive
        gestureLog.notice("APP \(boundary, privacy: .public) events=\(counts.total) gesture=\(counts.gesture) magnify=\(counts.magnify) rotate=\(counts.rotate) swipe=\(counts.swipe) smartMagnify=\(counts.smartMagnify) scroll=\(counts.scroll) eventType=\(type) window=\(eventWindow) key=\(key) responder=\(responderName, privacy: .public) phase=\(phase) active=\(active)")
    }

    private struct GestureCounts {
        var total = 0
        var gesture = 0
        var magnify = 0
        var rotate = 0
        var swipe = 0
        var smartMagnify = 0
        var scroll = 0
        private var reportedSpecialized = Set<NSEvent.EventType>()

        mutating func record(_ type: NSEvent.EventType) -> Self? {
            let specialized: Bool
            switch type {
            case .gesture: gesture += 1; specialized = false
            case .magnify: magnify += 1; specialized = true
            case .rotate: rotate += 1; specialized = true
            case .swipe: swipe += 1; specialized = true
            case .smartMagnify: smartMagnify += 1; specialized = true
            case .scrollWheel: scroll += 1; specialized = false
            default: return nil
            }
            total += 1
            let firstSpecialized = specialized && reportedSpecialized.insert(type).inserted
            guard total >= 60 || firstSpecialized else { return nil }
            let counts = self
            let reported = reportedSpecialized
            self = Self()
            reportedSpecialized = reported
            return counts
        }
    }
}
