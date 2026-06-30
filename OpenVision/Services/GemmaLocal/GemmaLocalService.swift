// OpenVision - GemmaLocalService.swift
// On-device Gemma 4 backend (text tier) running via Apple MLX.
//
// Conforms to the same backend shape as OpenClawService / GeminiLiveService:
// `.shared` singleton, @MainActor, AIConnectionState, callbacks (not Combine for events),
// connect()/disconnect()/sendMessage(). "Connect" loads the model into memory; "disconnect"
// unloads it. Selection is a manual knob (Settings → AI Backend → Local (Gemma 4)).
//
// Uses the native Gemma 4 VLM in mlx-swift-lm 3.31.3 (registered in VLMModelFactory as
// "gemma4"), which handles BOTH text and vision — so "what's this?" with a glasses photo
// runs fully on-device. No custom model port or pixel preprocessing needed: images go in
// via UserInput / Chat.Message and the model's processor handles the rest.
//
// NOTE: Requires iOS 18+ and a physical device (MLX is unavailable on the Simulator).

import Foundation
import CoreImage
import MLX
import MLXVLM            // native Gemma 4 vision-language model (text + image)
import MLXLMCommon
import MLXHuggingFace   // #hubDownloader() / #huggingFaceTokenizerLoader() macros
import HuggingFace      // the macros expand to HuggingFace.HubClient …
import Tokenizers       // … and Tokenizers.AutoTokenizer

// MARK: - Selectable on-device models

/// The Gemma 4 edge models we expose in the model manager.
/// Repo ids match the validated `mlx-community` snapshots (note E2B's capitalised id).
enum GemmaLocalModel: String, CaseIterable, Identifiable, Codable {
    case e2b
    case e4b

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .e2b: return "Gemma 4 E2B"
        case .e4b: return "Gemma 4 E4B"
        }
    }

    /// HuggingFace repo id of the 4-bit MLX snapshot.
    var modelId: String {
        switch self {
        case .e2b: return "mlx-community/gemma-4-E2B-it-4bit"
        case .e4b: return "mlx-community/gemma-4-e4b-it-4bit"
        }
    }

    var detail: String {
        switch self {
        case .e2b: return "2B params • ~3.6 GB • fastest"
        case .e4b: return "4B params • ~5.2 GB • smarter"
        }
    }

    static func from(modelId: String) -> GemmaLocalModel {
        allCases.first { $0.modelId == modelId } ?? .e2b
    }
}

@MainActor
final class GemmaLocalService: ObservableObject {

    static let shared = GemmaLocalService()
    private init() {}

    // MARK: - Published state

    @Published var connectionState: AIConnectionState = .disconnected {
        didSet { onConnectionStateChanged?(connectionState) }
    }
    @Published var isProcessing: Bool = false
    @Published var isModelLoaded: Bool = false
    @Published var downloadProgress: Double = 0
    @Published var lastError: String?

    // MARK: - Callbacks (mirror OpenClawService)

    /// Full assistant reply, delivered once generation completes.
    var onAgentMessage: ((String) -> Void)?
    /// Optional incremental tokens for live transcript display.
    var onPartialResponse: ((String) -> Void)?
    var onProcessingChanged: ((Bool) -> Void)?
    var onConnectionStateChanged: ((AIConnectionState) -> Void)?
    var onDisconnected: (() -> Void)?

    // MARK: - MLX state

    private var modelContainer: ModelContainer?
    private var loadedModelId: String?
    private var cancelRequested = false

    // mlx-swift-lm 3.31.3 ships a native Gemma 4 VLM (text + vision) registered in
    // VLMModelFactory, so no custom model registration is needed.

    // MARK: - Download (model manager)

