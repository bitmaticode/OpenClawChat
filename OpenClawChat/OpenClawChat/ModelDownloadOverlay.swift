//
//  ModelDownloadOverlay.swift
//  OpenClawChat
//
//  Popup overlay shown while downloading / loading the WhisperKit model.
//

import SwiftUI

struct ModelDownloadOverlay: View {
    let isDownloading: Bool
    let progress: Double       // 0.0–1.0
    let statusMessage: String

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Icon
                if isDownloading {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeating)
                } else {
                    // Loading/compiling spinner
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }

                Text(isDownloading ? "Descargando modelo STT" : "Preparando modelo STT")
                    .font(.headline)
                    .foregroundStyle(.white)

                if isDownloading {
                    // Progress bar
                    VStack(spacing: 8) {
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(.white)

                        Text("\(Int(progress * 100))%")
                            .font(.title2.monospacedDigit().bold())
                            .foregroundStyle(.white)
                    }

                    Text("large-v3 turbo · ~630 MB")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }

                Text("Solo la primera vez")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(32)
            .frame(maxWidth: 300)
            .background(.ultraThinMaterial.opacity(0.85))
            .background(Color.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 20)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.3), value: isDownloading)
    }
}
