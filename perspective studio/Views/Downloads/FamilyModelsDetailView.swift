import SwiftUI
import AppKit

struct FamilyModelsDetailView: View {
    let family: ModelFamily
    @Bindable var chatViewModel: ChatViewModel
    let onBack: () -> Void

    @State private var selectedErrorLog: String? = nil
    @State private var modelToDelete: ModelCatalogVariant? = nil

    private func isModelDownloaded(_ id: String) -> Bool {
        chatViewModel.installedModels.contains { $0.id == id }
    }

    private func isModelDownloading(_ id: String) -> Bool {
        if case .downloading = chatViewModel.modelState, chatViewModel.selectedModelID == id {
            return true
        }
        return false
    }

    private func downloadProgress(_ id: String) -> Double {
        if case .downloading(let p) = chatViewModel.modelState, chatViewModel.selectedModelID == id {
            return p
        }
        return 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Unified Clean Header (No double bar)
            HStack(spacing: 12) {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Models")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .liquidGlass(.capsule)
                }
                .buttonStyle(.plain)
                .help("Back to Model Families")

                ProviderLogoView(provider: family.provider, familyName: family.name, size: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(family.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                    Text("\(family.variants.count) available variants")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // List of Model Variants
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(family.variants) { variant in
                        variantCard(variant)
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "13171D") ?? .black)
        .alert("Download Error Log", isPresented: Binding(
            get: { selectedErrorLog != nil },
            set: { if !$0 { selectedErrorLog = nil } }
        )) {
            Button("Dismiss", role: .cancel) { selectedErrorLog = nil }
        } message: {
            if let log = selectedErrorLog {
                Text(log)
            }
        }
        .alert("Delete Model from Mac?", isPresented: Binding(
            get: { modelToDelete != nil },
            set: { if !$0 { modelToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let m = modelToDelete {
                    deleteVariantModel(m)
                    modelToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { modelToDelete = nil }
        } message: {
            if let m = modelToDelete {
                Text("This will permanently remove \(m.name) files from your Mac disk cache.")
            }
        }
    }

    // MARK: - Model Variant Card

    private func variantCard(_ variant: ModelCatalogVariant) -> some View {
        let isDownloaded = isModelDownloaded(variant.id)
        let isDownloading = isModelDownloading(variant.id)
        let progress = downloadProgress(variant.id)
        let errorLog = chatViewModel.downloadErrors[variant.id]

        return VStack(alignment: .leading, spacing: 10) {
            // Top Row: Real Provider Logo + Title & Actions
            HStack(alignment: .center, spacing: 10) {
                ProviderLogoView(provider: family.provider, familyName: family.name, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(variant.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text(variant.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()

                // Download or Action State
                if isDownloading {
                    ModernDownloadProgressBar(progress: progress) {
                        chatViewModel.stopGenerating()
                    }
                } else if isDownloaded {
                    HStack(spacing: 8) {
                        // Installed Badge
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Installed")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(.green)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.green.opacity(0.16))
                        .clipShape(.capsule)

                        // Load Button
                        Button {
                            chatViewModel.loadHFModel(variant.rawModel)
                        } label: {
                            Text(chatViewModel.selectedModelID == variant.id ? "Loaded" : "Load")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(chatViewModel.selectedModelID == variant.id ? Color.cyan : Color.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .liquidGlass(.capsule)
                        }
                        .buttonStyle(.plain)

                        // Delete Model Button
                        Button {
                            modelToDelete = variant
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(.red.opacity(0.85))
                                .frame(width: 26, height: 26)
                                .liquidGlass(.circle)
                        }
                        .buttonStyle(.plain)
                        .help("Delete model from Mac")
                    }
                } else {
                    HStack(spacing: 8) {
                        if let errorLog {
                            Button {
                                selectedErrorLog = errorLog
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                    Text("Error Log")
                                }
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange.opacity(0.18))
                                .clipShape(.capsule)
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            chatViewModel.downloadHFModel(variant.rawModel)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.down.circle")
                                Text("Download")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .liquidGlass(.capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Description
            Text(variant.description)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .lineSpacing(2)

            // Specs directly computed from API
            HStack(spacing: 8) {
                Text(variant.sizeFormatted)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))

                Text("•")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))

                Text(variant.ramFormatted)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }

            // Badges Row
            if !variant.badges.isEmpty {
                HStack(spacing: 8) {
                    ForEach(variant.badges) { badge in
                        HStack(spacing: 4) {
                            Image(systemName: badge.icon)
                                .font(.system(size: 9))
                            Text(badge.title)
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(badge.color.opacity(0.18))
                        .clipShape(.capsule)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .liquidGlass(.rect(cornerRadius: 14))
    }

    private func deleteVariantModel(_ variant: ModelCatalogVariant) {
        let fm = FileManager.default
        let hubDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        let dirName = "models--" + variant.id.replacingOccurrences(of: "/", with: "--")
        let targetURL = hubDir.appendingPathComponent(dirName)
        try? fm.removeItem(at: targetURL)
        chatViewModel.scanInstalledModels()
    }
}

// MARK: - Modern Download Progress Bar (Liquid Glass Animation)

struct ModernDownloadProgressBar: View {
    let progress: Double
    let onCancel: () -> Void
    @State private var shimmerOffset: CGFloat = -1.0

    var body: some View {
        HStack(spacing: 8) {
            // Animated Liquid Glass Bar
            ZStack(alignment: .leading) {
                // Background Track
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 80, height: 7)

                // Filled Progress
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan, Color.blue, Color.purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(6, 80 * progress), height: 7)
                    .overlay(
                        // Shimmer highlight
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.65), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 30)
                            .offset(x: shimmerOffset * 50)
                            .mask(
                                Capsule().frame(width: max(6, 80 * progress), height: 7)
                            )
                    )
            }
            .clipShape(.capsule)

            Text("\(Int(progress * 100))%")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 34, alignment: .trailing)

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .buttonStyle(.plain)
            .help("Cancel Download")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .liquidGlass(.capsule)
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                shimmerOffset = 1.0
            }
        }
    }
}
