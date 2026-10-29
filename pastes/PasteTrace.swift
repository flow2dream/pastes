import Foundation

#if DEBUG
import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hidsystem
#endif

/// Explicitly enabled Debug diagnostics. Never records clipboard payloads.
@MainActor
enum PasteTrace {
    static var isEnabled: Bool { AppEnvironment.isPasteDebugEnabled }

    static func record(_ event: String, details: [String: Any] = [:]) {
        #if DEBUG
        guard isEnabled else { return }
        var fields = details
        fields["event"] = event
        fields["timestamp"] = Date().timeIntervalSince1970
        fields["pid"] = Int(ProcessInfo.processInfo.processIdentifier)
        guard JSONSerialization.isValidJSONObject(fields),
              var data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        // FileHandle writes directly to the descriptor without stdio buffering.
        try? FileHandle.standardOutput.write(contentsOf: data)
        #endif
    }

    static func captureLaunch() {
        #if DEBUG
        guard isEnabled else { return }
        record("launch", details: [
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "bundlePath": Bundle.main.bundleURL.path,
            "pasteboard": AppEnvironment.pasteboard.name.rawValue,
            "AXIsProcessTrusted": AXIsProcessTrusted(),
            "CGPreflightPostEventAccess": CGPreflightPostEventAccess()
        ])
        DispatchQueue.global(qos: .utility).async {
            let access = IOHIDCheckAccess(kIOHIDRequestTypePostEvent)
            let description: String
            switch access {
            case kIOHIDAccessTypeGranted: description = "Granted"
            case kIOHIDAccessTypeDenied: description = "Denied"
            default: description = "Unknown"
            }
            DispatchQueue.main.async {
                record("hid_post_access", details: ["IOHIDCheckAccess": description])
            }
        }
        #endif
    }
}
