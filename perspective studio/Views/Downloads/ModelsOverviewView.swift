import SwiftUI
import AppKit

struct ModelsOverviewView: View {
    @Bindable var chatViewModel: ChatViewModel
    var onClose: (() -> Void)? = nil
    @Binding var selectedFamily: ModelFamily?
    @State private var searchQuery: String = ""

    init(chatViewModel: ChatViewModel, onClose: (() -> Void)? = nil, selectedFamily: Binding<ModelFamily?>) {
        self.chatViewModel = chatViewModel
        self.onClose = onClose
        self._selectedFamily = selectedFamily
    }

    private var families: [ModelFamily] {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ModelCatalogData.featuredFamilies
        }
        return ModelCatalogData.featuredFamilies.filter { family in
            family.name.localizedStandardContains(searchQuery) ||
            family.description.localizedStandardContains(searchQuery) ||
            family.variants.contains(where: { $0.name.localizedStandardContains(searchQuery) })
        }
    }

    private func downloadedCount(for family: ModelFamily) -> Int {
        family.variants.filter { variant in
            chatViewModel.installedModels.contains { $0.id == variant.id }
        }.count
    }

    var body: some View {
        Group {
            if let selectedFamily {
                FamilyModelsDetailView(
                    family: selectedFamily,
                    chatViewModel: chatViewModel,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            self.selectedFamily = nil
                        }
                    }
                )
            } else {
                overviewContent
                    .task {
                        await ModelCatalog.shared.fetchCatalogFromAPI()
                    }
            }
        }
    }

    // MARK: - Overview Content (Exact Screenshot 2 Parity)

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Navigation Bar
            HStack(spacing: 12) {
                if let onClose {
                    Button {
                        onClose()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Chat")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Text("Models")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                // Search Capsule
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("Search models...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 140)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .liquidGlass(.capsule, isClear: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Section Title
                    Text("Featured")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 4)

                    // Cards List
                    LazyVStack(spacing: 12) {
                        ForEach(families) { family in
                            familyCard(family)
                        }
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "13171D") ?? .black)
    }

    // MARK: - Family Card View (Exact Screenshot 2 Parity)

    private func familyCard(_ family: ModelFamily) -> some View {
        let downloaded = downloadedCount(for: family)

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedFamily = family
            }
        } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    // Header: Icon + Title & Downloaded Checkmark
                    HStack(spacing: 8) {
                        ProviderLogoView(provider: family.provider, familyName: family.name, size: 24)

                        Text(family.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)

                        if downloaded > 0 {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.green)
                        }
                    }

                    // Description
                    Text(family.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .lineSpacing(2)

                    // Model Count
                    Text(downloaded > 0 ? "\(family.modelCount) models (\(downloaded) downloaded)" : "\(family.modelCount) models")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))

                    // Badges Row
                    HStack(spacing: 8) {
                        ForEach(family.badges) { badge in
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

                Spacer()

                // Trailing Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(16)
            .liquidGlass(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
