import AVFAudio
import SwiftUI
import AppKit

enum SettingsSidebarTab: String, CaseIterable, Identifiable {
    case general = "General"
    case models = "Models"
    case personalization = "Personalization"
    case skills = "Manage Skills"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .models: "cube"
        case .personalization: "person"
        case .skills: "sparkles"
        }
    }
}

enum ResponseStylePersonality: String, CaseIterable, Identifiable {
    case helpful = "Helpful"
    case formal = "Formal"
    case concise = "Concise"
    case creative = "Creative"
    case humorous = "Humorous"

    var id: String { rawValue }
}

enum ResponseTone: String, CaseIterable, Identifiable {
    case natural = "Natural"
    case academic = "Academic"
    case empathetic = "Empathetic"
    case playful = "Playful"

    var id: String { rawValue }
}

enum ResponseLengthPreference: String, CaseIterable, Identifiable {
    case concise = "Concise"
    case balanced = "Balanced"
    case thorough = "Thorough"

    var id: String { rawValue }
}

struct SettingsView: View {
    var onClose: (() -> Void)? = nil

    @State private var selectedTab: SettingsSidebarTab = .general

    // General Settings
    @AppStorage("notifyOnFinish") private var notifyOnFinish: Bool = true
    @AppStorage("experienceLevel") private var experienceLevel: String = ExperienceLevel.beginner.rawValue
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = true
    @State private var showDeleteHistoryAlert: Bool = false

    // Gradient Customization
    @AppStorage("chatGradientTheme") private var gradientPresetRaw: String = GradientPreset.aurora.rawValue
    @AppStorage("chatGradientTopHex") private var customTopHex: String = GradientTheme.defaultTopHex
    @AppStorage("chatGradientBottomHex") private var customBottomHex: String = GradientTheme.defaultBottomHex

    // Personalization
    @AppStorage("customSystemPrompt") private var customSystemPrompt: String = ""
    @AppStorage("importedPersonaSummary") private var importedPersonaSummary: String = ""
    @AppStorage("personalityStyle") private var personalityStyle: String = ResponseStylePersonality.helpful.rawValue
    @AppStorage("responseTone") private var responseTone: String = ResponseTone.natural.rawValue
    @AppStorage("responseLength") private var responseLength: String = ResponseLengthPreference.balanced.rawValue
    @AppStorage("enableThinkingMode") private var enableThinkingMode: Bool = true
    @AppStorage("thinkingBudget") private var thinkingBudget: String = "medium"
    @AppStorage("enableRichMarkdown") private var enableRichMarkdown: Bool = true
    @AppStorage("enableCrossSessionMemory") private var enableCrossSessionMemory: Bool = true

    // Models & Storage
    @AppStorage("defaultContextLength") private var defaultContextLength: Int = 4096
    @State private var downloadedModels: [LocalDiskModel] = []
    @State private var isScanningLocal: Bool = false
    @State private var showingImportSheet: Bool = false

    @State private var customTopColor: Color = Color(hex: GradientTheme.defaultTopHex) ?? .green
    @State private var customBottomColor: Color = Color(hex: GradientTheme.defaultBottomHex) ?? .black

    private var activeColors: [Color] {
        GradientTheme.activeColors(
            presetRaw: gradientPresetRaw,
            customTopHex: customTopHex,
            customBottomHex: customBottomHex
        )
    }

    private var totalLocalSizeFormatted: String {
        let total = downloadedModels.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar (Exact Screenshot 4 Parity)
            VStack(alignment: .leading, spacing: 6) {
                // Top header with Back to Chat and Traffic Lights spacing
                HStack(spacing: 8) {
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
                        .padding(.trailing, 8)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // Sidebar Tabs List
                ForEach(SettingsSidebarTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 15))
                                .frame(width: 22)
                            Text(tab.rawValue)
                                .font(.system(size: 14, weight: selectedTab == tab ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundStyle(selectedTab == tab ? .white : .primary)
                        .background(
                            selectedTab == tab ? Color.accentColor : Color.clear,
                            in: .rect(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .frame(width: 210)
            .padding(.horizontal, 8)
            .background(Color(hex: "13171D") ?? .black)

            Divider()

            // Right Detail Area (Exact Screenshot 4 Parity)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch selectedTab {
                    case .general:
                        generalDetailView
                    case .models:
                        modelsDetailView
                    case .personalization:
                        personalizationDetailView
                    case .skills:
                        ManageSkillsView()
                    }
                }
                .padding(28)
                .frame(maxWidth: 680, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(hex: "1A202C") ?? .black)
        }
        .frame(minWidth: 700, minHeight: 520)
        .onAppear {
            if let c1 = Color(hex: customTopHex) { customTopColor = c1 }
            if let c2 = Color(hex: customBottomHex) { customBottomColor = c2 }
            Task { await scanLocalDownloads() }
        }
        .sheet(isPresented: $showingImportSheet) {
            ImportFromProvidersView()
        }
        .alert("Clear All Conversation History?", isPresented: $showDeleteHistoryAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                // History clear action
            }
        } message: {
            Text("This will permanently delete all messages and conversations on this Mac.")
        }
    }

    // MARK: - Detail 1: General (Exact Screenshot 4 Parity)

    private var generalDetailView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("General")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            // App Card
            VStack(alignment: .leading, spacing: 14) {
                Text("App")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)

                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "bell")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text("Notify when model finishes responding")
                            .font(.system(size: 13))
                        Spacer()
                        Toggle("", isOn: $notifyOnFinish)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    Divider()

