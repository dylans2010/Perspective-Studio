import AVFAudio
import SwiftUI
import AppKit

enum ResponseStylePersonality: String, CaseIterable, Identifiable {
    case helpful = "Helpful & Balanced"
    case concise = "Direct & Concise"
    case creative = "Creative & Expansive"
    case analytical = "Technical & Analytical"

    var id: String { rawValue }
}

enum ResponseTone: String, CaseIterable, Identifiable {
    case natural = "Natural & Warm"
    case professional = "Professional"
    case casual = "Casual & Friendly"
    case academic = "Academic & Rigorous"

    var id: String { rawValue }
}

enum ResponseLengthPreference: String, CaseIterable, Identifiable {
    case concise = "Concise"
    case balanced = "Balanced"
    case detailed = "Detailed"

    var id: String { rawValue }
}

struct SettingsView: View {
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
    @AppStorage("enableThinkingMode") private var enableThinkingMode: Bool = false
    @AppStorage("enableRichMarkdown") private var enableRichMarkdown: Bool = true
    @AppStorage("enableCrossSessionMemory") private var enableCrossSessionMemory: Bool = true

    // General & Device
    @AppStorage("experienceLevel") private var experienceLevel: String = ExperienceLevel.beginner.rawValue
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("defaultContextLength") private var defaultContextLength: Int = 4096
    @AppStorage("autoReadAloud") private var autoReadAloud: Bool = false
    @AppStorage("ttsVoiceIdentifier") private var ttsVoiceIdentifier: String = ""

    @State private var availableVoices: [AVSpeechSynthesisVoice] = []
    @State private var showingImportSheet = false
    @State private var customTopColor: Color = Color(hex: GradientTheme.defaultTopHex) ?? .green
    @State private var customBottomColor: Color = Color(hex: GradientTheme.defaultBottomHex) ?? .black

    private var activeColors: [Color] {
        GradientTheme.activeColors(
            presetRaw: gradientPresetRaw,
            customTopHex: customTopHex,
            customBottomHex: customBottomHex
        )
    }

