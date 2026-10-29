//
//  UpdateManager.swift
//  pastes
//
//  Created by hai on 2026/6/18.
//

import Sparkle
import Combine
import Foundation

final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var startupError: String?

    private var updater: SPUUpdater?
    private var userDriver: SPUStandardUserDriver!
    private var updaterObservation: NSKeyValueObservation?

    private override init() {
        super.init()
        // The release feed still serves the legacy SwiftData application.
        guard !AppEnvironment.isDevelopment else { return }
        userDriver = SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil)
        let updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: self
        )
        self.updater = updater
        updaterObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, change in
            let canCheck = change.newValue ?? updater.canCheckForUpdates
            DispatchQueue.main.async {
                self?.canCheckForUpdates = canCheck
            }
        }
        do {
            try updater.start()
            canCheckForUpdates = updater.canCheckForUpdates
        } catch {
            canCheckForUpdates = false
            startupError = error.localizedDescription
            print("[Pastes] Failed to start updater: \(error)")
        }
    }

    @objc func checkForUpdates() {
        updater?.checkForUpdates()
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        "https://raw.githubusercontent.com/flow2dream/pastes/main/appcast.xml"
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        print("[Pastes] Update error: \(error.localizedDescription)")
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        []
    }

    func updaterMayCheck(forUpdates updater: SPUUpdater) -> Bool {
        true
    }

    // Force Chinese localization for Sparkle UI
    func allowedSparkleBundleLocalizations(for updater: SPUUpdater) -> [String] {
        let lang = LocalizationManager.shared.language
        if lang == .zh {
            return ["zh_CN", "zh-Hans", "zh"]
        }
        return ["en"]
    }
}
