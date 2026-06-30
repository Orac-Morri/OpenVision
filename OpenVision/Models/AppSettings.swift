// OpenVision - AppSettings.swift
// Settings data model with Codable support for JSON persistence

import Foundation

/// The type of AI backend to use
enum AIBackendType: String, Codable, CaseIterable {
    case openClaw = "openclaw"
    case geminiLive = "gemini_live"
    case localGemma = "local_gemma"

    var displayName: String {
        switch self {
        case .openClaw: return "OpenClaw"
        case .geminiLive: return "Gemini Live"
        case .localGemma: return "Local (Gemma 4)"
        }
    }

    var description: String {
        switch self {
        case .openClaw:
            return "Wake word activation, 56+ tools, task execution"
        case .geminiLive:
            return "Real-time voice + vision, continuous conversation"
        case .localGemma:
            return "On-device Gemma 4 — private, offline, no API cost"
        }
    }

    var icon: String {
        switch self {
        case .openClaw: return "terminal"
        case .geminiLive: return "waveform"
        case .localGemma: return "cpu"
        }
    }
}

/// App settings persisted to Documents/settings.json
struct AppSettings: Codable, Equatable {
    // MARK: - AI Backend Selection

    /// Which AI backend to use
    var aiBackend: AIBackendType = .openClaw

    // MARK: - OpenClaw Configuration

    /// OpenClaw gateway WebSocket URL (e.g., "wss://openclaw.example.com")
    var openClawGatewayURL: String = ""

    /// OpenClaw authentication token
    var openClawAuthToken: String = ""

    // MARK: - Gemini Live Configuration

    /// Google Gemini API key
    var geminiAPIKey: String = ""

    // MARK: - Local Gemma Configuration

    /// HuggingFace repo id of the on-device Gemma 4 model to load.
    /// Matches `GemmaLocalModel.e2b.modelId` (note the validated capital-E2B casing).
    var localGemmaModelId: String = "mlx-community/gemma-4-E2B-it-4bit"

    /// Whether the selected Gemma model has finished downloading and is ready to load.
    /// Set by the model-manager / GemmaLocalService once the snapshot is on disk.
    var localGemmaModelReady: Bool = false

    // MARK: - Voice Settings

    /// Wake word phrase (default: "Ok Vision")
    var wakeWord: String = "Ok Vision"

    /// Whether wake word detection is enabled (OpenClaw mode only)
    var wakeWordEnabled: Bool = true

    /// Play activation chime on wake word detection
    var playActivationSound: Bool = true

    /// Conversation timeout in seconds (auto-end after silence)
    var conversationTimeout: TimeInterval = 30

    /// Selected TTS voice identifier (nil = system default)
    var selectedVoiceIdentifier: String? = nil

    // MARK: - AI Customization

    /// Custom instructions appended to AI system prompt
    var userPrompt: String = ""

    /// Key-value memories the AI can read and manage
    var memories: [String: String] = [:]

    // MARK: - Advanced Settings

    /// Auto-reconnect on connection drop
    var autoReconnect: Bool = true

    /// Show live transcripts in UI
    var showTranscripts: Bool = true

    /// Video frame rate for Gemini Live (frames per second)
    var geminiVideoFPS: Int = 1

    // MARK: - Computed Properties

    /// Whether OpenClaw is configured (has URL and token)
    var isOpenClawConfigured: Bool {
        !openClawGatewayURL.isEmpty && !openClawAuthToken.isEmpty
    }

    /// Whether Gemini is configured (has API key)
    var isGeminiConfigured: Bool {
        !geminiAPIKey.isEmpty
    }

    /// Whether the local Gemma backend is ready (model downloaded)
    var isLocalGemmaConfigured: Bool {
        localGemmaModelReady
    }

    /// Whether the currently selected backend is configured
    var isCurrentBackendConfigured: Bool {
        switch aiBackend {
        case .openClaw: return isOpenClawConfigured
        case .geminiLive: return isGeminiConfigured
        case .localGemma: return isLocalGemmaConfigured
        }
    }
}
