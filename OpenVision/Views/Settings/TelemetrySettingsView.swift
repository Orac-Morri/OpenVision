// OpenVision - TelemetrySettingsView.swift
// Live metrics panel + configuration for the optional self-hosted push.
//
// The live section is always useful (marking turn stages is free and always on); only the push
// needs configuring. See telemetry/README.md for the docker-compose stack this talks to.

import SwiftUI

struct TelemetrySettingsView: View {
    @ObservedObject private var metrics = MetricsCollector.shared
    @ObservedObject private var settingsManager = SettingsManager.shared

    var body: some View {
        List {
            liveSection
            turnsSection
            pushSection
            privacySection
        }
        .navigationTitle("Telemetry")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Sampling only runs while this screen is open unless push is on — no point paying
            // for it otherwise.
            metrics.startSampling()
        }
        .onDisappear {
            if !settingsManager.settings.telemetryEnabled { metrics.stopSampling() }
        }
    }

    // MARK: - Live device state

    private var liveSection: some View {
        Section("Device") {
            if let system = metrics.latestSystem {
                metricRow("Memory", String(format: "%.0f / %.0f MB",
                                           system.memoryFootprintMB, system.memoryTotalMB))
                metricRow("Jetsam headroom", String(format: "%.0f MB", system.memoryAvailableMB),
                          tint: system.memoryAvailableMB < 500 ? .orange : nil)
                metricRow("CPU", String(format: "%.0f%%", system.cpuPercent))
                metricRow("Thermal", system.thermalLabel.capitalized,
                          tint: system.thermalLevel >= 2 ? .orange : nil)
                if let battery = system.batteryLevel {
                    metricRow("Battery", String(format: "%.0f%%", battery * 100))
                }
                if system.isLowPowerMode {
                    metricRow("Low power mode", "On", tint: .orange)
                }
            } else {
                Text("Sampling…").foregroundStyle(.secondary)
            }

            Text("iOS exposes no temperature sensor or per-core clocks — thermal is a four-level "
                 + "state, and CPU is this app's threads summed across cores (>100% is normal).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Turn latency

    private var turnsSection: some View {
        Section("Recent turns") {
            if metrics.recentTurns.isEmpty {
                Text("No turns recorded yet.").foregroundStyle(.secondary)
            } else {
                ForEach(metrics.recentTurns.prefix(8)) { turn in
                    turnRow(turn)
                }
            }
        }
    }

    private func turnRow(_ turn: TurnTimeline) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(turn.perceivedLatency.map { String(format: "%.2fs", $0) } ?? "—")
                    .font(.system(.title3, design: .monospaced))
                    .fontWeight(.semibold)
                Text("perceived").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if turn.abandoned {
                    Text("abandoned").font(.caption2).foregroundStyle(.orange)
                }
            }
            // The stage breakdown is the whole point: it says WHICH part was slow.
            Text(stageBreakdown(turn))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            if let rate = turn.tokensPerSecond {
                Text(String(format: "%.1f tok/s", rate))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func stageBreakdown(_ turn: TurnTimeline) -> String {
        var parts: [String] = []
        if let v = turn.commitDuration { parts.append(String(format: "commit %.2f", v)) }
        if let v = turn.timeToFirstToken { parts.append(String(format: "ttft %.2f", v)) }
        if let v = turn.generationDuration { parts.append(String(format: "gen %.2f", v)) }
        if let v = turn.ttsLeadIn { parts.append(String(format: "tts %.2f", v)) }
        return parts.isEmpty ? "no stages recorded" : parts.joined(separator: " · ")
    }

    // MARK: - Push configuration

    private var pushSection: some View {
        Section {
            Toggle("Push to InfluxDB", isOn: Binding(
                get: { settingsManager.settings.telemetryEnabled },
                set: { newValue in
                    settingsManager.settings.telemetryEnabled = newValue
                    applyTelemetryConfiguration()
                }
            ))

            if settingsManager.settings.telemetryEnabled {
                labelledField("URL", "http://192.168.1.20:8086",
                              text: $settingsManager.settings.telemetryURL,
                              keyboard: .URL)
                labelledField("Bucket", "metrics", text: $settingsManager.settings.telemetryBucket)
                labelledField("Org", "openvision", text: $settingsManager.settings.telemetryOrg)
                labelledField("Token", "InfluxDB v2 token",
                              text: $settingsManager.settings.telemetryToken, secure: true)
                labelledField("Device tag", "iphone",
                              text: $settingsManager.settings.telemetryDeviceName)

                Button("Apply & send a sample") {
                    applyTelemetryConfiguration()
                    metrics.sampleNow()
                    metrics.flush()
                }

                if metrics.isPushEnabled {
                    Label("Pushing", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
        } header: {
            Text("Self-hosted push")
        } footer: {
            Text("Use your machine's LAN IP or .local name — localhost would mean this phone. "
                 + "Run the stack from telemetry/docker-compose.yml.")
        }
    }

    private var privacySection: some View {
        Section {
            Text("Timings and device health only. Transcripts, replies, prompts, and tool "
                 + "arguments are never sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    /// Shared with the launch restore path so the two can't drift — see
    /// `MetricsCollector.applySavedConfiguration()`.
    private func applyTelemetryConfiguration() {
        metrics.applySavedConfiguration()
    }

    private func metricRow(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(tint ?? .secondary)
        }
    }

    @ViewBuilder
    private func labelledField(_ label: String, _ placeholder: String,
                               text: Binding<String>, secure: Bool = false,
                               keyboard: UIKeyboardType = .default) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            if secure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
                    .keyboardType(keyboard)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
    }
}
