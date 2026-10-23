import SwiftUI
import AppKit

struct FamilyModelsDetailView: View {
    let family: ModelFamily
    @Bindable var chatViewModel: ChatViewModel
    let onBack: () -> Void

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
            // Top Navigation Bar (Exact Screenshot 3 Parity)
            HStack(spacing: 14) {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .liquidGlass(.circle)
                }
                .buttonStyle(.plain)
                .help("Back to Models")

                Text(family.name)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // List of Model Variants (Exact Screenshot 3 Parity)
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
    }

    // MARK: - Model Variant Card

    private func variantCard(_ variant: ModelCatalogVariant) -> some View {
        let isDownloaded = isModelDownloaded(variant.id)
        let isDownloading = isModelDownloading(variant.id)
        let progress = downloadProgress(variant.id)

        return VStack(alignment: .leading, spacing: 10) {
            // Top Row: Icon + Title & Download Button
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: family.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)

                Text(variant.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                // Download Button (Screenshot 3 Action)
                if isDownloading {
                    HStack(spacing: 8) {
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 60)
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .liquidGlass(.capsule)
                } else if isDownloaded {
                    Button {
                        chatViewModel.loadHFModel(variant.rawModel)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                            Text("Loaded")
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .liquidGlass(.capsule)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        chatViewModel.downloadHFModel(variant.rawModel)
                    } label: {
                        Text("Download")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 6)
                            .liquidGlass(.capsule)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Description
            Text(variant.description)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .lineSpacing(2)

            // Specs
            Text(variant.sizeFormatted)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))

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
}
