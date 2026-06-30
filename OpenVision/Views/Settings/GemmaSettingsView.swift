// OpenVision - GemmaSettingsView.swift
// Download & manage the on-device Gemma 4 model for the Local backend.

import SwiftUI

struct GemmaSettingsView: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var gemma = GemmaLocalService.shared

    @State private var selectedModel: GemmaLocalModel = .e2b
    @State private var isDownloading = false
    @State private var downloadError: String?

    var body: some View {
        Form {
            Section {
                ForEach(GemmaLocalModel.allCases) { model in
                    Button {
                        selectedModel = model
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                    .foregroundStyle(.primary)
                                Text(model.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedModel == model {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Runs entirely on-device via Apple MLX. Requires iOS 18+ and a physical device — no API key, no cloud, works offline.")
            }

            Section {
                if isDownloading {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: gemma.downloadProgress)
                        Text("Downloading… \(Int(gemma.downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        download()
                    } label: {
                        Label(
                            settingsManager.settings.isLocalGemmaConfigured ? "Re-download Model" : "Download Model",
                            systemImage: "arrow.down.circle"
                        )
                    }
                }

                if let downloadError {
                    Text(downloadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Download")
            } footer: {
                if settingsManager.settings.isLocalGemmaConfigured {
                    Label("Model ready — select “Local (Gemma 4)” as your backend.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("The first download is several GB — keep the app open and use Wi-Fi.")
                }
            }
        }
        .navigationTitle("Local Gemma")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedModel = GemmaLocalModel.from(modelId: settingsManager.settings.localGemmaModelId)
        }
    }

    private func download() {
        downloadError = nil
        isDownloading = true
        Task {
            do {
                try await gemma.download(selectedModel) { _ in }
                settingsManager.settings.localGemmaModelId = selectedModel.modelId
                settingsManager.settings.localGemmaModelReady = true
            } catch {
                downloadError = error.localizedDescription
            }
            isDownloading = false
        }
    }
}

#Preview {
    NavigationStack { GemmaSettingsView() }
}
