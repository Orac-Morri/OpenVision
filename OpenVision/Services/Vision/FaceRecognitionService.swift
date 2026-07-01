// OpenVision - FaceRecognitionService.swift
// On-device face recognition using Apple's Vision framework — no cloud, no model download.
//
// Pipeline: detect faces (VNDetectFaceRectangles) → crop → make a feature vector
// (VNGenerateImageFeaturePrint) → match against saved faces by cosine similarity.
// Faces are stored locally as JSON (name + feature vector). Approximate, not biometric-grade,
// but private and lightweight — good for recognising a handful of people you've enrolled.

import Foundation
import Vision
import UIKit

@MainActor
final class FaceRecognitionService: ObservableObject {

    static let shared = FaceRecognitionService()

    @Published private(set) var knownFaces: [KnownFace] = []

    struct KnownFace: Codable, Identifiable {
        var id = UUID()
        var name: String
        let faceprint: [Float]
        var lastSeen: Date
    }

    /// Cosine-similarity threshold (0–1). Higher = stricter. Tune if you get false matches.
    private let matchThreshold: Float = 0.6

    private let storageURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storageURL = docs.appendingPathComponent("known_faces.json")
        load()
    }

    // MARK: - Enroll / manage

    /// Remember the face in `image` under `name`. Updates the stored print if the name exists.
    func rememberFace(name: String, from image: UIImage) async -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return "What name should I save them under?" }
        guard let cgImage = image.cgImage else { return "I couldn't get a clear picture — try again." }

        let prints = await Self.faceprints(in: cgImage)
        guard let faceprint = prints.first else {
            return "I don't see a face clearly. Have them look toward you and try again."
        }

        if let idx = knownFaces.firstIndex(where: { $0.name.lowercased() == cleanName.lowercased() }) {
            knownFaces[idx] = KnownFace(id: knownFaces[idx].id, name: cleanName, faceprint: faceprint, lastSeen: Date())
        } else {
            knownFaces.append(KnownFace(name: cleanName, faceprint: faceprint, lastSeen: Date()))
        }
        save()
        return "Got it — I'll remember \(cleanName)."
    }

    /// Identify who is in `image`. Returns a spoken-friendly answer.
    func identify(in image: UIImage) async -> String {
        guard !knownFaces.isEmpty else {
            return "I don't know anyone yet. Say “remember this is …” to teach me a face."
        }
        guard let cgImage = image.cgImage else { return "I couldn't get a clear picture — try again." }

        let prints = await Self.faceprints(in: cgImage)
        guard !prints.isEmpty else { return "I don't see anyone right now." }

        var names: [String] = []
        for fp in prints {
            if let idx = bestMatch(for: fp) {
                knownFaces[idx].lastSeen = Date()
                names.append(knownFaces[idx].name)
            }
        }
        save()

        switch names.count {
        case 0: return "I see a face, but I don't recognise them."
        case 1: return "That's \(names[0])."
        default: return "I recognise \(names.joined(separator: ", "))."
        }
    }

    func forgetFace(name: String) -> String {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let before = knownFaces.count
        knownFaces.removeAll { $0.name.lowercased() == target }
        save()
        return knownFaces.count < before ? "Okay, I've forgotten \(name)." : "I don't have anyone named \(name)."
    }

    func listKnownFaces() -> String {
        guard !knownFaces.isEmpty else { return "I don't know anyone yet." }
        let names = knownFaces.map { $0.name }
        return names.count == 1 ? "I know \(names[0])." : "I know \(names.count) people: \(names.joined(separator: ", "))."
    }

    // MARK: - Vision (runs off the main thread)

    /// Detect faces in `cgImage` and return a feature vector per face.
    nonisolated private static func faceprints(in cgImage: CGImage) async -> [[Float]] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: (try? computeFaceprints(cgImage)) ?? [])
            }
        }
    }

    nonisolated private static func computeFaceprints(_ cgImage: CGImage) throws -> [[Float]] {
        let faceRequest = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([faceRequest])
        guard let faces = faceRequest.results, !faces.isEmpty else { return [] }

        var prints: [[Float]] = []
        for face in faces.prefix(5) {
            guard let cropped = cropFace(from: cgImage, boundingBox: face.boundingBox) else { continue }
            let printRequest = VNGenerateImageFeaturePrintRequest()
            try VNImageRequestHandler(cgImage: cropped, options: [:]).perform([printRequest])
            guard let observation = printRequest.results?.first else { continue }

            let data = observation.data
            let count = data.count / MemoryLayout<Float>.size
            var floats = [Float](repeating: 0, count: count)
            _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            prints.append(floats)
        }
        return prints
    }

    /// Crop to the face region (Vision boxes are normalised, origin bottom-left) with padding.
    nonisolated private static func cropFace(from cgImage: CGImage, boundingBox: CGRect) -> CGImage? {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let pad: CGFloat = 0.15
        var rect = CGRect(
            x: (boundingBox.origin.x - pad * boundingBox.width) * w,
            y: (1 - boundingBox.origin.y - boundingBox.height - pad * boundingBox.height) * h,
            width: boundingBox.width * (1 + 2 * pad) * w,
            height: boundingBox.height * (1 + 2 * pad) * h
        )
        rect = rect.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !rect.isNull, rect.width > 1, rect.height > 1 else { return nil }
        return cgImage.cropping(to: rect)
    }

    // MARK: - Matching

    private func bestMatch(for faceprint: [Float]) -> Int? {
        var best: Int?
        var bestScore: Float = matchThreshold
        for (idx, known) in knownFaces.enumerated() where known.faceprint.count == faceprint.count {
            let score = Self.cosineSimilarity(faceprint, known.faceprint)
            if score > bestScore { bestScore = score; best = idx }
        }
        return best
    }

    nonisolated private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, magA: Float = 0, magB: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; magA += a[i] * a[i]; magB += b[i] * b[i] }
        let mag = sqrt(magA) * sqrt(magB)
        return mag > 0 ? dot / mag : 0
    }

    // MARK: - Persistence

    private func save() {
        try? JSONEncoder().encode(knownFaces).write(to: storageURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let faces = try? JSONDecoder().decode([KnownFace].self, from: data) else { return }
        knownFaces = faces
    }
}
