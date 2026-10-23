import SwiftUI
import AppKit

struct DownloadsView: View {
    @Bindable var chatViewModel: ChatViewModel
    var onClose: (() -> Void)? = nil
    @State private var downloadsManager = DownloadsManager.shared
    @State private var selectedTab: DownloadsViewTab = .browse
    @State private var selectedFamily: ModelFamily? = nil
    @State private var downloadedModels: [LocalDiskModel] = []
    @State private var isScanningLocal = false
    @State private var modelToDelete: LocalDiskModel?
    @State private var showDeleteConfirmation = false
    @State private var showDeleteAllConfirmation = false

    enum DownloadsViewTab: String, CaseIterable, Identifiable {
        case browse = "Featured Models"
        case local = "Downloaded on Mac"
        var id: String { rawValue }
    }

    private var hubCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
    }

    private var totalLocalSizeFormatted: String {
        let total = downloadedModels.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top Tab Picker (Only shown when not viewing a family detail to prevent double headers)
            if selectedFamily == nil {
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

                    Picker("View", selection: $selectedTab) {
                        ForEach(DownloadsViewTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Divider()
            }

            switch selectedTab {
            case .browse:
                ModelsOverviewView(chatViewModel: chatViewModel, selectedFamily: $selectedFamily)
            case .local:
                localDownloadsView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "13171D") ?? .black)
        .task {
            if downloadsManager.allModels.isEmpty {
                await downloadsManager.fetchModelsFromHF()
            }
            await scanLocalDownloads()
        }
        .alert("Delete Model?", isPresented: $showDeleteConfirmation, presenting: modelToDelete) { model in
            Button("Delete", role: .destructive) {
                deleteLocalModel(model)
            }
            Button("Cancel", role: .cancel) { }
        } message: { model in
            Text("This will remove \(model.displayName) (\(model.sizeFormatted)) from your Mac. You can re-download it anytime.")
        }
        .alert("Remove All Downloaded Models?", isPresented: $showDeleteAllConfirmation) {
            Button("Remove All", role: .destructive) {
                deleteAllLocalModels()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove all \(downloadedModels.count) downloaded models (\(totalLocalSizeFormatted)) from your disk.")
        }
    }

    // MARK: - Browse View (Grouped by Provider)

    private var browseView: some View {
        VStack(spacing: 0) {
            // Search and Capability Filter Bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search models by name or provider...", text: $downloadsManager.searchQuery)
                    .textFieldStyle(.plain)

                if !downloadsManager.searchQuery.isEmpty {
                    Button {
                        downloadsManager.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    Task { await downloadsManager.fetchModelsFromHF(forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh HuggingFace API")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .liquidGlass(.rect(cornerRadius: 12))
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            // Capability Pills (Tools, Vision, Thinking, Code, Chat)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    FilterChip(
                        title: "All Capabilities",
                        isSelected: downloadsManager.selectedCapabilityFilter == nil
                    ) {
                        downloadsManager.selectedCapabilityFilter = nil
                    }

                    ForEach(ModelCapability.allCases) { cap in
                        FilterChip(
                            title: cap.rawValue,
                            icon: cap.symbol,
                            color: cap.color,
                            isSelected: downloadsManager.selectedCapabilityFilter == cap
                        ) {
                            downloadsManager.selectedCapabilityFilter = cap
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)

            Divider()

            if downloadsManager.isLoading {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView("Fetching models from HuggingFace...")
                    Text("Powered by mlx-community")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = downloadsManager.errorMessage {
                ContentUnavailableView {
                    Label("Could Not Load Models", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        Task { await downloadsManager.fetchModelsFromHF(forceRefresh: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if downloadsManager.groupedByProvider.isEmpty {
                ContentUnavailableView("No Matching Models", systemImage: "magnifyingglass")
            } else {
                List {
                    ForEach(downloadsManager.groupedByProvider, id: \.provider) { group in
                        Section {
                            ForEach(group.models) { model in
                                ModelRowView(
                                    model: model,
                                    chatViewModel: chatViewModel,
                                    onDownload: {
                                        chatViewModel.downloadHFModel(model.rawModel)
                                    },
                                    onLoad: {
                                        chatViewModel.loadHFModel(model.rawModel)
                                    }
                                )
                            }
                        } header: {
                            HStack(spacing: 8) {
                                Image(systemName: group.provider.icon)
                                    .foregroundStyle(group.provider.brandColor)
                                Text(group.provider.rawValue)
                                    .font(.headline)
                                    .bold()

                                Spacer()

                                Text("\(group.models.count) models")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Local Downloads View

    private var localDownloadsView: some View {
        VStack(spacing: 0) {
            // Storage Summary Bar
            HStack {
                Label("\(downloadedModels.count) models downloaded", systemImage: "internaldrive")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("Total Disk Space: \(totalLocalSizeFormatted)")
                    .font(.subheadline)
                    .bold()

                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await scanLocalDownloads() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)

                if downloadedModels.count > 1 {
                    Button("Remove All", role: .destructive) {
                        showDeleteAllConfirmation = true
                    }
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                    .font(.subheadline)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(.controlBackgroundColor).opacity(0.6))

            Divider()

            if isScanningLocal {
                ProgressView("Scanning downloaded files...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if downloadedModels.isEmpty {
                ContentUnavailableView {
                    Label("No Models Downloaded", systemImage: "arrow.down.circle")
                } description: {
                    Text("Downloaded models will appear here so you can chat offline or free up disk space.")
                }
            } else {
                List {
                    ForEach(downloadedModels) { model in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(model.displayName)
                                        .font(.headline)

                                    if chatViewModel.selectedModelID == model.id {
                                        Text("Active in Chat")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.green.opacity(0.2))
                                            .foregroundStyle(.green)
                                            .clipShape(.capsule)
                                    }

                                    if !model.isComplete {
                                        Text("Incomplete")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.orange.opacity(0.2))
                                            .foregroundStyle(.orange)
                                            .clipShape(.capsule)
                                    }
                                }

                                Text("\(model.author) • \(model.sizeFormatted)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if !model.isComplete {
                                    Text(model.issues.first ?? "Download did not finish")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                    Button("Resume / Repair Download") {
                                        let hfModel = HFModel(
                                            id: model.id, name: model.id, downloads: 0, likes: 0,
                                            tags: [], pipelineTag: nil, createdAt: nil
                                        )
                                        chatViewModel.downloadHFModel(hfModel)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }

                            Spacer()

                            Button {
                                loadLocalModel(model)
                            } label: {
                                Label("Load", systemImage: "play.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button {
                                modelToDelete = model
                                showDeleteConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Delete from Mac")
                        }
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Helpers

    private func scanLocalDownloads() async {
        isScanningLocal = true
        let hubDir = hubCacheDirectory
        let list = await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(atPath: hubDir.path()) else {
                return [LocalDiskModel]()
            }
            var result: [LocalDiskModel] = []
            for entry in entries {
                guard entry.hasPrefix("models--") else { continue }
                let parts = entry.dropFirst("models--".count).split(separator: "--", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let author = String(parts[0])
                let modelName = String(parts[1])
                let modelId = "\(author)/\(modelName)"
                let modelDir = hubDir.appendingPathComponent(entry)
                let blobsDir = modelDir.appendingPathComponent("blobs")
                let size = Self.calculateDirSize(at: blobsDir, fm: fm)
                let validation = ModelArtifactValidator.validate(modelID: modelId)

                result.append(LocalDiskModel(
                    id: modelId,
                    displayName: modelName,
                    author: author,
                    sizeBytes: size,
                    url: modelDir,
                    isComplete: validation.isComplete,
                    issues: validation.issues
                ))
            }
            return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }.value

        downloadedModels = list
        isScanningLocal = false
    }

    nonisolated static func calculateDirSize(at url: URL, fm: FileManager) -> Int64 {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    private func deleteLocalModel(_ model: LocalDiskModel) {
        try? FileManager.default.removeItem(at: model.url)
        downloadedModels.removeAll { $0.id == model.id }
        chatViewModel.scanInstalledModels()
    }

    private func deleteAllLocalModels() {
        for model in downloadedModels {
            try? FileManager.default.removeItem(at: model.url)
        }
        downloadedModels.removeAll()
        chatViewModel.scanInstalledModels()
    }

    private func loadLocalModel(_ model: LocalDiskModel) {
        let isVisual = ChatViewModel.looksLikeVisualModel(model.displayName)
        let hfModel = HFModel(
            id: model.id,
            name: model.id,
            downloads: 0,
            likes: 0,
            tags: isVisual ? ["image-text-to-text"] : [],
            pipelineTag: isVisual ? "image-text-to-text" : nil,
            createdAt: nil
        )
        chatViewModel.loadHFModel(hfModel)
    }
}

// MARK: - Local Disk Model

struct LocalDiskModel: Identifiable {
    let id: String
    let displayName: String
    let author: String
    let sizeBytes: Int64
    let url: URL
    /// Populated by scans that run `ModelArtifactValidator`; defaults keep
    /// other call sites source-compatible.
    var isComplete: Bool = true
    var issues: [String] = []

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

// MARK: - Model Row View

private struct ModelRowView: View {
    let model: ManagedHFModel
    @Bindable var chatViewModel: ChatViewModel
    let onDownload: () -> Void
    let onLoad: () -> Void

    private var isCurrentModelDownloading: Bool {
        if case .downloading = chatViewModel.modelState, chatViewModel.selectedModelID == model.id {
            return true
        }
        return false
    }

    private var downloadProgress: Double {
        if case .downloading(let p) = chatViewModel.modelState, chatViewModel.selectedModelID == model.id {
            return p
        }
        return 0
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Model Info
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.displayName)
                        .font(.system(size: 14, weight: .semibold))

                    if let q = model.quantization {
                        Text(q)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(.capsule)
                    }
                }

                // Capabilities & Size Tags
                HStack(spacing: 6) {
                    // Size Badge
                    Text(model.sizeFormatted)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Text(model.ramFormatted)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    // Capabilities Badges
                    ForEach(model.capabilities) { cap in
                        HStack(spacing: 3) {
                            Image(systemName: cap.symbol)
                                .font(.system(size: 9))
                            Text(cap.rawValue)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(cap.color.opacity(0.12))
                        .foregroundStyle(cap.color)
                        .clipShape(.capsule)
                    }
                }
            }

            Spacer()

            // Download or Action State
            if isCurrentModelDownloading {
                VStack(spacing: 4) {
                    ProgressView(value: downloadProgress)
                        .frame(width: 90)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption2)
                        .monospacedDigit()
                }
            } else if model.isDownloaded {
                HStack(spacing: 8) {
                    Text("Downloaded")
                        .font(.caption)
                        .foregroundStyle(.green)

                    Button("Load") {
                        onLoad()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Button {
                    onDownload()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let title: String
    var icon: String? = nil
    var color: Color = .blue
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2)
                }
                if isSelected {
                    Text(title)
                        .font(.caption)
                        .bold()
                } else {
                    Text(title)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .liquidGlass(.capsule, isClear: !isSelected)
        }
        .buttonStyle(.plain)
    }
}