    /// Download a model snapshot to disk (idempotent — skipped if already cached).
    func download(_ model: GemmaLocalModel, onProgress: @escaping (Double) -> Void) async throws {
        downloadProgress = 0
        let configuration = ModelConfiguration(id: model.modelId)
        // loadContainer fetches the snapshot if missing; reuse it as the download path.
        _ = try await VLMModelFactory.shared.loadContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: configuration,
            progressHandler: { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress.fractionCompleted
                    onProgress(progress.fractionCompleted)
                }
            }
        )
        downloadProgress = 1
    }

    // MARK: - Connect / disconnect (load / unload)

    /// Load the selected model into memory. Throws if it hasn't been downloaded yet
    /// (we don't want a multi-GB download to kick off silently on a "connect").
    func connect(modelId: String) async throws {
        print("[GemmaLocal] connect(\(modelId)) — already loaded: \(loadedModelId == modelId && modelContainer != nil)")
        if loadedModelId == modelId, modelContainer != nil {
            setState(.connected); return
        }
        setState(.connecting)
        isProcessing = false

        Memory.cacheLimit = 20 * 1024 * 1024

        do {
            print("[GemmaLocal] loading container…")
            let configuration = ModelConfiguration(id: modelId)
            let container = try await VLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in self?.downloadProgress = progress.fractionCompleted }
                }
            )
            modelContainer = container
            loadedModelId = modelId
            isModelLoaded = true
            setState(.connected)
            print("[GemmaLocal] ✓ model loaded, connected")
        } catch {
            print("[GemmaLocal] ✗ load failed: \(error)")
            lastError = error.localizedDescription
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    func disconnect() async {
        modelContainer = nil
        loadedModelId = nil
        isModelLoaded = false
        isProcessing = false
        setState(.disconnected)
        onDisconnected?()
    }

    // MARK: - Generation

    /// Send a prompt and return the full reply via `onAgentMessage`. When `imageData` is provided
    /// (a glasses photo), it's passed to the Gemma 4 VLM so it can answer "what's this?" on-device.
    func sendMessage(_ text: String, imageData: Data? = nil) async throws {
        NSLog("[OV] GemmaLocal sendMessage: \"%@\" — loaded: %@, image: %d bytes", text, modelContainer != nil ? "yes" : "no", imageData?.count ?? 0)
        guard let container = modelContainer else {
            print("[GemmaLocal] ✗ model NOT loaded — throwing")
            throw GemmaLocalError.modelNotLoaded
        }
        setProcessing(true)
        cancelRequested = false
        defer { setProcessing(false) }

        var images: [UserInput.Image] = []
        if let data = imageData, var ciImage = CIImage(data: data) {
            // Downscale large frames before the vision encoder to keep peak memory down.
            let maxDim: CGFloat = 1024
            let longest = max(ciImage.extent.width, ciImage.extent.height)
            if longest > maxDim {
                let scale = maxDim / longest
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            images.append(.ciImage(ciImage))
        }

        var chat: [Chat.Message] = []
        let systemPrompt = SettingsManager.shared.settings.userPrompt
        if !systemPrompt.isEmpty {
            chat.append(.init(role: .system, content: systemPrompt))
        }
        chat.append(.init(role: .user, content: text, images: images))
        let userInput = UserInput(chat: chat)

        NSLog("[OV] GemmaLocal: starting generation…")
        let stream = try await container.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            // Cap output length — without this, generation can run for minutes on-device and
            // the UI sits on "thinking". 220 tokens ≈ a few short spoken sentences.
            let parameters = GenerateParameters(maxTokens: 220, temperature: 0.7)
            return try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: context)
        }

        var full = ""
        var tokenCount = 0
        for await item in stream {
            if cancelRequested { break }
            if case .chunk(let piece) = item {
                full += piece
                tokenCount += 1
                if tokenCount == 1 { NSLog("[OV] GemmaLocal: first token received") }
                let snapshot = full
                await MainActor.run { self.onPartialResponse?(snapshot) }
            }
        }
        NSLog("[OV] GemmaLocal: generation done — %d chunks, %d chars", tokenCount, full.count)
        let reply = full
        if !cancelRequested {
            await MainActor.run { self.onAgentMessage?(reply) }
        }
    }

    /// Barge-in: stop streaming the current reply as soon as possible.
    func interrupt() {
        cancelRequested = true
        setProcessing(false)
    }

    // MARK: - Helpers

    private func setState(_ state: AIConnectionState) {
        connectionState = state
    }

    private func setProcessing(_ value: Bool) {
        isProcessing = value
        onProcessingChanged?(value)
    }

    enum GemmaLocalError: LocalizedError {
        case modelNotLoaded
        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "The local Gemma model isn't loaded. Download it in Settings → AI Backend → Local (Gemma 4)."
            }
        }
    }
}
