// OpenVision - GemmaLocalService.swift
// On-device Gemma 4 backend (text tier) running via Apple MLX.
//
// Conforms to the same backend shape as OpenClawService / GeminiLiveService:
// `.shared` singleton, @MainActor, AIConnectionState, callbacks (not Combine for events),
// connect()/disconnect()/sendMessage(). "Connect" loads the model into memory; "disconnect"
// unloads it. Selection is a manual knob (Settings → AI Backend → Local (Gemma 4)).
//
// The Gemma 4 model architecture itself lives in Vendor/Gemma4Text.swift (MIT, from
// github.com/vdthatte/gemma4-ios). The load + generate flow below mirrors that project's
// MLXService, adapted to OpenVision's backend conventions.
//
// NOTE: Requires iOS 18+ and a physical device (MLX is unavailable on the Simulator).
// Phase 1 is TEXT-ONLY (LLMModelFactory). Vision (VLMModelFactory + image preprocessing)
// is Phase 2 — see docs/local-gemma-backend.md.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

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
    private var registeredGemma4 = false
    private var cancelRequested = false

    // MARK: - Registration

    /// Register the Gemma 4 model architecture into mlx-swift-lm's registry.
    /// mlx-swift-lm 3.31.3 ships Gemma 3 but not Gemma 4, so we register the vendored port.
    private func registerGemma4IfNeeded() async {
        guard !registeredGemma4 else { return }
        registeredGemma4 = true
        await LLMTypeRegistry.shared.registerModelType("gemma4") { data in
            let config = try JSONDecoder().decode(Gemma4TextConfiguration.self, from: data)
            return Gemma4TextModel(config)
        }
        await LLMTypeRegistry.shared.registerModelType("gemma4_text") { data in
            let config = try JSONDecoder().decode(Gemma4TextConfiguration.self, from: data)
            return Gemma4TextModel(config)
        }
    }

    // MARK: - Download (model manager)

    /// Download a model snapshot to disk (idempotent — skipped if already cached).
    func download(_ model: GemmaLocalModel, onProgress: @escaping (Double) -> Void) async throws {
        downloadProgress = 0
        await registerGemma4IfNeeded()
        let configuration = ModelConfiguration(id: model.modelId)
        // loadContainer fetches the snapshot if missing; reuse it as the download path.
        _ = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration
        ) { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress.fractionCompleted
                onProgress(progress.fractionCompleted)
            }
        }
        downloadProgress = 1
    }

    // MARK: - Connect / disconnect (load / unload)

    /// Load the selected model into memory. Throws if it hasn't been downloaded yet
    /// (we don't want a multi-GB download to kick off silently on a "connect").
    func connect(modelId: String) async throws {
        if loadedModelId == modelId, modelContainer != nil {
            setState(.connected); return
        }
        setState(.connecting)
        isProcessing = false

        Memory.cacheLimit = 20 * 1024 * 1024
        await registerGemma4IfNeeded()

        do {
            let configuration = ModelConfiguration(id: modelId)
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: configuration
            ) { [weak self] progress in
                Task { @MainActor in self?.downloadProgress = progress.fractionCompleted }
            }
            modelContainer = container
            loadedModelId = modelId
            isModelLoaded = true
            setState(.connected)
        } catch {
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

    /// Send a prompt and return the full reply via `onAgentMessage`. `imageData` is accepted
    /// for interface parity with the cloud backends but is ignored in Phase 1 (text-only).
    func sendMessage(_ text: String, imageData: Data? = nil) async throws {
        guard let container = modelContainer else {
            throw GemmaLocalError.modelNotLoaded
        }
        setProcessing(true)
        cancelRequested = false
        defer { setProcessing(false) }

        var chat: [Chat.Message] = []
        let systemPrompt = SettingsManager.shared.settings.userPrompt
        if !systemPrompt.isEmpty {
            chat.append(.init(role: .system, content: systemPrompt))
        }
        chat.append(.init(role: .user, content: text))
        let userInput = UserInput(chat: chat)

        let stream = try await container.perform { (context: ModelContext) in
            let lmInput = try await context.processor.prepare(input: userInput)
            let parameters = GenerateParameters(temperature: 0.7)
            return try MLXLMCommon.generate(input: lmInput, parameters: parameters, context: context)
        }

        var full = ""
        for await item in stream {
            if cancelRequested { break }
            if case .chunk(let piece) = item {
                full += piece
                let snapshot = full
                await MainActor.run { self.onPartialResponse?(snapshot) }
            }
        }
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
