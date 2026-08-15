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

    /// Record a counted occurrence (wake word heard, recognizer restarted, …).
    ///
    /// Speech-recognition QUALITY is otherwise invisible: transcripts arrive garbled
    /// ("53258 Okay Vision") with nothing to measure. Counting wake-word detections against
    /// completed commands, and counting recognizer restarts, gives a usable proxy — a high
    /// restart rate means the recognizer is churning, which is what shreds transcripts.
    /// Names only; never anything the user said.
    func count(_ event: String) {
        let now = Date()
        eventCounts[event, default: 0] += 1
        for sink in sinks { sink.record(event: event, at: now) }
    }

    /// Running totals for this app run, shown in the debug panel.
    @Published private(set) var eventCounts: [String: Int] = [:]

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
    func markCommit(backend: String?, model: String?, ttsEngine: String? = nil) {
        if currentTurn == nil { beginTurn() }
        setIfUnset(\.commitAt)
        // Backend/model can change between commit and generation (fallbacks, model switching),
        // so take the latest rather than first-wins.
        currentTurn?.backend = backend
        currentTurn?.model = model
        currentTurn?.ttsEngine = ttsEngine
    }

    /// First output token from the model.
    func markFirstToken() { setIfUnset(\.firstTokenAt) }

    /// Generation finished. `tokenCount` powers tok/s when the backend can report it.
    ///
    /// Backfills `firstTokenAt` because generation cannot finish without having started, and the
    /// two marks arrive in either order depending on the backend: streaming paths report a first
    /// token early, non-streaming ones never report it at all and would otherwise leave the whole
    /// post-commit breakdown missing (or, if marked later, negative).
    func markGenerationDone(tokenCount: Int? = nil) {
        setIfUnset(\.firstTokenAt)
        setIfUnset(\.generationDoneAt)
        if let tokenCount { currentTurn?.tokenCount = tokenCount }
    }

    /// Text was handed to the speech engine. Starts the TTS time-to-first-byte clock.
    func markTTSRequested() { setIfUnset(\.ttsRequestedAt) }

    /// First audible sound of the reply — the end of the wearer's perceived wait.
    func markFirstAudio() { setIfUnset(\.firstAudioAt) }

    /// The user spoke over the assistant. Recorded on the turn being interrupted, so interruption
    /// rate can be read per model/engine — a slow or wrong answer gets talked over more.
    func markInterrupted() {
        guard var turn = currentTurn else { return }
        turn.interrupted = true
        currentTurn = turn
    }

    /// Playback finished; the turn is done and gets published.
    ///
    /// Guarded on `firstAudioAt` because "TTS stopped" is not the same event as "this turn's reply
    /// finished". The previous reply's playback ending — or being cut short by barge-in, a wake
    /// word, or session teardown — arrives AFTER the next turn has already begun, and without this
    /// guard it closed that turn seconds early, publishing a timeline that had only reached commit.
    func markSpokeDone() {
        guard currentTurn?.firstAudioAt != nil else { return }
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
