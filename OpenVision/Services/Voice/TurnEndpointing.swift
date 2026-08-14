// OpenVision - TurnEndpointing.swift
// Decides HOW LONG to wait after speech stops before treating a turn as finished.
//
// Why this exists: a single fixed silence timeout can't tell "I'm still thinking" from "I'm done".
// Set it long (we shipped 4.0s) and every turn pays that toll before the model even starts — the
// dominant cost in the whole voice loop, paid identically by a fast cloud model and a local one.
// Set it short and it guillotines anyone who pauses mid-sentence.
//
// So instead of one timeout we pick one based on what was actually said. This is the cheap,
// dependency-free half of "semantic endpointing" as used by voice agents: an utterance that reads
// grammatically complete commits fast; one that dangles ("what is the…", "tell me about…") keeps
// the long window. Purely lexical — no model, no network, no GPU contention with on-device
// inference. See docs for the upgrade path to a real turn-detector model.

import Foundation

/// Pure endpointing helpers (unit-testable; no timers, no state, no I/O).
enum TurnEndpointing {

    /// Fired when the utterance reads finished. Long enough to ride out the tiny gaps inside
    /// normal speech, short enough to feel responsive.
    static let completeTimeout: TimeInterval = 0.8

    /// Fired when the utterance clearly dangles — the speaker is mid-thought. Generous on purpose:
    /// being slow here is a much smaller sin than cutting someone off.
    static let incompleteTimeout: TimeInterval = 3.0

    /// Very short transcripts are usually a recognizer fragment of a longer sentence still arriving,
    /// not a real one-word command, so they get the long window too.
    static let minimumWordsForFastCommit = 2

    /// Words that almost never end an English sentence. If the utterance stops on one of these the
    /// speaker is mid-thought, whatever the punctuation says.
    ///
    /// Kept deliberately tight: every entry here costs latency when it misfires, so this covers
    /// function words that dangle unambiguously rather than trying to be a grammar.
    /// Demonstratives ("that", "this") and personal pronouns ("you", "it", "they") are deliberately
    /// ABSENT: they are grammatically determiners/subjects, but they very often *end* a finished
    /// question — "what's that", "how are you", "what is it". Listing them cost 3 seconds on some
    /// of the most common utterances there are.
    private static let danglingWords: Set<String> = [
        // articles & determiners
        "a", "an", "the", "my", "your", "our", "their", "its",
        "his", "her", "some", "any", "every", "each", "both", "another",
        // prepositions
        "of", "to", "in", "on", "at", "for", "with", "from", "by", "about", "into", "onto",
        "over", "under", "between", "through", "during", "before", "after", "above", "below",
        "near", "toward", "towards", "upon", "within", "without", "across", "against",
        // conjunctions
        "and", "or", "but", "nor", "yet", "so", "because", "although", "though", "while",
        "whereas", "unless", "until", "if", "than", "whether",
        // auxiliaries & copulas
        "is", "are", "was", "were", "am", "be", "been", "being", "do", "does", "did", "have",
        "has", "had", "will", "would", "can", "could", "should", "shall", "may", "might", "must",
        // interrogatives / relatives (trailing "what is the ..." style)
        "what", "which", "who", "whom", "whose", "where", "when", "why", "how",
        // very common trailing verbs that take an object
        "want", "need", "like", "tell", "show", "give", "find", "make", "let", "get", "put",
        "take", "send", "set", "add", "call", "play", "open", "turn"
    ]

    /// Filler sounds that mean "still talking" — a transcript ending here is a thinking pause.
    private static let fillers: Set<String> = [
        "um", "uh", "erm", "hmm", "hm", "ah", "er", "eh", "like", "well", "so", "okay", "ok"
    ]

    /// How long to wait for more speech, given the transcript captured so far.
    ///
    /// - Parameter transcript: what the recognizer has produced for this turn.
    /// - Returns: the silence window to arm before committing the turn.
    static func silenceTimeout(for transcript: String) -> TimeInterval {
        isLikelyComplete(transcript) ? completeTimeout : incompleteTimeout
    }

    /// True when the transcript reads like a finished thought.
    ///
    /// Order matters: explicit terminal punctuation wins outright (the recognizer only emits it
    /// when confident), then we reject utterances that are too short or end on a dangling word.
    static func isLikelyComplete(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Terminal punctuation from the recognizer is a strong, trustworthy signal.
        if let last = trimmed.last, last == "." || last == "?" || last == "!" {
            return true
        }

        let words = tokenize(trimmed)
        guard words.count >= minimumWordsForFastCommit else { return false }
        guard let last = words.last else { return false }

        // Trailing filler ("...tell me about, um") = still composing.
        if fillers.contains(last) { return false }

        // Dangling function word = the object of the sentence hasn't been said yet.
        if danglingWords.contains(last) { return false }

        return true
    }

    /// Lowercased word list with surrounding punctuation stripped. Keeps intra-word apostrophes
    /// so "what's" stays one token rather than becoming a dangling "what".
    static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { word in
                String(word.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()[]{}…-")))
            }
            .filter { !$0.isEmpty }
    }
}
