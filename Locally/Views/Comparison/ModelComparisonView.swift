import SwiftUI
import AppKit

struct ModelComparisonView: View {
    @Bindable var chatViewModel: ChatViewModel
    var onClose: (() -> Void)? = nil

    @State private var viewModel = ModelComparisonViewModel()
    @State private var copiedModelA = false
    @State private var copiedModelB = false

    @AppStorage("chatGradientTheme") private var gradientPresetRaw: String = GradientPreset.aurora.rawValue
    @AppStorage("chatGradientTopHex") private var customTopHex: String = GradientTheme.defaultTopHex
    @AppStorage("chatGradientBottomHex") private var customBottomHex: String = GradientTheme.defaultBottomHex

    private var activeColors: [Color] {
        GradientTheme.activeColors(
            presetRaw: gradientPresetRaw,
            customTopHex: customTopHex,
            customBottomHex: customBottomHex
        )
    }

    private let samplePrompts = [
        "Write a clean, idiomatic Swift function to parse JSON with Swift 6 concurrency.",
        "Explain quantum entanglement and superpositions to a 10-year-old.",
        "Compare the philosophical ideas of Kant's Categorical Imperative with Utilitarianism.",
        "Draft a compelling, conversion-focused product announcement for an on-device AI app."
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: activeColors,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Navigation Bar
                topBar

                // Model Selection & Memory Protection Strip
                modelSelectionHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                // Side-by-Side Comparison Workspace
                comparisonWorkspace
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)

                // Prompt Input & Control Bar
                promptComposerBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
        }
        .onAppear {
            chatViewModel.scanInstalledModels()
            if viewModel.selectedModelA == nil, let first = chatViewModel.installedModels.first {
                viewModel.selectedModelA = first
            }
            if viewModel.selectedModelB == nil {
                if chatViewModel.installedModels.count > 1 {
                    viewModel.selectedModelB = chatViewModel.installedModels[1]
                } else if let first = chatViewModel.installedModels.first {
                    viewModel.selectedModelB = first
                }
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
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
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .liquidGlass(.capsule)
                }
                .buttonStyle(.plain)
            }

            Text("Side-by-Side Model Comparison")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            // Memory Safety Badge
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                Text(viewModel.memorySafetyNotice)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .liquidGlass(.capsule, isClear: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: - Model Selectors

    private var modelSelectionHeader: some View {
        HStack(spacing: 14) {
            // Model A Selector Card
            modelPickerCard(
                label: "Model A",
                selection: $viewModel.selectedModelA,
                tagColor: .blue
            )

            // VS Divider
            VStack {
                Text("VS")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .liquidGlass(.capsule)
            }

            // Model B Selector Card
            modelPickerCard(
                label: "Model B",
                selection: $viewModel.selectedModelB,
                tagColor: .purple
            )
        }
    }

    private func modelPickerCard(
        label: String,
        selection: Binding<InstalledModel?>,
        tagColor: Color
    ) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tagColor)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            Picker("", selection: selection) {
                if chatViewModel.installedModels.isEmpty {
                    Text("No downloaded models").tag(nil as InstalledModel?)
                } else {
                    ForEach(chatViewModel.installedModels) { model in
                        Text(model.displayName).tag(model as InstalledModel?)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 240)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .liquidGlass(.rect(cornerRadius: 12), isClear: true)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Comparison Workspace Panels

    private var comparisonWorkspace: some View {
        HStack(spacing: 14) {
            // Model A Panel
            comparisonResultPanel(
                label: "Model A",
                model: viewModel.selectedModelA,
                result: viewModel.resultA,
                accentColor: .blue,
                isCopied: copiedModelA,
                onCopy: {
                    viewModel.copyResponseA()
                    copiedModelA = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copiedModelA = false
                    }
                },
                onRerun: {
                    viewModel.rerunModelA()
                }
            )

            // Model B Panel
            comparisonResultPanel(
                label: "Model B",
                model: viewModel.selectedModelB,
                result: viewModel.resultB,
                accentColor: .purple,
                isCopied: copiedModelB,
                onCopy: {
                    viewModel.copyResponseB()
                    copiedModelB = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copiedModelB = false
                    }
                },
                onRerun: {
                    viewModel.rerunModelB()
                }
            )
        }
    }

    private func comparisonResultPanel(
        label: String,
        model: InstalledModel?,
        result: ComparisonResult?,
        accentColor: Color,
        isCopied: Bool,
        onCopy: @escaping () -> Void,
        onRerun: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text(model?.displayName ?? label)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer()

                if let status = result?.status {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(status.badgeColor)
                            .frame(width: 6, height: 6)
                        Text(status.displayText)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(status.badgeColor.opacity(0.18))
                    .clipShape(.capsule)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Metrics Bar
            if let res = result, res.latencySeconds > 0 {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "stopwatch")
                            .font(.system(size: 10))
                        Text("\(res.latencySeconds, format: .number.precision(.fractionLength(2)))s")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                        Text("\(res.tokensPerSecond, format: .number.precision(.fractionLength(1))) tok/s")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    if let ttft = res.timeToFirstTokenSeconds {
                        HStack(spacing: 4) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 10))
                            Text("TTFT \(ttft, format: .number.precision(.fractionLength(2)))s")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    if res.loadSeconds > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 10))
                            Text("Load \(res.loadSeconds, format: .number.precision(.fractionLength(1)))s")
                                .font(.system(size: 11))
                        }
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10))
                        Text("\(res.tokensCount) tokens (\(res.charactersCount) chars)")
                            .font(.system(size: 11))
                    }
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.04))
            }

            Divider()

            // Response Text Stream
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let res = result, !res.response.isEmpty {
                        // Reasoning goes in the thinking UI; the column
                        // shows the answer only (same split as chat).
                        let parsed = ThinkingContentParser.parse(res.response)
                        if parsed.hasThinking {
                            ThinkingModelUI(
                                thinkingText: parsed.thinkingText,
                                isStreaming: res.status == .generating && parsed.isThinkingOpen
                            )
                        }
                        if !parsed.answer.isEmpty {
                            Text(parsed.answer)
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else if result?.status == .generating || result?.status == .loading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Model thinking...")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.top, 24)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 24))
                                .foregroundStyle(.white.opacity(0.2))
                            Text("Response will appear here")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Footer Actions
            HStack {
                Button {
                    onCopy()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "Copied" : "Copy")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .disabled(result?.response.isEmpty ?? true)

                Spacer()

                Button {
                    onRerun()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                        Text("Rerun Model")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isComparing || viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.03))
        }
        .liquidGlass(.rect(cornerRadius: 14))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Prompt Input & Composer Bar

    private var promptComposerBar: some View {
        VStack(spacing: 8) {
            // Quick Sample Prompts Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(samplePrompts, id: \.self) { sample in
                        Button {
                            viewModel.prompt = sample
                        } label: {
                            Text(sample)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .liquidGlass(.capsule, isClear: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Input Bar Capsule
            HStack(spacing: 12) {
                TextField("Enter prompt to test both models simultaneously...", text: $viewModel.prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .onSubmit {
                        if !viewModel.isComparing {
                            viewModel.startComparison()
                        }
                    }

                if viewModel.isComparing {
                    Button {
                        viewModel.stopComparison()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "stop.fill")
                            Text("Stop")
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.red)
                        .clipShape(.capsule)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        viewModel.startComparison()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Compare Models")
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                        .clipShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .liquidGlass(.capsule)
        }
    }
}
