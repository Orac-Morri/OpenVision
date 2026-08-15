// OpenVision - FrameChange.swift
// Pure gating logic for the continuous live-vision loop: when is a frame worth describing, and
// when is a description worth saying out loud.
//
// The loop's economics: FastVLM inference costs ~1-2s of GPU per frame and speech costs GPU
// contention on top (measured: decode drops ~40% while Kokoro synthesises). Most frames are the
// same scene, and most fresh descriptions of the same scene differ only in wording — so both
// gates exist to spend inference and speech ONLY on change. Thresholds were the cheap-to-tune
// part; keeping the math pure (byte arrays and strings, no UIKit) makes them unit-testable.

import Foundation

enum FrameChange {

    /// Mean absolute difference between two equal-length grayscale thumbnails, normalised to 0…1.
    /// Thumbnails come from downscaling frames to a few hundred pixels — enough to notice the
    /// wearer turning their head or an object entering view, cheap enough to run per frame.
    /// Returns 1 (maximally different) on length mismatch so a resolution change never gets
    /// silently treated as "same scene".
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 1 }
        var total = 0
        for i in 0..<a.count {
            total += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(total) / (255.0 * Double(a.count))
    }

    /// Scene-change threshold on `difference`. Below this the view is considered unchanged and
    /// the frame is skipped without inference. 0.06 ≈ small lighting flicker and BT compression
    /// noise stay under it; turning the head or swapping the object in hand lands well above.
    static let sceneChangeThreshold = 0.06

    static func isNewScene(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        difference(a, b) > sceneChangeThreshold
    }

    /// Word-overlap similarity between two descriptions, 0…1 (Jaccard over lowercased words).
    /// Used to decide whether a fresh description says anything NEW — the model rephrases the
    /// same scene endlessly ("a man at a desk" / "a person sitting at a desk"), and speaking
    /// every rephrase is noise.
    static func similarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let wordsB = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 1 }
        let union = wordsA.union(wordsB)
        guard !union.isEmpty else { return 1 }
        return Double(wordsA.intersection(wordsB).count) / Double(union.count)
    }

    /// Speak when similarity to the last SPOKEN description falls below this. Deliberately
    /// permissive (rephrasings share most content words and score high; a genuinely new subject
    /// shares few) — the cost of a false "same" is a missed announcement, the cost of a false
    /// "new" is chatter, and chatter is worse on glasses.
    static let spokenSimilarityThreshold = 0.5

    static func isWorthSpeaking(_ new: String, lastSpoken: String?) -> Bool {
        guard let lastSpoken, !lastSpoken.isEmpty else { return true }
        return similarity(new, lastSpoken) < spokenSimilarityThreshold
    }
}
