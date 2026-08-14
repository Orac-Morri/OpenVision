// OpenVision - MetricsCollector.swift
// Single entry point for runtime telemetry: marks turn stages, samples device state, fans both
// out to whatever sinks are configured, and keeps a small in-memory history for the debug panel.
//
// Design notes:
//  • Marking is CHEAP and always on — recording a Date costs nothing and means the debug panel is
//    useful the moment you open it. Only device SAMPLING and remote PUSH are opt-in.
//  • Marks are idempotent per stage: the first one wins. Backends emit many partial-response
//    callbacks, and `firstToken` must mean the first, not the latest.
//  • Nothing here may ever carry user content. Numbers, model ids and backend names only.

import Foundation
import UIKit

@MainActor
final class MetricsCollector: ObservableObject {

    static let shared = MetricsCollector()

    // MARK: - Published state (drives the debug panel)

    /// Most recent device sample, or nil until sampling starts.
    @Published private(set) var latestSystem: SystemMetrics?
    /// The turn currently in flight.
    @Published private(set) var currentTurn: TurnTimeline?
    /// Completed turns, newest first, capped at `maxHistory`.
    @Published private(set) var recentTurns: [TurnTimeline] = []
    /// True when a remote sink is attached — surfaced in settings so it's never a surprise.
    @Published private(set) var isPushEnabled = false

    private let maxHistory = 50

    private var sinks: [MetricsSink] = []
    private var sampleTimer: Timer?

    private init() {}

    // MARK: - Configuration

    /// Attach/replace the remote sink. Pass nil to detach (and stop pushing immediately).
    func configureRemote(_ sink: MetricsSink?) {
        sinks.removeAll()
        if let sink {
            sinks.append(sink)
            isPushEnabled = true
        } else {
            isPushEnabled = false
        }
    }

    /// Begin periodic device sampling. Idempotent.
    func startSampling(interval: TimeInterval = 2.0) {
        guard sampleTimer == nil else { return }
        sampleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleNow() }
        }
        sampleNow()
    }

    func stopSampling() {
        sampleTimer?.invalidate()
        sampleTimer = nil
    }

    func sampleNow() {
        let now = Date()
        let sample = SystemMetricsReader.sample()
        latestSystem = sample
        for sink in sinks { sink.record(system: sample, at: now) }
    }

    func flush() {
        for sink in sinks { sink.flush() }
    }

    // MARK: - Turn lifecycle

    /// A new turn begins. Any turn still in flight is closed as abandoned so it isn't lost.
    func beginTurn() {
        if currentTurn != nil { abandonTurn() }
        currentTurn = TurnTimeline(startedAt: Date())
    }

    /// VAD (or the fallback timer) decided the user stopped speaking.
    func markSpeechEnd() {
        if currentTurn == nil { beginTurn() }
        setIfUnset(\.speechEndAt)
    }

    /// The command was handed to a backend.
    func markCommit(backend: String?, model: String?) {
        if currentTurn == nil { beginTurn() }
        setIfUnset(\.commitAt)
        // Backend/model can change between commit and generation (fallbacks, model switching),
        // so take the latest rather than first-wins.
        currentTurn?.backend = backend
        currentTurn?.model = model
    }

    /// First output token from the model.
    func markFirstToken() { setIfUnset(\.firstTokenAt) }

    /// Generation finished. `tokenCount` powers tok/s when the backend can report it.
    func markGenerationDone(tokenCount: Int? = nil) {
        setIfUnset(\.generationDoneAt)
        if let tokenCount { currentTurn?.tokenCount = tokenCount }
    }

    /// First audible sound of the reply — the end of the wearer's perceived wait.
    func markFirstAudio() { setIfUnset(\.firstAudioAt) }

    /// Playback finished; the turn is done and gets published.
    func markSpokeDone() {
        setIfUnset(\.spokeDoneAt)
        finishTurn()
    }

    /// The turn ended without delivering audio (interrupted, superseded, error).
    func abandonTurn() {
        guard var turn = currentTurn else { return }
        turn.abandoned = true
        currentTurn = turn
        finishTurn()
    }

    // MARK: - Private

    private func setIfUnset(_ keyPath: WritableKeyPath<TurnTimeline, Date?>) {
        guard var turn = currentTurn, turn[keyPath: keyPath] == nil else { return }
        turn[keyPath: keyPath] = Date()
        currentTurn = turn
    }

    private func finishTurn() {
        guard let turn = currentTurn else { return }
        currentTurn = nil
        recentTurns.insert(turn, at: 0)
        if recentTurns.count > maxHistory { recentTurns.removeLast(recentTurns.count - maxHistory) }
        for sink in sinks { sink.record(turn: turn) }
    }
}
