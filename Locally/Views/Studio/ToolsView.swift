import SwiftUI
import AppKit

/// Tools (feature K): the bounded tool registry, made visible. Run tools
/// directly, authorize folders for file search, and run a tool-enabled
/// exchange where the model may request one tool — with confirmation for
/// sensitive tools before anything executes.
struct ToolsView: View {
    @Bindable var chatViewModel: ChatViewModel
    @State private var registry = ToolRegistry.shared

    // Direct-run state
    @State private var selectedToolID = "calculator"
    @State private var argumentText = ""
    @State private var directResult = ""
    @State private var directError: String?
    @State private var showDirectConfirm = false

    // Tool-calling state
    @State private var agentPrompt = "What is 25% of 1840, and what time is it?"
    @State private var agentAnswer = ""
    @State private var agentSteps: [ToolRunStep] = []
    @State private var pendingConfirmation: (toolID: String, arguments: [String: String])?
    @State private var isAgentRunning = false

    private var selectedTool: ToolDefinition? {
        registry.definition(for: selectedToolID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Only the tools below exist. There is no shell tool, model arguments are validated against each tool's allow-list, and file search only looks inside folders you authorize here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ComputerUsePermissionsView()
                Divider()
                catalogSection
                Divider()
                directRunSection
                Divider()
                foldersSection
                Divider()
                agentSection
            }
            .padding()
        }
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tool Registry").font(.headline)
            ForEach(registry.tools) { tool in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(tool.name).bold()
                            if tool.requiresConfirmation {
                                Text("Needs confirmation")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.orange.opacity(0.2))
                                    .foregroundStyle(.orange)
                                    .clipShape(.capsule)
                            }
                        }
                        Text(tool.toolDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(tool.id)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 10))
            }
        }
    }

    private var directRunSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run a Tool").font(.headline)
            Picker("Tool", selection: $selectedToolID) {
                ForEach(registry.tools) { tool in
                    Text(tool.name).tag(tool.id)
                }
            }
            .pickerStyle(.menu)

            if let tool = selectedTool, !tool.allowedArguments.isEmpty {
                TextField(tool.allowedArguments.sorted().first.map { "Argument: \($0)" } ?? "Argument", text: $argumentText)
                    .textFieldStyle(.roundedBorder)
            }

            Button("Execute") {
                if selectedTool?.requiresConfirmation == true {
                    showDirectConfirm = true
                } else {
                    runDirect(confirmed: false)
                }
            }
            .buttonStyle(.borderedProminent)
            .alert("Confirm File Search?", isPresented: $showDirectConfirm) {
                Button("Run Search") { runDirect(confirmed: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("File search will read file names and text contents inside your authorized folders only.")
            }

            if let directError {
                Text(directError).font(.caption).foregroundStyle(.red)
            }
            if !directResult.isEmpty {
                Text(directResult)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                    .clipShape(.rect(cornerRadius: 10))
            }
        }
    }

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Authorized Folders (File Search)").font(.headline)
            ForEach(registry.authorizedFolders, id: \.path) { folder in
                HStack {
                    Image(systemName: "folder")
                    Text(folder.path).font(.caption).lineLimit(1)
                    Spacer()
                    Button("Remove") {
                        registry.authorizedFolders = registry.authorizedFolders.filter { $0 != folder }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Button("Add Folder…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    registry.authorizedFolders = registry.authorizedFolders + [url]
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask With Tools").font(.headline)
            Text("The selected installed model may request one tool. Its request is parsed and validated; sensitive tools stop for your approval, and the real result is fed back for the final answer.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Prompt", text: $agentPrompt, axis: .vertical)
                .lineLimit(2...4)
            HStack {
                Button {
                    runAgent(confirmedToolIDs: [])
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAgentRunning || chatViewModel.installedModels.isEmpty)
                if isAgentRunning { ProgressView().controlSize(.small) }
            }

            if let pending = pendingConfirmation {
                VStack(alignment: .leading, spacing: 6) {
                    Text("The model wants to run “\(pending.toolID)” with \(pending.arguments). Approve?")
                        .font(.callout)
                    HStack {
                        Button("Approve & Run") {
                            pendingConfirmation = nil
                            runAgent(confirmedToolIDs: [pending.toolID])
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Decline", role: .destructive) {
                            pendingConfirmation = nil
                            agentAnswer = "Tool request declined — nothing was executed."
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(10)
                .background(.orange.opacity(0.12))
                .clipShape(.rect(cornerRadius: 10))
            }

            ForEach(agentSteps) { step in
                Label("\(step.title): \(step.detail)", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !agentAnswer.isEmpty {
                Text(agentAnswer)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                    .clipShape(.rect(cornerRadius: 10))
            }
        }
    }

    private func runDirect(confirmed: Bool) {
        directError = nil
        directResult = ""
        let toolID = selectedToolID
        var arguments: [String: String] = [:]
        if let key = selectedTool?.allowedArguments.sorted().first {
            arguments[key] = argumentText
        }
        Task {
            do {
                directResult = try await registry.execute(toolID: toolID, arguments: arguments, confirmed: confirmed)
            } catch {
                directError = error.localizedDescription
            }
        }
    }

    private func runAgent(confirmedToolIDs: Set<String>) {
        guard let model = chatViewModel.installedModels.first(where: { $0.id == chatViewModel.selectedModelID })
            ?? chatViewModel.installedModels.first else { return }
        isAgentRunning = true
        Task {
            let outcome = await ToolCallingService.run(prompt: agentPrompt, model: model, confirmedToolIDs: confirmedToolIDs)
            switch outcome {
            case .finished(let answer, let steps):
                agentAnswer = answer
                agentSteps = steps
            case .needsConfirmation(let toolID, let arguments, let steps):
                agentSteps = steps
                pendingConfirmation = (toolID, arguments)
            case .failed(let message, let steps):
                agentSteps = steps
                agentAnswer = "Failed: \(message)"
            }
            isAgentRunning = false
        }
    }
}
