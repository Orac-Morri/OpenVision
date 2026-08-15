// OpenVision - FrameChangeTests.swift
// Gating for the continuous live-vision loop: frame-difference and speak-worthiness thresholds.

import XCTest
@testable import OpenVision

final class FrameChangeTests: XCTestCase {

    // MARK: - Pixel difference

    func testIdenticalThumbnailsAreZero() {
        let a: [UInt8] = [10, 200, 55, 0, 255]
        XCTAssertEqual(FrameChange.difference(a, a), 0)
    }

    func testMaximallyDifferentThumbnailsAreOne() {
        XCTAssertEqual(FrameChange.difference([0, 0, 0], [255, 255, 255]), 1)
    }

    func testLengthMismatchIsTreatedAsFullyDifferent() {
        // A resolution change must never read as "same scene".
        XCTAssertEqual(FrameChange.difference([1, 2, 3], [1, 2]), 1)
        XCTAssertEqual(FrameChange.difference([], []), 1)
    }

    func testSmallNoiseStaysUnderSceneThreshold() {
        // ±5 gray levels everywhere ≈ BT compression flicker — must not trigger inference.
        let base = [UInt8](repeating: 128, count: 256)
        let noisy = base.map { UInt8(Int($0) + 5) }
        XCTAssertFalse(FrameChange.isNewScene(base, noisy))
    }

    func testLargeChangeCrossesSceneThreshold() {
        // Half the view changing brightness strongly = head turn / new subject.
        let base = [UInt8](repeating: 40, count: 256)
        var moved = base
        for i in 0..<128 { moved[i] = 200 }
        XCTAssertTrue(FrameChange.isNewScene(base, moved))
    }

    // MARK: - Description similarity

    func testRephrasingScoresHigh() {
        let s = FrameChange.similarity("a man sitting at a desk", "a man at a desk")
        XCTAssertGreaterThan(s, FrameChange.spokenSimilarityThreshold)
    }

    func testNewSubjectScoresLow() {
        let s = FrameChange.similarity("a man sitting at a desk", "a coffee mug on a wooden table")
        XCTAssertLessThan(s, FrameChange.spokenSimilarityThreshold)
    }

    func testCaseAndPunctuationIgnored() {
        XCTAssertEqual(FrameChange.similarity("A red car.", "a RED car"), 1)
    }

    // MARK: - Speak gate

    func testFirstDescriptionAlwaysSpoken() {
        XCTAssertTrue(FrameChange.isWorthSpeaking("a man at a desk", lastSpoken: nil))
        XCTAssertTrue(FrameChange.isWorthSpeaking("a man at a desk", lastSpoken: ""))
    }

    func testRephraseOfSameSceneIsNotSpoken() {
        XCTAssertFalse(FrameChange.isWorthSpeaking(
            "a person sitting at a desk with a laptop",
            lastSpoken: "a man sitting at a desk using a laptop"))
    }

    func testGenuinelyNewSceneIsSpoken() {
        XCTAssertTrue(FrameChange.isWorthSpeaking(
            "a hallway with a red fire extinguisher",
            lastSpoken: "a man sitting at a desk using a laptop"))
    }
}
