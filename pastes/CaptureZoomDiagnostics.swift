import AppKit
import OSLog

struct CaptureZoomDiagnostics {
    /// Optional frame details supplement the live system-recognizer log.
    static let tracesSamples = AppEnvironment.isDevelopment &&
        ProcessInfo.processInfo.environment["PASTES_ZOOM_TRACE"] == "1"

    static func eventName(_ type: NSEvent.EventType) -> String {
        let name: String
        switch type {
        case .scrollWheel: name = "scrollWheel"
        case .magnify: name = "magnify"
        case .gesture: name = "genericGesture"
        case .rotate: name = "rotate"
        case .swipe: name = "swipe"
        case .smartMagnify: name = "smartMagnify"
        case .leftMouseDown: name = "leftMouseDown"
        case .leftMouseUp: name = "leftMouseUp"
        case .leftMouseDragged: name = "leftMouseDragged"
        default: name = "other"
        }
        return "\(name)(\(type.rawValue))"
    }

    static func eventDetails(_ event: NSEvent) -> String {
        switch event.type {
        case .scrollWheel:
            return String(format: "scroll=(%.3f,%.3f) precise=%@ momentum=%@", event.scrollingDeltaX,
                event.scrollingDeltaY, String(event.hasPreciseScrollingDeltas), phaseName(event.momentumPhase))
        case .magnify:
            return "systemDelta=\(event.magnification)"
        default:
            return ""
        }
    }

    /// Query WindowServer only at stream boundaries, never for each changed event.
    static func shouldTraceLocation(_ event: NSEvent) -> Bool {
        !event.phase.contains(.changed) && !event.momentumPhase.contains(.changed)
    }

    static func phaseName(_ phase: NSEvent.Phase) -> String {
        if phase.isEmpty { return "none" }
        let names: [(NSEvent.Phase, String)] = [
            (.began, "began"), (.changed, "changed"), (.ended, "ended"),
            (.cancelled, "cancelled"), (.stationary, "stationary"), (.mayBegin, "mayBegin")
        ]
        return names.filter { phase.contains($0.0) }.map(\.1).joined(separator: "|")
    }

    static func stateName(_ state: NSGestureRecognizer.State) -> String {
        switch state {
        case .possible: return "possible"
        case .began: return "began"
        case .changed: return "changed"
        case .ended: return "ended"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }

    private var events = 0
    private var native = 0
    private var gesture = 0
    private var recognizer = 0
    private var changes = 0
    private var delayMS: [Double] = []
    private var dispatchMS: [Double] = []
    private var resizeMS: [Double] = []
    private var largestStep: CGFloat = 0
    private let log = Logger(subsystem: "com.pastes.capture", category: "pinch")

    mutating func event(_ event: NSEvent, dispatch: Double, delay: Double) {
        events += 1
        if event.type == .magnify { native += 1 }
        if event.type == .gesture { gesture += 1 }
        delayMS.append(max(0, delay * 1000))
        dispatchMS.append(dispatch * 1000)
    }
    mutating func systemRecognizer() { recognizer += 1 }
    mutating func resize(seconds: Double, amount: CGFloat) {
        changes += 1
        largestStep = max(largestStep, abs(amount))
        resizeMS.append(seconds * 1000)
    }
    mutating func flushIfNeeded(window: Int, force: Bool = false) {
        guard events >= 60 || force && (events > 0 || changes > 0 || recognizer > 0) else { return }
        let delay = percentile95(delayMS), dispatch = percentile95(dispatchMS), resize = percentile95(resizeMS)
        let events = self.events, native = self.native, gesture = self.gesture, changes = self.changes, largestStep = self.largestStep
        let recognizer = self.recognizer
        log.notice("ZOOM DIAG window=\(window) input=system-recognizer events=\(events) native=\(native) gesture=\(gesture) recognizer=\(recognizer) resizes=\(changes) queueP95ms=\(delay) dispatchP95ms=\(dispatch) resizeP95ms=\(resize) maxStep=\(largestStep)")
        self = Self()
    }
    private func percentile95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[min(values.count - 1, Int(ceil(Double(values.count) * 0.95)) - 1)]
    }
}
