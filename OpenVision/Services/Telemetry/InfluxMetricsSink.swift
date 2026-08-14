// OpenVision - InfluxMetricsSink.swift
// Pushes metrics to InfluxDB (line protocol over HTTP), which Grafana reads as a datasource.
//
// Why line protocol rather than Prometheus remote_write: remote_write is protobuf + snappy, a lot
// of machinery to hand-roll in Swift for one device. Line protocol is plain text over POST, so the
// whole wire format is the `line(...)` helper below. Grafana treats InfluxDB as a first-class
// datasource either way. If this ever needs to become remote_write, only this file changes.
//
// PRIVACY: this is OFF by default and must be switched on with an explicit endpoint. It sends
// timing and device-health numbers only — never transcripts, replies, prompts, or tool arguments.
// Keep it that way: OpenVision's whole premise is that what you say stays on your phone.

import Foundation

/// Buffers metrics and POSTs them to InfluxDB in batches.
final class InfluxMetricsSink: MetricsSink, @unchecked Sendable {

    struct Config: Equatable, Codable {
        /// Base URL of the InfluxDB server, e.g. `http://192.168.1.20:8086`.
        var url: String
        /// v2 bucket, or v1 database name.
        var bucket: String
        /// v2 organisation. Ignored by v1.
        var org: String
        /// v2 API token. Takes precedence over username/password when non-empty.
        var token: String
        /// v1 basic-auth credentials, used when `token` is empty.
        var username: String
        var password: String
        /// Tag applied to every point so multiple devices stay separable in Grafana.
        var deviceName: String

        var isUsable: Bool { !url.isEmpty && !bucket.isEmpty }
    }

    private let config: Config
    private let session: URLSession

    /// Pending lines. Guarded by `lock`; drained on a timer or when the batch gets large.
    private var buffer: [String] = []
    private let lock = NSLock()
    private var flushTimer: Timer?

    /// Hard cap so a dead endpoint can't grow this without bound. Oldest points are dropped —
    /// recent device state is worth more than stale history.
    private let maxBufferedLines = 2_000
    private let flushThreshold = 50

    init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
        // Timed flush so a quiet app still reports; the threshold handles busy periods.
        flushTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.flush()
        }
    }

    deinit {
        flushTimer?.invalidate()
    }

    // MARK: - MetricsSink

    func record(system: SystemMetrics, at time: Date) {
        let fields = [
            "memory_footprint_mb=\(system.memoryFootprintMB)",
            "memory_available_mb=\(system.memoryAvailableMB)",
            "memory_total_mb=\(system.memoryTotalMB)",
            "cpu_percent=\(system.cpuPercent)",
            "thermal_level=\(system.thermalLevel)i",
            "low_power_mode=\(system.isLowPowerMode)",
            system.batteryLevel.map { "battery_level=\($0)" }
        ].compactMap { $0 }

        enqueue(line(
            measurement: "device",
            tags: ["device": config.deviceName, "thermal": system.thermalLabel],
            fields: fields,
            timestamp: time
        ))
    }

    func record(turn: TurnTimeline) {
        var fields: [String] = []
        // Each stage is optional: an abandoned turn still tells us where it got to.
        if let v = turn.commitDuration { fields.append("commit_s=\(v)") }
        if let v = turn.timeToFirstToken { fields.append("ttft_s=\(v)") }
        if let v = turn.generationDuration { fields.append("generation_s=\(v)") }
        if let v = turn.ttsLeadIn { fields.append("tts_lead_in_s=\(v)") }
        if let v = turn.perceivedLatency { fields.append("perceived_latency_s=\(v)") }
        if let v = turn.totalDuration { fields.append("total_s=\(v)") }
        if let v = turn.tokensPerSecond { fields.append("tokens_per_second=\(v)") }
        if let v = turn.tokenCount { fields.append("tokens=\(v)i") }
        fields.append("abandoned=\(turn.abandoned)")

        // A point with no measurable field is noise.
        guard fields.count > 1 else { return }

        enqueue(line(
            measurement: "turn",
            tags: [
                "device": config.deviceName,
                "backend": turn.backend ?? "unknown",
                "model": turn.model ?? "unknown"
            ],
            fields: fields,
            timestamp: turn.spokeDoneAt ?? turn.firstAudioAt ?? turn.startedAt
        ))
    }

    func flush() {
        lock.lock()
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()

        guard !batch.isEmpty, let request = makeRequest(body: batch.joined(separator: "\n")) else {
            return
        }

        session.dataTask(with: request) { _, response, error in
            if let error {
                print("[Metrics] Push failed: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                // 401/404 here almost always means the bucket/org/credentials are wrong.
                print("[Metrics] Push rejected: HTTP \(http.statusCode)")
            }
        }.resume()
        // Deliberately not re-queueing on failure: this is best-effort observability, and retrying
        // into a dead endpoint would grow memory on a device that has little to spare.
    }

    // MARK: - Line protocol

    private func enqueue(_ line: String) {
        lock.lock()
        buffer.append(line)
        if buffer.count > maxBufferedLines {
            buffer.removeFirst(buffer.count - maxBufferedLines)
        }
        let shouldFlush = buffer.count >= flushThreshold
        lock.unlock()
        if shouldFlush { flush() }
    }

    /// `measurement,tag=value field=1,other=2 <nanoseconds>`
    private func line(measurement: String, tags: [String: String], fields: [String], timestamp: Date) -> String {
        let tagPart = tags
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }          // stable order keeps series identity consistent
            .map { "\(escapeTag($0.key))=\(escapeTag($0.value))" }
            .joined(separator: ",")
        let head = tagPart.isEmpty ? measurement : "\(measurement),\(tagPart)"
        let nanos = UInt64(max(0, timestamp.timeIntervalSince1970) * 1_000_000_000)
        return "\(head) \(fields.joined(separator: ",")) \(nanos)"
    }

    /// Commas, spaces and equals signs are structural in line protocol and must be escaped in
    /// tag keys/values — model ids like `mlx-community/gemma-4-E2B-it-4bit` are otherwise fine.
    private func escapeTag(_ s: String) -> String {
        s.replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: " ", with: "\\ ")
            .replacingOccurrences(of: "=", with: "\\=")
    }

    private func makeRequest(body: String) -> URLRequest? {
        guard config.isUsable,
              var components = URLComponents(string: config.url.trimmingCharacters(in: .whitespaces))
        else { return nil }

        components.path = "/api/v2/write"
        components.queryItems = [
            URLQueryItem(name: "bucket", value: config.bucket),
            URLQueryItem(name: "org", value: config.org),
            URLQueryItem(name: "precision", value: "ns")
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        if !config.token.isEmpty {
            request.setValue("Token \(config.token)", forHTTPHeaderField: "Authorization")
        } else if !config.username.isEmpty {
            // v1-compatible basic auth.
            let credentials = "\(config.username):\(config.password)"
            if let encoded = credentials.data(using: .utf8)?.base64EncodedString() {
                request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }
}