    var body: some View {
        Form {
            // MARK: - Section 1: Chat Appearance & Gradient Customization
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    // Live Gradient Preview Card
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Chat Background Preview")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(colors: activeColors, startPoint: .top, endPoint: .bottom))
                            .frame(height: 75)
                            .overlay(
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Meet the new Apple Foundation")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(.white)
                                        Text("Locally AI • Active Theme")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.white.opacity(0.75))
                                    }
                                    Spacer()
                                    Image(systemName: "apple.intelligence")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                                .padding(.horizontal, 16)
                            )
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15), lineWidth: 1))
                    }

                    Picker("Gradient Preset", selection: $gradientPresetRaw) {
                        ForEach(GradientPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset.rawValue)
                        }
                    }

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
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Label("Chat Appearance & Gradients", systemImage: "paintpalette.fill")
                    .accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Changes the background gradient of the Chat window in real-time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Section 2: Personalization
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Custom System Prompt")
                            .font(.subheadline)
                            .bold()

                        Spacer()

                        if !customSystemPrompt.isEmpty {
                            Button("Clear") {
                                customSystemPrompt = ""
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }

                    TextEditor(text: $customSystemPrompt)
                        .font(.system(size: 12))
                        .frame(minHeight: 90)
                        .padding(6)
                        .background(Color(.controlBackgroundColor))
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 1))

                    if !importedPersonaSummary.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text(importedPersonaSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Prompt Preset Quick Buttons
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quick Prompt Presets:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            promptPresetButton(
                                title: "Helpful & Direct",
                                prompt: "You are a concise, highly capable AI assistant. Provide direct answers with clarity, precision, and no filler."
                            )
                            promptPresetButton(
                                title: "Senior Engineer",
                                prompt: "You are a senior software architect. Provide production-grade, idiomatic code, explain edge cases, and follow best design patterns."
                            )
                            promptPresetButton(
                                title: "Deep Thinker",
                                prompt: "You are an analytical philosopher and researcher. Think step-by-step, explore nuances, evaluate tradeoffs, and reason rigorously."
                            )
                        }
                    }

                    Divider()
                        .padding(.vertical, 4)

                    // Personality, Tone, and Length Pickers
                    Picker("Personality Style", selection: $personalityStyle) {
                        ForEach(ResponseStylePersonality.allCases) { item in
                            Text(item.rawValue).tag(item.rawValue)
                        }
                    }

                    Picker("Tone", selection: $responseTone) {
                        ForEach(ResponseTone.allCases) { item in
                            Text(item.rawValue).tag(item.rawValue)
                        }
                    }

                    Picker("Response Length", selection: $responseLength) {
                        ForEach(ResponseLengthPreference.allCases) { item in
                            Text(item.rawValue).tag(item.rawValue)
                        }
                    }

                    Divider()
                        .padding(.vertical, 4)

                    // Customization Toggles
                    Toggle("Enable Step-by-Step Thinking (Reasoning)", isOn: $enableThinkingMode)
                    Toggle("Rich Markdown & Code Highlighting", isOn: $enableRichMarkdown)
                    Toggle("Cross-Session Context & Memory", isOn: $enableCrossSessionMemory)
                }
            } header: {
                Label("Personalization", systemImage: "person.crop.circle.badge.checkmark")
                    .accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Customize how your on-device AI thinks, talks, and behaves across all conversations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Section 3: Import From Providers
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.title2)
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Import Persona From Other AIs")
                                .font(.headline)
                            Text("Extract what ChatGPT, Claude, or Gemini already knows about your preferences and transfer it to Locally.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            showingImportSheet = true
                        } label: {
                            Text("Open Importer")
                                .bold()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Label("Import From Providers", systemImage: "square.and.arrow.down.on.square.fill")
                    .accessibilityAddTraits(.isHeader)
            }

            // MARK: - Section 4: Model Defaults & Generation
            Section {
                Picker("Experience Level", selection: $experienceLevel) {
                    ForEach(ExperienceLevel.allCases) { level in
                        Label(level.displayName, systemImage: level.icon)
                            .tag(level.rawValue)
                    }
                }

                Picker("Context Length", selection: $defaultContextLength) {
                    Text("2,048 tokens").tag(2048)
                    Text("4,096 tokens").tag(4096)
                    Text("8,192 tokens").tag(8192)
                    Text("16,384 tokens").tag(16384)
                }
            } header: {
                Label("Model Defaults", systemImage: "slider.horizontal.3")
                    .accessibilityAddTraits(.isHeader)
            }

            // MARK: - Section 5: Text-to-Speech
            Section {
                Toggle("Read Responses Aloud", isOn: $autoReadAloud)

                Picker("Voice", selection: $ttsVoiceIdentifier) {
                    Text("Default").tag("")
                    ForEach(availableVoices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))")
                            .tag(voice.identifier)
                    }
                }
            } header: {
                Label("Speech & Audio", systemImage: "speaker.wave.2.fill")
                    .accessibilityAddTraits(.isHeader)
            }

            // MARK: - Section 6: Device & Memory
            Section {
                LabeledContent("Device Memory") {
                    Text(RAMService.ramDescription)
                }
                LabeledContent("Available for Models") {
                    Text("\(RAMService.availableRAMForModels.formatted(.number.precision(.fractionLength(1)))) GB")
                }
            } header: {
                Label("Device", systemImage: "memorychip")
                    .accessibilityAddTraits(.isHeader)
            }

            // MARK: - Section 7: About Locally
            Section {
                LabeledContent("App") {
                    Text("Locally")
                }
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
                LabeledContent("Engine") {
                    Text("MLX & Apple Silicon")
                }

                Button("Reset Onboarding") {
                    hasCompletedOnboarding = false
                }
                .foregroundStyle(.red)
            } header: {
                Label("About Locally", systemImage: "info.circle.fill")
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .sheet(isPresented: $showingImportSheet) {
            ImportFromProvidersView()
        }
        .onAppear {
            availableVoices = TTSService.shared.availableVoices()
            if let top = Color(hex: customTopHex) { customTopColor = top }
            if let bottom = Color(hex: customBottomHex) { customBottomColor = bottom }
        }
    }

    private func promptPresetButton(title: String, prompt: String) -> some View {
        Button(title) {
            customSystemPrompt = prompt
        }
        .font(.caption2)
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }
}
