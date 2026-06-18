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
        print("[Pastes] checkForUpdates called, canCheck: \(canCheckForUpdates)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            print("[Pastes] Calling Sparkle checkForUpdates")
            self.updaterController.checkForUpdates(nil)
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    var updateCheckInterval: TimeInterval {
        get { updaterController.updater.updateCheckInterval }
        set { updaterController.updater.updateCheckInterval = newValue }
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        print("[Pastes] Sparkle error: \(error.localizedDescription)")
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        []
    }

    func updaterMayCheck(forUpdates updater: SPUUpdater) -> Bool {
        true
    }
}
