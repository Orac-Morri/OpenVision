// OpenVision - MetricsCollector+Configuration.swift
// Builds the remote sink from saved settings, and restores it at launch.
//
// This exists because the settings were persisted but the SINK was not: it was only attached when
// the user opened Settings → Telemetry and toggled it. Any relaunch — including a jetsam kill
// during a model switch, which is exactly when memory spikes — brought the app back with telemetry
// silently off, and metrics simply stopped arriving with nothing to indicate why.

import Foundation

extension MetricsCollector {

    /// Attach (or detach) the remote sink to match the saved settings.
    ///
    /// Safe to call repeatedly; it replaces whatever sink was configured.
    /// - Returns: true when pushing is now active.
    @discardableResult
    func applySavedConfiguration() -> Bool {
        let settings = SettingsManager.shared.settings
        guard settings.telemetryEnabled, !settings.telemetryURL.isEmpty else {
            configureRemote(nil)
            return false
        }
        configureRemote(InfluxMetricsSink(config: .init(
            url: settings.telemetryURL,
            bucket: settings.telemetryBucket,
            org: settings.telemetryOrg,
            token: settings.telemetryToken,
            username: settings.telemetryUsername,
            password: settings.telemetryPassword,
            deviceName: settings.telemetryDeviceName
        )))
        startSampling()
        return true
    }

    /// Restore telemetry at app launch so it survives relaunches without the user re-toggling it.
    func restoreAtLaunch() {
        if applySavedConfiguration() {
            print("[Metrics] Telemetry restored from settings — pushing to \(SettingsManager.shared.settings.telemetryURL)")
        }
    }
}
