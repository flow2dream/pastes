import AppKit

/// Compatibility recovery for the retired system-capture takeover feature.
/// New sessions only read the screenshot folder; no API can enable takeover.
/// Injected preference access keeps tests away from real system settings.
@MainActor
final class CaptureInbox {
    private let defaults: UserDefaults
    private let read: (String) -> Any?
    private let write: (String, Any?) -> Void
    private let synchronize: () -> Void
    let folder: URL
    private let snapshotKey = "captureInboxSnapshot.v1"
    private var legacyAppliedValues: [String: Any] {
        ["location": folder.path, "location-screenshot": folder.path,
         "location-screenrecording": folder.path, "target": "file",
         "target-screenshot": "file", "target-screenrecording": "file", "show-thumbnail": false]
    }

    init(folder: URL, defaults: UserDefaults = .standard,
         read: @escaping (String) -> Any? = CaptureInbox.readSystem,
         write: @escaping (String, Any?) -> Void = CaptureInbox.writeSystem,
         synchronize: @escaping () -> Void = CaptureInbox.syncSystem) {
        self.folder = folder; self.defaults = defaults
        self.read = read; self.write = write; self.synchronize = synchronize
    }
    nonisolated static func readSystem(_ key: String) -> Any? {
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        return CFPreferencesCopyAppValue(key as CFString, "com.apple.screencapture" as CFString)
    }
    nonisolated static func writeSystem(_ key: String, _ value: Any?) {
        CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, "com.apple.screencapture" as CFString)
    }
    nonisolated static func syncSystem() { CFPreferencesAppSynchronize("com.apple.screencapture" as CFString) }

    func restore() {
        guard let previous = defaults.dictionary(forKey: snapshotKey) else { return }
        // If another app changed destinations, it owns the capture configuration now.
        // Do not restore shared target/thumbnail values underneath that app.
        let ownsDestination = ["location", "location-screenshot", "location-screenrecording"].contains {
            (read($0) as? String) == folder.path
        }
        let ownsAllDestinations = ["location", "location-screenshot", "location-screenrecording"].allSatisfy {
            (read($0) as? String) == folder.path
        }
        if ownsDestination {
            for (key, expected) in legacyAppliedValues {
                // A partial takeover by another app must not have its shared target/thumbnail reset.
                if !ownsAllDestinations && !key.hasPrefix("location") { continue }
                guard let current = read(key), Self.equal(current, expected),
                      let saved = previous[key] as? [String: Any] else { continue }
                write(key, saved["exists"] as? Bool == true ? saved["value"] : nil)
            }
            synchronize()
        }
        defaults.removeObject(forKey: snapshotKey)
    }

    private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        (lhs as? NSObject)?.isEqual(rhs) == true
    }

    static var screenshotFolder: URL {
        let path = readSystem("location-screenshot") as? String ?? readSystem("location") as? String
        return path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
}
