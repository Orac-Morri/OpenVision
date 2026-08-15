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
    /// When text was handed to the speech engine. Distinct from `generationDoneAt`: on a streamed
    /// reply the first sentence is sent while the model is still writing the rest.
    var ttsRequestedAt: Date?
    var firstAudioAt: Date?
    var spokeDoneAt: Date?

    /// Which backend served this turn (local model id, "openai", "apple_foundation", …).
    var backend: String?
    /// Model identifier when known — lets the backend group tok/s by model.
    var model: String?
    /// Which speech engine spoke this turn ("kokoro" / "apple").
    ///
    /// Tagged because the engine changes the whole pipeline, not just the voice: one streams
    /// sentences while the model generates, the other waits for the full reply. Comparing turns
    /// without splitting on it mixes two different behaviours — and Kokoro synthesising on the
    /// Metal GPU measurably slows decode, so tok/s is only comparable within one engine.
    var ttsEngine: String?
    /// Tokens produced, for tok/s. Nil when the backend doesn't report it (cloud streaming).
    ///
    /// ACCUMULATED across generation passes: a routed turn can run the model more than once
    /// (route -> answer, or search-reformulate -> answer). Overwriting instead of accumulating
    /// once paired pass-2's token count with pass-1's time window — a fabricated rate.
    var tokenCount: Int?

    /// Exact decode time reported by the generation library (`GenerateCompletionInfo.generateTime`),
    /// accumulated across passes like `tokenCount`. This — not timeline-timestamp deltas — is the
    /// denominator for tok/s: timeline stamps are first-wins and get backfilled for non-streaming
    /// backends, so a rate derived from them can silently cover a different span than the tokens.
    var generationSeconds: TimeInterval?

    /// Time spent acquiring a camera frame before a vision turn's model call (live video mode).
    /// Kept separate so it's visible: it happens between commit and first token, so `ttft` on
    /// vision turns INCLUDES it — comparing vision ttft against text ttft without this number
    /// blames the model for time spent waiting on the glasses' Bluetooth stream.
    var frameGrabSeconds: TimeInterval?
    /// True when the turn ended early (interrupted/superseded/error) rather than completing.
    /// This is the "E" in RED — a turn that failed is a failure whether or not it was slow.
    var abandoned: Bool = false

    /// True when the user spoke over the assistant during this turn (barge-in). Industry tracks
    /// interruption rate as a satisfaction signal — repeated interruptions mean the agent is
    /// talking too long, answering wrongly, or being too slow to be worth waiting for.
    var interrupted: Bool = false

    init(id: UUID = UUID(), startedAt: Date) {
        self.id = id
        self.startedAt = startedAt
    }

    // MARK: - Derived durations (seconds; nil when either endpoint is missing)

    /// Endpoint decision cost: silence detected -> handed to the backend.
    var commitDuration: TimeInterval? { Self.delta(speechEndAt, commitAt) }

    /// Backend think time before any output. Includes network for cloud, prompt eval for local.
    var timeToFirstToken: TimeInterval? { Self.delta(commitAt, firstTokenAt) }

    /// Wall-clock span from first token (first pass) to generation end (last pass). On a
    /// multi-pass turn this INCLUDES time between passes — e.g. the web search a routed turn runs
    /// between routing and answering — so it is a coarse fallback, not decode time. Prefer
    /// `generationSeconds` (exact, library-reported, decode only) whenever it exists.
    var generationDuration: TimeInterval? { Self.delta(firstTokenAt, generationDoneAt) }

    /// Best available generation time: exact accumulated decode when the backend reported it,
    /// otherwise the wall-clock span above (cloud/Apple backends that only get backstop marks).
    var generationSecondsBestEffort: TimeInterval? { generationSeconds ?? generationDuration }

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

    /// Speech-engine time-to-first-byte: text handed to TTS -> first audible sound.
    ///
    /// The industry-standard TTS metric (targets are around 150 ms for cloud engines). Distinct
    /// from `ttsLeadIn`, which is measured from GENERATION being finished: on a streamed reply the
    /// first sentence goes to the engine long before the model stops writing, so lead-in can be
    /// negative while this stays positive. This is the one that answers "how slow is synthesis?"
    var ttsTimeToFirstByte: TimeInterval? { Self.delta(ttsRequestedAt, firstAudioAt) }

    /// THE headline: how long the wearer waits in silence after they stop speaking.
    var perceivedLatency: TimeInterval? { Self.delta(speechEndAt, firstAudioAt) }

    /// Whole turn including playback.
    var totalDuration: TimeInterval? { Self.delta(speechEndAt, spokeDoneAt) }

    /// Decode rate, computed ONLY from the library-reported pair (token count + generate time),
    /// both accumulated over the same passes. Never derived from timeline timestamps: those are
    /// first-wins and backfilled for non-streaming backends, which produced two past bugs — a
    /// microsecond window dividing into millions of tok/s, and pass-2 tokens over a pass-1 window.
    /// The minimum-window guard stays as a sanity check; no rate is better than a fictional one.
    static let minimumRateWindow: TimeInterval = 0.05

    var tokensPerSecond: Double? {
        guard let tokens = tokenCount, tokens > 0,
              let seconds = generationSeconds,
              seconds >= Self.minimumRateWindow else { return nil }
        return Double(tokens) / seconds
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
