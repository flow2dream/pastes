//
//  UpdateManager.swift
//  pastes
//
//  Created by hai on 2026/6/18.
//

import Sparkle

final class UpdateManager: NSObject {
    static let shared = UpdateManager()

    private var updater: SPUUpdater!
    private var userDriver: SPUStandardUserDriver!

    private override init() {
        super.init()
        userDriver = SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil)
        updater = try! SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: userDriver,
            delegate: self
        )
        do {
            try updater.start()
        } catch {
            print("[Pastes] Failed to start updater: \(error)")
        }
    }

    var canCheckForUpdates: Bool {
        updater.canCheckForUpdates
    }

    @objc func checkForUpdates() {
        updater.checkForUpdates()
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
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
