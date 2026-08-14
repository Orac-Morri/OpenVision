// OpenVision - TurnEndpointingTests.swift
// Adaptive end-of-turn detection: commit fast on finished thoughts, wait on dangling ones.
//
// The two failure modes these guard against pull in opposite directions:
//   - too eager  → the user is cut off mid-sentence (worst outcome, so `incomplete` cases dominate)
//   - too patient → every turn pays a fixed delay before the model starts (the old 4.0s behaviour)

import XCTest
@testable import OpenVision

final class TurnEndpointingTests: XCTestCase {

    // MARK: - Complete utterances (should commit fast)

    func testPlainQuestionIsComplete() {
        XCTAssertTrue(TurnEndpointing.isLikelyComplete("what's the weather"))
    }

    func testTerminalPunctuationIsComplete() {
        XCTAssertTrue(TurnEndpointing.isLikelyComplete("Set a timer for five minutes."))
        XCTAssertTrue(TurnEndpointing.isLikelyComplete("Are we there yet?"))
        XCTAssertTrue(TurnEndpointing.isLikelyComplete("Stop!"))
    }

    func testPunctuationWinsOverDanglingWord() {
        // The recognizer only emits a terminator when confident — trust it even though the last
        // word is in the dangling set.
        XCTAssertTrue(TurnEndpointing.isLikelyComplete("I know what you did."))
    }

    func testCommandWithObjectIsComplete() {
        XCTAssertTrue(TurnEndpointing.isLikelyComplete("take a photo"))
        XCTAssertTrue(TurnEndpointing.isLikelyComplete("remind me to call mom tomorrow"))
    }

    func testContractionIsNotTreatedAsDangling() {
        // "what's" must survive tokenization intact; splitting it would leave a dangling "what".
        XCTAssertTrue(TurnEndpointing.isLikelyComplete("what's that"))
    }

    func testQuestionsEndingInPronounOrDemonstrativeAreComplete() {
        // Regression: these words are determiners/subjects grammatically, so an over-eager
        // dangling list catches them — but they end some of the most common questions there are,
        // and listing them cost 3s every time.
        XCTAssertTrue(TurnEndpointing.isLikelyComplete("how are you"))
        XCTAssertTrue(TurnEndpointing.isLikelyComplete("what is it"))
        XCTAssertTrue(TurnEndpointing.isLikelyComplete("who are they"))
        XCTAssertTrue(TurnEndpointing.isLikelyComplete("what is this"))
        XCTAssertTrue(TurnEndpointing.isLikelyComplete("read that"))
    }

    // MARK: - Incomplete utterances (should keep waiting)

    func testTrailingArticleIsIncomplete() {
        XCTAssertFalse(TurnEndpointing.isLikelyComplete("what is the"))
        XCTAssertFalse(TurnEndpointing.isLikelyComplete("show me a"))
    }

    func testTrailingPrepositionIsIncomplete() {
        XCTAssertFalse(TurnEndpointing.isLikelyComplete("tell me about"))
        XCTAssertFalse(TurnEndpointing.isLikelyComplete("set a reminder for"))
    }

    func testTrailingConjunctionIsIncomplete() {
        XCTAssertFalse(TurnEndpointing.isLikelyComplete("turn on the light and"))
        XCTAssertFalse(TurnEndpointing.isLikelyComplete("go to the shop because"))
    }

    func testTrailingAuxiliaryIsIncomplete() {
        XCTAssertFalse(TurnEndpointing.isLikelyComplete("the weather is"))
        XCTAssertFalse(TurnEndpointing.isLikelyComplete("i would"))
    }

    func testTrailingFillerIsIncomplete() {
        XCTAssertFalse(TurnEndpointing.isLikelyComplete("remind me to um"))
        XCTAssertFalse(TurnEndpointing.isLikelyComplete("i want to, uh"))
    }

    func testVeryShortTranscriptIsIncomplete() {
        // Likely a fragment of a longer sentence still streaming in.
        XCTAssertFalse(TurnEndpointing.isLikelyComplete("what"))
        XCTAssertFalse(TurnEndpointing.isLikelyComplete("hey"))
    }

    func testEmptyAndWhitespaceAreIncomplete() {
        XCTAssertFalse(TurnEndpointing.isLikelyComplete(""))
        XCTAssertFalse(TurnEndpointing.isLikelyComplete("   \n  "))
    }

    // MARK: - Timeout selection

    func testTimeoutMatchesCompleteness() {
        XCTAssertEqual(TurnEndpointing.silenceTimeout(for: "what's the weather"),
                       TurnEndpointing.completeTimeout)
        XCTAssertEqual(TurnEndpointing.silenceTimeout(for: "what is the"),
                       TurnEndpointing.incompleteTimeout)
    }

    func testFastPathIsActuallyFasterThanTheOldFixedWait() {
        // Regression guard on the whole point of this type.
        XCTAssertLessThan(TurnEndpointing.completeTimeout, TurnEndpointing.incompleteTimeout)
        XCTAssertLessThan(TurnEndpointing.completeTimeout, 1.5)
    }

    // MARK: - Tokenization

    func testTokenizeStripsPunctuationAndCase() {
        XCTAssertEqual(TurnEndpointing.tokenize("Hello, World!"), ["hello", "world"])
    }

    func testTokenizeKeepsInternalApostrophe() {
        XCTAssertEqual(TurnEndpointing.tokenize("what's up"), ["what's", "up"])
    }

    func testTokenizeDropsEmptyTokens() {
        XCTAssertEqual(TurnEndpointing.tokenize("hi   --  there"), ["hi", "there"])
    }
}
