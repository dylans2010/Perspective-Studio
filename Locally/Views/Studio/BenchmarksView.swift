import SwiftUI

/// Performance dashboard (feature E). Every number shown here was measured
/// during a real run — load time, time to first token, generation speed,
/// elapsed time, output tokens, and the process's real memory footprint.
/// Nothing is estimated; fields a run could not measure show "—".
struct BenchmarksView: View {
    @Bindable var chatViewModel: ChatViewModel
    @State private var store = BenchmarkStore.shared
    @State private var selectedModel: InstalledModel?
    @State private var prompt: String = "Explain how photosynthesis works in three sentences."
    @State private var repetitions: Int = 1
    @State private var isRunning = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Run a Benchmark") {
                    Picker("Model", selection: $selectedModel) {
                        Text("Select a model").tag(nil as InstalledModel?)
                        ForEach(chatViewModel.installedModels) { model in
                            Text(model.displayName).tag(model as InstalledModel?)
                        }
                    }
                    TextField("Prompt", text: $prompt, axis: .vertical)
                        .lineLimit(2...4)
                    Stepper("Repetitions: \(repetitions)", value: $repetitions, in: 1...5)
                    HStack {
                        Button {
                            runBenchmark()
                        } label: {
                            Label("Run Benchmark", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedModel == nil || isRunning || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                        if isRunning { ProgressView().controlSize(.small) }
                    }
                    if let errorText {
                        Text(errorText).foregroundStyle(.red).font(.caption)
                    }
                    Text("Measured on this Mac with the real model — load time, time to first token, tok/s, and memory are recorded from the actual token stream.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 300)

            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                if !store.results.isEmpty {
                    Button("Clear History", role: .destructive) { store.deleteAll() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal)

            if store.results.isEmpty {
                ContentUnavailableView("No Benchmarks Yet", systemImage: "gauge", description: Text("Run a benchmark to record measured performance for a model."))
            } else {
                List {
                    ForEach(store.results.sorted { $0.date > $1.date }) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(result.modelID)
                                    .font(.subheadline)
                                    .bold()
                                    .lineLimit(1)
                                Spacer()
                                Text(result.date, format: .dateTime.month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 14) {
                                metric("Load", result.loadSeconds.map { seconds($0) })
                                metric("TTFT", result.timeToFirstTokenSeconds.map { seconds($0) })
                                metric("Total", seconds(result.totalSeconds))
                                metric("Speed", result.tokensPerSecond.map { "\($0.formatted(.number.precision(.fractionLength(1)))) tok/s" })
                                metric("Tokens", "\(result.outputTokens)")
                                metric("Memory", result.memoryFootprintBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) })
                                if result.repetitions > 1 {
                                    metric("Reps", "\(result.repetitions)")
                                }
                            }
                            Text("“\(result.promptPreview)”")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func metric(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value ?? "—").font(.caption).bold()
        }
    }

    private func seconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(2))))s"
    }

    private func runBenchmark() {
        guard let model = selectedModel else { return }
        isRunning = true
        errorText = nil
        Task {
            do {
                _ = try await BenchmarkService.run(model: model, prompt: prompt, repetitions: repetitions)
            } catch {
                errorText = error.localizedDescription
            }
            isRunning = false
        }
    }
}
