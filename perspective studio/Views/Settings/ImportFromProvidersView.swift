import SwiftUI
import AppKit

enum AIProviderTarget: String, CaseIterable, Identifiable {
    case chatgpt = "ChatGPT"
    case claude = "Claude"
    case gemini = "Gemini"
    case other = "Other"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .chatgpt: "bubble.left.and.exclamationmark.bubble.right.fill"
        case .claude: "sparkle"
        case .gemini: "stars"
        case .other: "globe"
        }
    }

    var tip: String {
        switch self {
        case .chatgpt:
            "Paste this into ChatGPT (works great with GPT-4o / o1) where you have active conversation history or Memory enabled."
        case .claude:
            "Paste this into Claude (Claude 3.5 Sonnet / Opus) with your projects or past conversations."
        case .gemini:
            "Paste this into Google Gemini (Advanced / 1.5 Pro) where you have history enabled."
        case .other:
            "Paste this into any frontier AI that has interacted with you."
        }
    }
}

struct ImportFromProvidersView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("customSystemPrompt") private var customSystemPrompt: String = ""
    @AppStorage("importedPersonaSummary") private var importedPersonaSummary: String = ""

    @State private var selectedProvider: AIProviderTarget = .chatgpt
    @State private var pastedResponseText: String = ""
    @State private var copiedPrompt = false
    @State private var showAppliedAlert = false

    private var extractionPrompt: String {
        """
        Based on EVERYTHING you know about me from our conversations, my memory profile, instructions, preferences, work style, coding patterns, background, communication habits, and goals:

        Please synthesize a comprehensive, personalized AI Persona and System Prompt for my private local AI assistant in the Locally app.

        Structure your output as a ready-to-use System Prompt containing:
        1. [User Profile]: Who I am, my role, primary domains, and technical environment.
        2. [Communication Style]: My preferred tone, formatting, brevity vs detail, and how you should speak to me.
        3. [Coding & Problem Solving]: Languages, frameworks, conventions, and quality standards I care about.
        4. [Key Rules]: Specific things to always do or avoid when answering my questions.

        Output ONLY the synthesized system prompt so I can directly paste it into Locally.
        """
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header Banner
                    HStack(spacing: 14) {
                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            .font(.system(size: 38))
                            .foregroundStyle(
                                LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Import Persona from Providers")
                                .font(.title2)
                                .bold()
                            Text("Transfer what ChatGPT, Claude, or Gemini already knows about you directly into your private, on-device AI.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 4)

                    Divider()

                    // Step 1: Pick Provider & Copy Prompt
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Step 1: Copy Extraction Prompt")
                                .font(.headline)
                                .bold()

                            Spacer()

                            Picker("Provider", selection: $selectedProvider) {
                                ForEach(AIProviderTarget.allCases) { p in
                                    Label(p.rawValue, systemImage: p.icon).tag(p)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 140)
                        }

                        Text(selectedProvider.tip)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        // Extraction Prompt Box
                        VStack(alignment: .trailing, spacing: 8) {
                            ScrollView {
                                Text(extractionPrompt)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                            .frame(height: 140)
                            .liquidGlass(.rect(cornerRadius: 10), isClear: true)

                            Button {
                                copyPromptToClipboard()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: copiedPrompt ? "checkmark" : "doc.on.doc")
                                    Text(copiedPrompt ? "Copied to Clipboard!" : "Copy Extraction Prompt")
                                }
                                .font(.subheadline)
                                .bold()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(16)
                    .liquidGlass(.rect(cornerRadius: 16))

                    // Step 2: Paste Response and Apply
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Step 2: Paste the Response Here")
                            .font(.headline)
                            .bold()

                        Text("Send the prompt above into your existing AI model, then copy its output and paste it below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $pastedResponseText)
                            .font(.system(size: 13))
                            .frame(minHeight: 160)
                            .padding(8)
                            .liquidGlass(.rect(cornerRadius: 10), isClear: true)

                        HStack {
                            Button("Clear") {
                                pastedResponseText = ""
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .disabled(pastedResponseText.isEmpty)

                            Spacer()

                            Button {
                                applyImportedPersona()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "sparkles")
                                    Text("Apply Persona to Locally")
                                }
                                .font(.headline)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(pastedResponseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(16)
                    .liquidGlass(.rect(cornerRadius: 16))
                }
                .padding(24)
            }
            .navigationTitle("Import From Providers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Persona Imported Successfully!", isPresented: $showAppliedAlert) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("Your personalized system prompt has been applied. All conversations in Locally will now utilize this persona.")
            }
        }
        .frame(minWidth: 580, minHeight: 600)
    }

    private func copyPromptToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(extractionPrompt, forType: .string)
        withAnimation {
            copiedPrompt = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation {
                copiedPrompt = false
            }
        }
    }

    private func applyImportedPersona() {
        let clean = pastedResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        customSystemPrompt = clean
        importedPersonaSummary = "Imported from \(selectedProvider.rawValue) on \(Date.now.formatted(date: .abbreviated, time: .shortened))"
        showAppliedAlert = true
    }
}
