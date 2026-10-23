import AVFAudio
import SwiftUI
import AppKit

enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance = "Appearance"
    case personalization = "Personalization"
    case thinking = "Thinking & AI"
    case audio = "Speech"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance: "paintpalette.fill"
        case .personalization: "person.crop.circle"
        case .thinking: "lightbulb.fill"
        case .audio: "speaker.wave.2.fill"
        case .about: "info.circle.fill"
        }
    }
}

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
    var onClose: (() -> Void)? = nil
    @State private var selectedCategory: SettingsCategory = .appearance

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
        VStack(spacing: 0) {
            // Category Navigation Bar
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

                ForEach(SettingsCategory.allCases) { category in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedCategory = category
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: category.icon)
                                .font(.system(size: 12))
                            Text(category.rawValue)
                                .font(.system(size: 13, weight: selectedCategory == category ? .semibold : .regular))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .foregroundStyle(selectedCategory == category ? .white : .primary)
                        .background(
                            selectedCategory == category
                                ? Color.accentColor
                                : Color.clear,
                            in: .capsule
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            // Main Content Area for Selected Category
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedCategory {
                    case .appearance:
                        appearanceCategoryView
                    case .personalization:
                        personalizationCategoryView
                    case .thinking:
                        thinkingCategoryView
                    case .audio:
                        audioCategoryView
                    case .about:
                        aboutCategoryView
                    }
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
        .frame(minWidth: 580, minHeight: 460)
        .onAppear {
            availableVoices = AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.starts(with: "en") }
            if let c1 = Color(hex: customTopHex) { customTopColor = c1 }
            if let c2 = Color(hex: customBottomHex) { customBottomColor = c2 }
        }
        .sheet(isPresented: $showingImportSheet) {
            ImportFromProvidersView()
        }
    }

    // MARK: - Category 1: Appearance

    private var appearanceCategoryView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Chat Appearance")
                    .font(.title2)
                    .bold()
                Text("Customize the real-time background gradient of the Chat window.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Live Preview Card
            VStack(alignment: .leading, spacing: 8) {
                Text("Background Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: activeColors, startPoint: .top, endPoint: .bottom))
                    .frame(height: 100)
                    .overlay(
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Meet the new Apple Foundation")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("Locally AI • Active Theme")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            Spacer()
                            Image(systemName: "apple.intelligence")
                                .font(.system(size: 26))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .padding(.horizontal, 20)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Theme Presets")
                    .font(.headline)

                Picker("Preset", selection: $gradientPresetRaw) {
                    ForEach(GradientPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)

                if gradientPresetRaw == GradientPreset.custom.rawValue {
                    HStack(spacing: 24) {
                        ColorPicker("Top Color", selection: $customTopColor)
                            .onChange(of: customTopColor) { _, newColor in
                                customTopHex = newColor.toHex()
                            }

                        ColorPicker("Bottom Color", selection: $customBottomColor)
                            .onChange(of: customBottomColor) { _, newColor in
                                customBottomHex = newColor.toHex()
                            }
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(16)
            .liquidGlass(.rect(cornerRadius: 14), isClear: true)
        }
    }

    // MARK: - Category 2: Personalization

    private var personalizationCategoryView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Personalization")
                    .font(.title2)
                    .bold()
                Text("Shape how your on-device AI communicates, behaves, and reasons.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // System Prompt Card
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Custom System Prompt")
                        .font(.headline)
                    Spacer()
                    if !customSystemPrompt.isEmpty {
                        Button("Clear") {
                            customSystemPrompt = ""
                        }
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

                // Quick Presets
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quick Presets:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
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
            }
            .padding(16)
            .liquidGlass(.rect(cornerRadius: 14), isClear: true)

            // Personality Pickers Card
            VStack(alignment: .leading, spacing: 14) {
                Text("Voice & Tone Preferences")
                    .font(.headline)

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
            }
            .padding(16)
            .liquidGlass(.rect(cornerRadius: 14), isClear: true)

            // Import From Providers Launcher Card
            HStack(spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Persona From Other AIs")
                        .font(.headline)
                    Text("Transfer preferences from ChatGPT, Claude, or Gemini into Locally.")
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
            .liquidGlass(.rect(cornerRadius: 14), isClear: true)
        }
    }

    // MARK: - Category 3: Thinking & AI

    private var thinkingCategoryView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Thinking & Reasoning")
                    .font(.title2)
                    .bold()
                Text("Adjust how deeply your on-device models analyze queries before answering.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                Toggle("Enable Thinking Mode (Chain-of-Thought)", isOn: $enableThinkingMode)
                    .font(.headline)

                Text("When active, models construct reasoning steps and evaluate alternatives before composing their final response.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Reasoning Effort")
                        .font(.subheadline)
                        .bold()

                    Picker("Effort", selection: $thinkingBudget) {
                        Text("Low (Quick Analysis)").tag("low")
                        Text("Medium (Balanced)").tag("medium")
                        Text("High (Deep Rigorous Reasoning)").tag("high")
                    }
                    .pickerStyle(.segmented)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Default Context Window")
                            .font(.subheadline)
                            .bold()
                        Spacer()
                        Text("\(defaultContextLength) tokens")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Context Window", selection: $defaultContextLength) {
                        Text("2,048 tokens").tag(2048)
                        Text("4,096 tokens").tag(4096)
                        Text("8,192 tokens").tag(8192)
                        Text("16,384 tokens").tag(16384)
                    }
                    .pickerStyle(.segmented)
                }

                Divider()

                Toggle("Rich Markdown & Syntax Highlighting", isOn: $enableRichMarkdown)
                Toggle("Cross-Session Context & Memory", isOn: $enableCrossSessionMemory)
            }
            .padding(16)
            .liquidGlass(.rect(cornerRadius: 14), isClear: true)
        }
    }

    // MARK: - Category 4: Speech & Audio

    private var audioCategoryView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Speech & Audio")
                    .font(.title2)
                    .bold()
                Text("Configure text-to-speech voice readout and playback preferences.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                Toggle("Automatically Read Aloud Assistant Responses", isOn: $autoReadAloud)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Preferred System Voice")
                        .font(.subheadline)
                        .bold()

                    Picker("Voice", selection: $ttsVoiceIdentifier) {
                        Text("Default System Voice").tag("")
                        ForEach(availableVoices, id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.language))").tag(voice.identifier)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .padding(16)
            .liquidGlass(.rect(cornerRadius: 14), isClear: true)
        }
    }

    // MARK: - Category 5: About Locally

    private var aboutCategoryView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("About Locally")
                    .font(.title2)
                    .bold()
                Text("Private, on-device AI powered by Apple Silicon.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 16) {
                Image(systemName: "apple.intelligence")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                    .frame(width: 80, height: 80)
                    .liquidGlass(.circle)

                VStack(spacing: 4) {
                    Text("Locally")
                        .font(.title3)
                        .bold()
                    Text("Version 2.0 • Build 2026")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Locally executes open-source LLMs and VLMs entirely on your Mac's Neural Engine and Unified Memory with MLX. Zero server telemetry, zero external data leaks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                Divider()

                Button("Reset Onboarding Flow", role: .destructive) {
                    hasCompletedOnboarding = false
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .liquidGlass(.rect(cornerRadius: 16), isClear: true)
        }
    }

    // MARK: - Helpers

    private func promptPresetButton(title: String, prompt: String) -> some View {
        Button {
            customSystemPrompt = prompt
        } label: {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.15))
                .clipShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}
