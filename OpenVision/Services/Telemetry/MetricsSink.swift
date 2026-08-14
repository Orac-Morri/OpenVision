// OpenVision - MetricsSink.swift
// Where metrics go. One collector, pluggable destinations.

import Foundation

/// A destination for metrics. Implementations must be safe to call from the main actor and must
/// never block it — do network work asynchronously and drop rather than queue without bound.
protocol MetricsSink: Sendable {
    /// A periodic device reading.
    func record(system: SystemMetrics, at time: Date)
    /// A finished (or abandoned) voice turn.
    func record(turn: TurnTimeline)
    /// Best-effort flush, e.g. when the app backgrounds.
    func flush()
}

extension MetricsSink {
    func flush() {}
}
