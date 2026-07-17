// OpenVision - TextReaderService.swift
// On-device text reading (OCR) for Read Mode.
//
// Apple Vision does the reading here — it runs entirely on-device, is deterministic, and CANNOT
// hallucinate. So the assistant reads back what is actually in front of the camera. When the user
// asks a question about the text, the LLM reasons ONLY over this already-extracted text (see
// `groundedPrompt`), which sidesteps the reliability problem that dominates on-device VLM
// accessibility research (models confidently inventing details a blind/low-vision user can't verify).

import Foundation
import Vision
import CoreImage
import CoreGraphics

/// Result of an on-device OCR pass. `lines` are in natural reading order.
struct OCRResult {
    let lines: [String]
    let fullText: String
    let averageConfidence: Float
    var hasText: Bool { !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

final class TextReaderService {
    static let shared = TextReaderService()
    private init() {}

    /// Laplacian-variance score below which a frame reads as "too blurry". Used ONLY to tailor the
    /// guidance message when OCR finds nothing ("hold steady" vs "move closer") — never as a hard
    /// pre-OCR gate, since OCR's own result is the reliable quality signal. Rough, scene-dependent;
    /// intentionally conservative so we don't nag a usable frame.
    static let blurThreshold: Double = 90

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - OCR

    /// Recognize text on-device. Lines are returned top→bottom, then left→right (reading order).
    /// Confidence is averaged across recognized lines (0–1).
    func recognizeText(in image: CIImage) async -> OCRResult {
        let empty = OCRResult(lines: [], fullText: "", averageConfidence: 0)
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return empty }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                // Vision's coordinate origin is bottom-left, so a higher midY sits higher on the
                // page. Group roughly into lines by y, then order left→right within a line.
                let sorted = observations.sorted { a, b in
                    if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.02 {
                        return a.boundingBox.midY > b.boundingBox.midY
                    }
                    return a.boundingBox.minX < b.boundingBox.minX
                }
                var lines: [String] = []
                var confSum: Float = 0, confN: Float = 0
                for obs in sorted {
                    guard let top = obs.topCandidates(1).first else { continue }
                    let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    lines.append(text)
                    confSum += top.confidence
                    confN += 1
                }
                let avg = confN > 0 ? confSum / confN : 0
                continuation.resume(returning: OCRResult(
                    lines: lines,
                    fullText: lines.joined(separator: "\n"),
                    averageConfidence: avg))
            }
            request.recognitionLevel = .accurate       // reading a document — accuracy over speed
            request.usesLanguageCorrection = true
            if #available(iOS 16.0, *) { request.automaticallyDetectsLanguage = true }

            do {
                try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
            } catch {
                NSLog("[OV] OCR failed: %@", "\(error)")
                continuation.resume(returning: empty)
            }
        }
    }

    // MARK: - Blur / sharpness

    /// Variance of the Laplacian on a downscaled grayscale copy. Higher = sharper. Cheap (runs on
    /// ~256px), used only to choose the guidance message when OCR comes back empty.
    func sharpness(of image: CIImage) -> Double {
        let unknown = Double.greatestFiniteMagnitude
        let targetW: CGFloat = 256
        let scale = targetW / max(image.extent.width, 1)
        let gray = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIPhotoEffectMono")
        let w = Int(gray.extent.width), h = Int(gray.extent.height)
        guard w > 2, h > 2, let cg = ciContext.createCGImage(gray, from: gray.extent) else { return unknown }

        var buffer = [UInt8](repeating: 0, count: w * h)
        let variance: Double = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return unknown }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            let px = raw.bindMemory(to: UInt8.self)
            var sum = 0.0, sumSq = 0.0, n = 0.0
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let c = Double(px[y * w + x])
                    let lap = 4 * c
                        - Double(px[(y - 1) * w + x]) - Double(px[(y + 1) * w + x])
                        - Double(px[y * w + x - 1]) - Double(px[y * w + x + 1])
                    sum += lap; sumSq += lap * lap; n += 1
                }
            }
            guard n > 0 else { return unknown }
            let mean = sum / n
            return sumSq / n - mean * mean
        }
        return variance
    }

    // MARK: - Prompt

    /// Grounded + abstention prompt for answering a question about the read text. Answer ONLY from
    /// the OCR text; never invent (false detail is especially harmful when the user can't verify it).
    static func groundedPrompt(ocrText: String, question: String) -> String {
        """
        You are reading text aloud for someone using smart glasses. They may be blind or low-vision, \
        so accuracy matters and they cannot double-check you. Below is the EXACT text captured from \
        what their camera is pointed at, via on-device OCR:

        \"\"\"
        \(ocrText)
        \"\"\"

        Their question: "\(question)"

        Answer using ONLY the text above. Give the direct answer first, then one brief helpful detail \
        if it is present. If the answer is not in the text, say you can't find it and suggest they \
        reposition the glasses — do NOT guess or add anything that isn't there. Reply in one or two \
        natural spoken sentences. No markdown, no preamble.
        """
    }
}
