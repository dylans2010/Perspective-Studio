import SwiftUI
import AppKit

/// Prompt library + generation profiles (feature F).
struct PromptLibraryView: View {
    @Bindable var chatViewModel: ChatViewModel
    @Environment(\.modelContext) private var modelContext
    @State private var store = PromptLibraryStore.shared

    @State private var newTitle = ""
    @State private var newBody = ""
    @State private var newCategory = "General"

    @State private var importText = ""
    @State private var showImport = false
    @State private var importError: String?
    @State private var statusText: String?

    @State private var profileName = ""
    @State private var profileModelID: String?
    @State private var profileSystemPrompt = ""
    @State private var profileTemperature = 0.7
    @State private var profileTopP = 1.0
    @State private var profileTopK = 0
    @State private var profileRepetitionPenalty = 1.0
    @State private var profileMaxTokens = 1024
    @State private var profileContextLength = 4096

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                promptsSection
                Divider()
                profilesSection
                if let statusText {
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    // MARK: - Prompts

    private var promptsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Prompt Library").font(.headline)
                Spacer()
                Button("Export All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.exportPromptsJSON(), forType: .string)
                    statusText = "Library copied to the clipboard as JSON."
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Import…") { showImport = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            TextField("Search prompts", text: $store.searchQuery)
                .textFieldStyle(.roundedBorder)

            ForEach(store.filteredPrompts) { prompt in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(prompt.title).bold()
                        Text(prompt.category)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary)
                            .clipShape(.capsule)
                        Spacer()
                        Button("Use in Chat") {
                            chatViewModel.messageText = prompt.body
                            statusText = "“\(prompt.title)” placed in the chat composer — switch to Chat to send it."
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Delete", role: .destructive) { store.deletePrompt(prompt) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Text(prompt.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(10)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 10))
            }

            GroupBox("Add a Prompt") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Title", text: $newTitle)
                    TextField("Category", text: $newCategory)
                    TextEditor(text: $newBody)
                        .frame(minHeight: 70)
                    Button("Save Prompt") {
                        store.addPrompt(title: newTitle, body: newBody, category: newCategory)
                        newTitle = ""
                        newBody = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty || newBody.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .sheet(isPresented: $showImport) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Import Prompts (JSON)").font(.headline)
                TextEditor(text: $importText)
                    .frame(minWidth: 420, minHeight: 180)
                if let importError {
                    Text(importError).foregroundStyle(.red).font(.caption)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { showImport = false }
                    Button("Import") {
                        do {
                            let count = try store.importPromptsJSON(importText)
                            statusText = "Imported \(count) prompt(s)."
                            importError = nil
                            showImport = false
                        } catch {
                            importError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    // MARK: - Profiles

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Generation Profiles").font(.headline)
            Text(GenerationProfile(name: "").appliedSettingsDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(store.profiles) { profile in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name).bold()
                        Text(profile.modelID ?? "Any model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Temperature \(profile.temperature.formatted(.number.precision(.fractionLength(2)))) · top-p \(profile.topP.formatted(.number.precision(.fractionLength(2)))) · top-k \(profile.topK) · repetition \(profile.repetitionPenalty.formatted(.number.precision(.fractionLength(2)))) · max output \(profile.maxOutputTokens) · context \(profile.contextLength)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Apply to Current Chat") {
                        applyProfile(profile)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Delete", role: .destructive) { store.deleteProfile(profile) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(10)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 10))
            }

            GroupBox("New Profile") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Profile name", text: $profileName)
                    Picker("Applies to", selection: $profileModelID) {
                        Text("Any model").tag(nil as String?)
                        ForEach(chatViewModel.installedModels) { model in
                            Text(model.displayName).tag(model.id as String?)
                        }
                    }
                    TextField("System prompt (optional)", text: $profileSystemPrompt, axis: .vertical)
                        .lineLimit(2...4)
                    HStack {
                        Text("Temperature")
                        Slider(value: $profileTemperature, in: 0...2, step: 0.05)
                        Text(profileTemperature.formatted(.number.precision(.fractionLength(2))))
                            .font(.caption)
                            .frame(width: 36)
                    }
                    HStack {
                        Text("Top-p")
                        Slider(value: $profileTopP, in: 0...1, step: 0.05)
                        Text(profileTopP.formatted(.number.precision(.fractionLength(2))))
                            .font(.caption)
                            .frame(width: 36)
                    }
                    Stepper("Top-k: \(profileTopK) (0 = off)", value: $profileTopK, in: 0...100)
                    Stepper("Max output tokens: \(profileMaxTokens)", value: $profileMaxTokens, in: 64...8192, step: 64)
                    Stepper("Context length: \(profileContextLength)", value: $profileContextLength, in: 1024...32768, step: 1024)
                    HStack {
                        Text("Repetition penalty")
                        Slider(value: $profileRepetitionPenalty, in: 0.5...2, step: 0.05)
                        Text(profileRepetitionPenalty.formatted(.number.precision(.fractionLength(2))))
                            .font(.caption)
                            .frame(width: 36)
                    }
                    Button("Save Profile") {
                        store.saveProfile(GenerationProfile(
                            name: profileName,
                            modelID: profileModelID,
                            systemPrompt: profileSystemPrompt,
                            temperature: profileTemperature,
                            topP: profileTopP,
                            topK: profileTopK,
                            repetitionPenalty: profileRepetitionPenalty,
                            maxOutputTokens: profileMaxTokens,
                            contextLength: profileContextLength
                        ))
                        profileName = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func applyProfile(_ profile: GenerationProfile) {
        guard let conversation = chatViewModel.selectedConversation else {
            statusText = "Open a chat first, then apply the profile."
            return
        }
        conversation.temperature = profile.temperature
        if !profile.systemPrompt.isEmpty {
            conversation.systemPrompt = profile.systemPrompt
        }
        if let modelID = profile.modelID,
           let model = chatViewModel.installedModels.first(where: { $0.id == modelID }) {
            chatViewModel.loadInstalledModel(model)
        }
        try? modelContext.save()
        statusText = "Applied “\(profile.name)” to the current conversation (temperature + system prompt on the MLX backend)."
    }
}
