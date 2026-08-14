// OpenVision - SpeechActivityDetector.swift
// Acoustic voice-activity detection (Silero VAD via CoreML) for end-of-turn.
//
// WHY THIS EXISTS
// The voice loop used to decide "the user has finished" from transcript timing: arm a timer, reset
// it whenever SFSpeechRecognizer emits a new partial, commit the turn when it fires. That signal
// cannot do the job. The recognizer delivers partials in bursts with ~1s gaps WHILE YOU ARE STILL
// TALKING, so any window short enough to feel responsive also fires mid-sentence. Ours was set to
// 4.0s to avoid that — and every single turn paid it before the model was even asked anything,
// which dominated end-to-end latency (a fast cloud model and a local one finished in about the
// same total time, because both waited the same 4 seconds first).
//
// Semantics of the partial transcript can't rescue it either: "what's the weather" is a complete
// sentence AND a prefix of "what's the weather in London tomorrow", so a grammatical
// completeness test commits mid-utterance. (Tried; it cut the user off; reverted.)
//
// So listen to the AUDIO instead. Silero tells us when speech actually stops, which is the
// question we were trying to answer all along. This is what production voice agents do — ChatGPT's
// voice mode endpoints on server-side VAD, Gemini Live on a client-side VAD signal.
//
// THREADING
// `feed(_:)` is called from the AVAudioEngine tap — the Core Audio render thread, ~45×/sec. It must
// never block, allocate unpredictably, or hop to the main actor. It does the cheap part inline
// (convert + accumulate under a lock) and hands full chunks to an AsyncStream. A single consumer
// task drains that stream in order, which matters because `VadStreamState` must be threaded
// sequentially through `processStreamingChunk`. Callbacks reach the main actor only on speech
// start/end transitions — a few times per turn, not per buffer.

import AVFoundation
import Foundation
import FluidAudio

/// Detects when speech starts and stops in a live mic stream.
///
/// Failure is always soft: if the model can't load, `isAvailable` stays false, no events are
/// emitted, and the caller keeps whatever timer-based behaviour it had. Voice input degrading to
/// "as it was before" is acceptable; breaking it is not.
final class SpeechActivityDetector: @unchecked Sendable {

    // MARK: - Events (delivered on the main actor)

    /// Speech began. Used to cancel any pending end-of-turn commit.
    var onSpeechStart: (@MainActor () -> Void)?

    /// Speech ended, after Silero's `minSilenceDuration` of hysteresis. This is the real
    /// end-of-turn signal — the caller can commit immediately or add a small grace window.
    var onSpeechEnd: (@MainActor () -> Void)?

    // MARK: - State

    /// True once the CoreML model is loaded and chunks are being scored.
    private(set) var isAvailable = false

    /// Serialises access to `pending` / `converter` between the audio thread and the consumer.
    private let lock = NSLock()

    /// 16 kHz mono samples not yet formed into a full VAD chunk.
    private var pending: [Float] = []

    /// Lazily built for the tap's actual input format — 48 kHz on the phone mic, 8 or 16 kHz on the
    /// glasses' Bluetooth HFP mic, and it changes on every route switch (see `reset()`).
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    private var vad: VadManager?
    private var chunks: AsyncStream<[Float]>.Continuation?
    private var consumerTask: Task<Void, Never>?

    /// Silero's own target format: 16 kHz mono Float32, scored in 4096-sample (256 ms) hops.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(VadManager.sampleRate),
        channels: 1,
        interleaved: false
    )

    // MARK: - Lifecycle

    /// Load the model and start consuming chunks. Safe to call repeatedly; a second call while
    /// already running is a no-op. Never throws — see the soft-failure note above.
    func start() async {
        guard consumerTask == nil else { return }

        let manager: VadManager
        do {
            // Threshold is deliberately above the library default (0.85): the glasses HFP mic is
            // 8 kHz and noisy, and a false "speech" only costs a little latency whereas a false
            // "silence" cuts the user off mid-sentence.
            manager = try await VadManager(config: VadConfig(defaultThreshold: 0.9))
        } catch {
            print("[VAD] Unavailable, falling back to timer-based end-of-turn: \(error)")
            isAvailable = false
            return
        }

        vad = manager
        isAvailable = true
        print("[VAD] Ready — acoustic end-of-turn active (threshold 0.9)")

        let (stream, continuation) = AsyncStream<[Float]>.makeStream(
            // The audio thread must never block on a slow consumer. If VAD inference falls behind,
            // drop the oldest chunk: stale audio is worthless for a liveness decision, and a
            // growing backlog would report speech-end later and later.
            bufferingPolicy: .bufferingNewest(8)
        )
        chunks = continuation

        consumerTask = Task { [weak self] in
            var state = await manager.makeStreamState()
            for await chunk in stream {
                guard !Task.isCancelled else { break }
                do {
                    let result = try await manager.processStreamingChunk(chunk, state: state)
                    state = result.state
                    if let event = result.event {
                        await self?.deliver(event)
                    }
                } catch {
                    // A single bad chunk shouldn't kill detection for the session.
                    print("[VAD] Chunk failed: \(error)")
                }
            }
        }
    }

    /// Stop consuming and release the model.
    func stop() {
        chunks?.finish()
        chunks = nil
        consumerTask?.cancel()
        consumerTask = nil
        vad = nil
        isAvailable = false
        lock.lock()
        pending.removeAll()
        converter = nil
        converterInputFormat = nil
        lock.unlock()
    }

    /// Drop buffered audio and converter state. Call on audio-route changes: a converter built for
    /// the old format produces garbage after the route flips (see the stale-format rule in
    /// docs — a stopped engine reports the pre-change format).
    func reset() {
        lock.lock()
        pending.removeAll()
        converter = nil
        converterInputFormat = nil
        lock.unlock()
    }

    // MARK: - Audio input

    /// Feed one buffer from the mic tap. **Called on the Core Audio render thread.**
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard isAvailable, let targetFormat else { return }

        guard let converted = convert(buffer, to: targetFormat) else { return }

        var ready: [[Float]] = []
        lock.lock()
        pending.append(contentsOf: converted)
        while pending.count >= VadManager.chunkSize {
            ready.append(Array(pending.prefix(VadManager.chunkSize)))
            pending.removeFirst(VadManager.chunkSize)
        }
        lock.unlock()

        // yield() is non-blocking and thread-safe — the whole reason for the AsyncStream hop.
        for chunk in ready { chunks?.yield(chunk) }
    }

    // MARK: - Private

    @MainActor
    private func deliver(_ event: VadStreamEvent) {
        switch event.kind {
        case .speechStart:
            print("[VAD] speechStart")
            onSpeechStart?()
        case .speechEnd:
            print("[VAD] speechEnd")
            onSpeechEnd?()
        }
    }

    /// Resample/downmix a tap buffer to 16 kHz mono Float32.
    private func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> [Float]? {
        lock.lock()
        if converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterInputFormat = buffer.format
        }
        guard let converter else { lock.unlock(); return nil }
        lock.unlock()

        // Ratio-sized output with headroom; the converter reports what it actually wrote.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard capacity > 0,
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            // Hand the input over exactly once; reporting more would loop forever.
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, out.frameLength > 0,
              let channel = out.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}
