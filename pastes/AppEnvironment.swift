import Foundation
import AppKit

enum AppEnvironment {
    static var isPasteDebugEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["PASTES_DEBUG_PASTE"] == "1"
        #else
        false
        #endif
    }

    static let pasteboard: NSPasteboard = {
        #if DEBUG
        if isPasteDebugEnabled,
           let name = ProcessInfo.processInfo.environment["PASTES_DEBUG_PASTEBOARD"],
           name.hasPrefix("com.pastes.paste-debug."),
           name.count > "com.pastes.paste-debug.".count,
           name.utf8.count <= 255,
           name.utf8.allSatisfy({ byte in
               (65...90).contains(byte) || (97...122).contains(byte)
                   || (48...57).contains(byte) || byte == 45 || byte == 46 || byte == 95
           }) {
            return NSPasteboard(name: NSPasteboard.Name(name))
        }
        #endif
        return .general
    }()

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Pastes"
    }

    static var isDevelopment: Bool {
        if let flag = Bundle.main.object(forInfoDictionaryKey: "PASTESDevelopmentBuild") as? Bool {
            return flag
        }
        return Bundle.main.bundleURL.pathExtension != "app"
    }

    static var storageURL: URL {
        #if DEBUG
        if isPasteDebugEnabled,
           let directory = ProcessInfo.processInfo.environment["PASTES_DEBUG_DATA_DIRECTORY"],
           !directory.isEmpty {
            return URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("clipboard.sqlite")
        }
        #endif
        // Never open or replace the legacy SwiftData default.store.
        let identifier = Bundle.main.bundleIdentifier ?? "com.pastes.app.pastes.dev"
        return URL.applicationSupportDirectory
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("clipboard.sqlite")
    }
}
