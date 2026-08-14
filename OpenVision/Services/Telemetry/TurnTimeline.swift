// OpenVision - TurnTimeline.swift
// Latency breakdown of one voice turn, from "the user stopped talking" to "the reply is speaking".
//
// This is the metric the whole telemetry effort exists for. Chasing perceived slowness by feel
// cost a lot of guessing: the real culprit turned out to be a flat 4s end-of-turn timeout that a
// fast cloud model and a local one paid identically — obvious in one glance at these numbers,
// invisible without them.
//
// Stages, in order:
//   speechEnd   the mic went quiet (acoustic VAD)
//   commit      the turn was handed to a backend
//   firstToken  the model produced its first output       <- "is the MODEL slow?"
//   genDone     the model finished the reply
//   firstAudio  the user actually HEARS something         <- perceived latency ends here
//   spokeDone   playback finished
//
// `perceivedLatency` (speechEnd -> firstAudio) is the headline number: everything before it is
// dead air from the wearer's point of view.

import Foundation

/// Timestamps for a single turn. Stages are optional because a turn can be abandoned at any point
/// (interrupted, superseded, error) and a partial timeline is still worth recording.
struct TurnTimeline: Identifiable, Sendable {
    let id: UUID
    let startedAt: Date

    var speechEndAt: Date?
    var commitAt: Date?
    var firstTokenAt: Date?
    var generationDoneAt: Date?
    var firstAudioAt: Date?
    var spokeDoneAt: Date?

    /// Which backend served this turn (local model id, "openai", "apple_foundation", …).
    var backend: String?
    /// Model identifier when known — lets the backend group tok/s by model.
    var model: String?
    /// Tokens produced, for tok/s. Nil when the backend doesn't report it (cloud streaming).
    var tokenCount: Int?
    /// True when the turn ended early (interrupted/superseded/error) rather than completing.
    var abandoned: Bool = false

    init(id: UUID = UUID(), startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }

    // MARK: - Derived durations (seconds; nil when either endpoint is missing)

    /// Endpoint decision cost: silence detected -> handed to the backend.
    var commitDuration: TimeInterval? { Self.delta(speechEndAt, commitAt) }

    /// Backend think time before any output. Includes network for cloud, prompt eval for local.
    var timeToFirstToken: TimeInterval? { Self.delta(commitAt, firstTokenAt) }

    /// Pure generation time after the first token.
    var generationDuration: TimeInterval? { Self.delta(firstTokenAt, generationDoneAt) }

    /// Synthesis lead-in: reply text ready -> first audible sound. **Signed on purpose.**
    ///
    /// Positive means TTS is serialised behind generation — nothing is spoken until the whole
    /// reply exists (the Kokoro path). NEGATIVE means speech started while the model was still
    /// generating (the streaming Apple-TTS path), which is the good case and the entire point of
    /// pipelining. Clamping negatives to nil, as the other stages do, silently deleted this
    /// metric on exactly the turns it was meant to characterise.
    var ttsLeadIn: TimeInterval? {
        guard let generationDoneAt, let firstAudioAt else { return nil }
        return firstAudioAt.timeIntervalSince(generationDoneAt)
    }

    /// THE headline: how long the wearer waits in silence after they stop speaking.
    var perceivedLatency: TimeInterval? { Self.delta(speechEndAt, firstAudioAt) }

    /// Whole turn including playback.
    var totalDuration: TimeInterval? { Self.delta(speechEndAt, spokeDoneAt) }

    /// Generation rate. Uses first-token -> done so it measures decode speed, not queueing.
    ///
    /// Requires a plausible window, not merely a positive one: when a backend doesn't stream,
    /// `firstTokenAt` is backfilled to the same instant as `generationDoneAt`, leaving a
    /// microsecond duration that divides into millions of tokens/sec and wrecks the chart scale.
    /// No rate is better than a fictional one.
    static let minimumRateWindow: TimeInterval = 0.05

    var tokensPerSecond: Double? {
        guard let tokens = tokenCount, tokens > 0,
              let duration = generationDuration,
              duration >= Self.minimumRateWindow else { return nil }
        return Double(tokens) / duration
    }

    /// True once the turn reached audible output — the point where it counts as "delivered".
    var isComplete: Bool { firstAudioAt != nil }

    private static func delta(_ from: Date?, _ to: Date?) -> TimeInterval? {
        guard let from, let to else { return nil }
        let seconds = to.timeIntervalSince(from)
        // Clock skew or out-of-order marks would otherwise publish negative durations.
        return seconds >= 0 ? seconds : nil
    }
}