                    HStack {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text("Delete conversation history")
                            .font(.system(size: 13))
                        Spacer()
                        Button("Delete...") {
                            showDeleteHistoryAlert = true
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .liquidGlass(.rect(cornerRadius: 12))
            }

            // About Card
            VStack(alignment: .leading, spacing: 14) {
                Text("About")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)

                VStack(spacing: 0) {
                    settingsNavigationRow(icon: "doc.text", title: "Terms & Conditions")
                    Divider()
                    settingsNavigationRow(icon: "lock", title: "Privacy Policy")
                    Divider()
                    settingsNavigationRow(icon: "doc.plaintext", title: "Licenses")
                    Divider()
                    HStack {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text("Version 2.0 (Build 2026)")
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .liquidGlass(.rect(cornerRadius: 12))
            }

            // More Card
            VStack(alignment: .leading, spacing: 14) {
                Text("More")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)

                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text("Share the app (support us 🚀)")
                            .font(.system(size: 13))
                        Spacer()
                        Button("Share...") {
                            let picker = NSSharingServicePicker(items: ["Locally: Private on-device AI for macOS"])
                            if let window = NSApp.keyWindow {
                                picker.show(relativeTo: .zero, of: window.contentView ?? NSView(), preferredEdge: .minY)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    Divider()

                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text("Follow us on X")
                            .font(.system(size: 13))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .liquidGlass(.rect(cornerRadius: 12))
            }

            // Footer
            HStack {
                Spacer()
                Text("Made with 💜 for on-device intelligence")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 8)
        }
    }

    private func settingsNavigationRow(icon: String, title: String) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Detail 2: Models

    private var modelsDetailView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Models & Storage")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            // Storage Summary Card
            VStack(alignment: .leading, spacing: 10) {
                Text("Storage Usage")
                    .font(.headline)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total Downloaded Space")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(totalLocalSizeFormatted)
                            .font(.title3)
                            .bold()
                    }
                    Spacer()
                    Text("\(downloadedModels.count) models on disk")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HuggingFace Hub Cache")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("~/.cache/huggingface/hub")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Refresh") {
                        Task { await scanLocalDownloads() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(16)
            .liquidGlass(.rect(cornerRadius: 14))

            // Downloaded Models List
            if !downloadedModels.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Downloaded Files")
                        .font(.headline)

                    VStack(spacing: 0) {
                        ForEach(downloadedModels) { model in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(model.sizeFormatted)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Delete", role: .destructive) {
                                    try? FileManager.default.removeItem(at: model.url)
                                    downloadedModels.removeAll { $0.id == model.id }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                                .font(.caption)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)

                            if model.id != downloadedModels.last?.id {
                                Divider()
                            }
                        }
                    }
                    .liquidGlass(.rect(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: - Detail 3: Personalization

    private var personalizationDetailView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Personalization")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            // Live Gradient Preview Card
            VStack(alignment: .leading, spacing: 12) {
                Text("Chat Background Gradient")
                    .font(.headline)

                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: activeColors, startPoint: .top, endPoint: .bottom))
                    .frame(height: 80)
                    .overlay(
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Meet the new Apple Foundation")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("Active Gradient Theme")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            Spacer()
                            Image(systemName: "apple.intelligence")
                                .font(.system(size: 24))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .padding(.horizontal, 16)
                    )

                Picker("Preset", selection: $gradientPresetRaw) {
                    ForEach(GradientPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 240)

                if gradientPresetRaw == GradientPreset.custom.rawValue {
                    HStack(spacing: 20) {
                        ColorPicker("Top Color", selection: $customTopColor)
                            .onChange(of: customTopColor) { _, newColor in
                                customTopHex = newColor.toHex()
                            }
                        ColorPicker("Bottom Color", selection: $customBottomColor)
                            .onChange(of: customBottomColor) { _, newColor in
                                customBottomHex = newColor.toHex()
                            }
                    }
                }
            }
            .padding(16)
            .liquidGlass(.rect(cornerRadius: 14))

            // System Prompt Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Custom System Prompt")
                        .font(.headline)
                    Spacer()
                    if !customSystemPrompt.isEmpty {
                        Button("Clear") { customSystemPrompt = "" }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                TextEditor(text: $customSystemPrompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 80)
                    .padding(8)
                    .background(Color(.controlBackgroundColor))
                    .clipShape(.rect(cornerRadius: 8))

                // Quick Presets
                HStack(spacing: 8) {
                    promptPresetButton(title: "Helpful & Direct", prompt: "You are a concise, highly capable AI assistant.")
                    promptPresetButton(title: "Senior Engineer", prompt: "You are a senior software architect providing production-grade code.")
                    promptPresetButton(title: "Deep Thinker", prompt: "You are an analytical researcher. Think step-by-step and reason rigorously.")
                }
            }
            .padding(16)
            .liquidGlass(.rect(cornerRadius: 14))

            // Personality & Tone Card
            VStack(alignment: .leading, spacing: 14) {
                Text("Persona & Tone")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        Text("Style")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker("Style", selection: $personalityStyle) {
                            ForEach(ResponseStylePersonality.allCases) { style in
                                Text(style.rawValue).tag(style.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    GridRow {
                        Text("Tone")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker("Tone", selection: $responseTone) {
                            ForEach(ResponseTone.allCases) { tone in
                                Text(tone.rawValue).tag(tone.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    GridRow {
                        Text("Length")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker("Length", selection: $responseLength) {
                            ForEach(ResponseLengthPreference.allCases) { length in
                                Text(length.rawValue).tag(length.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }

                Divider()

                Toggle("Rich Markdown Output", isOn: $enableRichMarkdown)
                Toggle("Remember across conversations", isOn: $enableCrossSessionMemory)
            }
            .padding(16)
            .liquidGlass(.rect(cornerRadius: 14))

            // Thinking Mode Card
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Thinking Mode (Chain-of-Thought)", isOn: $enableThinkingMode)
                    .font(.headline)

                Picker("Reasoning Effort", selection: $thinkingBudget) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .pickerStyle(.segmented)
            }
            .padding(16)
            .liquidGlass(.rect(cornerRadius: 14))

            // Import Persona Launcher
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Persona From Other AIs")
                        .font(.headline)
                    Text("Extract what ChatGPT, Claude, or Gemini knows about you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Importer") {
                    showingImportSheet = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(16)
            .liquidGlass(.rect(cornerRadius: 14))
        }
    }

    private func promptPresetButton(title: String, prompt: String) -> some View {
        Button {
            customSystemPrompt = prompt
        } label: {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.15))
                .clipShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    private func scanLocalDownloads() async {
        isScanningLocal = true
        let fm = FileManager.default
        let hubDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        guard fm.fileExists(atPath: hubDir.path) else {
            downloadedModels = []
            isScanningLocal = false
            return
        }

        let list = await Task.detached(priority: .userInitiated) { () -> [LocalDiskModel] in
            guard let contents = try? fm.contentsOfDirectory(at: hubDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
                return []
            }
            var result: [LocalDiskModel] = []
            for modelDir in contents where modelDir.lastPathComponent.hasPrefix("models--") {
                let rawName = modelDir.lastPathComponent.replacingOccurrences(of: "models--", with: "")
                let parts = rawName.split(separator: "--")
                let author = parts.first.map(String.init) ?? "Local"
                let modelName = parts.dropFirst().joined(separator: "-")
                let modelId = "\(author)/\(modelName)"
                let size = DownloadsView.calculateDirSize(at: modelDir, fm: fm)
                result.append(LocalDiskModel(id: modelId, displayName: modelName, author: author, sizeBytes: size, url: modelDir))
            }
            return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }.value

        downloadedModels = list
        isScanningLocal = false
    }
}
