//
//  UpdateManager.swift
//  pastes
//
//  Created by hai on 2026/6/18.
//

import Sparkle

final class UpdateManager: NSObject {
    static let shared = UpdateManager()

    private var updaterController: SPUStandardUpdaterController!

    private override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }

    @objc func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
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
}
