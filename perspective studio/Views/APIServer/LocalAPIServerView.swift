import SwiftUI
import AppKit

struct LocalAPIServerView: View {
    @Bindable var chatViewModel: ChatViewModel
    var onClose: (() -> Void)? = nil

    @State private var serverManager = LocalAPIServerManager.shared
    @State private var portString: String = "1234"
    @State private var showLANWarningAlert: Bool = false
    @State private var copiedCurl: Bool = false
    @State private var copiedURL: Bool = false
    @State private var isTestingRequest: Bool = false
    @State private var testResponseOutput: String? = nil

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

    private var sampleCurlCommand: String {
        """
        curl \(serverManager.localhostURLString)/chat/completions \\
          -H "Content-Type: application/json" \\
          -d '{
            "model": "\(serverManager.defaultModelID.isEmpty ? "default" : serverManager.defaultModelID)",
            "messages": [{"role": "user", "content": "Hello Locally!"}],
            "stream": true
          }'
        """
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: activeColors,
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Bar
                topBar

                ScrollView {
                    VStack(spacing: 16) {
                        // Server Status & Power Card
                        serverStatusCard

                        // Configuration & Security Card
                        configurationCard

                        // Developer Testing & Integration Card
                        developerIntegrationCard

                        // Live Request Activity & Error Log Card
                        activityLogCard
                    }
                    .padding(20)
                }
            }
        }
        .onAppear {
            chatViewModel.scanInstalledModels()
            serverManager.updateAvailableModels(chatViewModel.installedModels)
            portString = String(serverManager.port)
        }
        .alert("Allow Local Network Access?", isPresented: $showLANWarningAlert) {
            Button("Enable LAN Access", role: .destructive) {
                serverManager.allowLocalNetworkAccess = true
                if serverManager.isRunning {
                    serverManager.stopServer()
                    serverManager.startServer()
                }
            }
            Button("Cancel", role: .cancel) {
                serverManager.allowLocalNetworkAccess = false
            }
        } message: {
            Text("Binding to 0.0.0.0 allows any device on your local Wi-Fi or LAN to send prompts and execute models on your Mac. Ensure your network is trusted.")
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

            Text("Local OpenAI-Compatible API Server")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            Spacer()

            // Status Indicator Pill
            HStack(spacing: 6) {
                Circle()
                    .fill(serverManager.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(serverManager.isRunning ? "RUNNING" : "STOPPED")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .liquidGlass(.capsule, isClear: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: - Status & Power Card

    private var serverStatusCard: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("API Endpoint")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                    if serverManager.isRunning {
                        Text("Ready for requests")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }

                Text(serverManager.localhostURLString)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)

                Text(serverManager.allowLocalNetworkAccess ? "Listening on all network interfaces (0.0.0.0)" : "Bound to localhost loopback (127.0.0.1)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            // Copy Base URL Button
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(serverManager.localhostURLString, forType: .string)
                copiedURL = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copiedURL = false
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copiedURL ? "checkmark" : "doc.on.doc")
                    Text(copiedURL ? "Copied" : "Copy URL")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .liquidGlass(.capsule, isClear: true)
            }
            .buttonStyle(.plain)

            // Start / Stop Toggle Button
            Button {
                if serverManager.isRunning {
                    serverManager.stopServer()
                } else {
                    if let portNum = Int(portString), portNum > 0 && portNum < 65535 {
                        serverManager.port = portNum
                    }
                    serverManager.startServer()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: serverManager.isRunning ? "stop.fill" : "play.fill")
                    Text(serverManager.isRunning ? "Stop Server" : "Start Server")
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(serverManager.isRunning ? Color.red : Color.green)
                .clipShape(.capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .liquidGlass(.rect(cornerRadius: 16))
    }

    // MARK: - Configuration & Security Card

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Configuration & Network Security")
                .font(.headline)
                .foregroundStyle(.white)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                // Port Setting
                GridRow {
                    Text("Port")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))

                    HStack {
                        TextField("Port", text: $portString)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 80)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .liquidGlass(.rect(cornerRadius: 8), isClear: true)
                            .onChange(of: portString) { _, newVal in
                                if let p = Int(newVal) {
                                    serverManager.port = p
                                }
                            }
                        Text("Standard local ports: 1234, 8080, 11434")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                // Default Model Setting
                GridRow {
                    Text("Default Model")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))

                    Picker("", selection: $serverManager.defaultModelID) {
                        if serverManager.availableModels.isEmpty {
                            Text("No installed models found").tag("")
                        } else {
                            ForEach(serverManager.availableModels, id: \.self) { modelId in
                                Text(modelId.replacingOccurrences(of: "mlx-community/", with: "")).tag(modelId)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320)
                }

                // Network Security Scope Toggle
                GridRow {
                    Text("Network Access")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Expose to Local Network (0.0.0.0)", isOn: Binding(
                            get: { serverManager.allowLocalNetworkAccess },
                            set: { newVal in
                                if newVal {
                                    showLANWarningAlert = true
                                } else {
                                    serverManager.allowLocalNetworkAccess = false
                                    if serverManager.isRunning {
                                        serverManager.stopServer()
                                        serverManager.startServer()
                                    }
                                }
                            }
                        ))
                        .font(.subheadline)
                        .foregroundStyle(.white)

                        Text("Default: Localhost only (127.0.0.1). When enabled, other machines, Docker containers, or phones on your Wi-Fi can query your Mac.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                // Bearer token (required hygiene for network exposure)
                GridRow {
                    Text("API Token")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))

                    VStack(alignment: .leading, spacing: 4) {
                        SecureField("Optional — required if you expose the server", text: Binding(
                            get: { serverManager.apiToken },
                            set: { serverManager.apiToken = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)

                        Text(serverManager.apiToken.isEmpty
                            ? "No token set: anyone who can reach the port can use your models. Set a token before enabling network access — clients send it as 'Authorization: Bearer <token>'."
                            : "Token required on every request (Authorization: Bearer …).")
                            .font(.caption)
                            .foregroundStyle(serverManager.apiToken.isEmpty && serverManager.allowLocalNetworkAccess ? .orange : .white.opacity(0.6))
                    }
                }
            }
        }
        .padding(16)
        .liquidGlass(.rect(cornerRadius: 16))
    }

    // MARK: - Developer Testing & Integration Card

    private var developerIntegrationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("OpenAI SDK & cURL Integration")
                    .font(.headline)
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sampleCurlCommand, forType: .string)
                    copiedCurl = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copiedCurl = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copiedCurl ? "checkmark" : "doc.on.doc")
                        Text(copiedCurl ? "Copied Command" : "Copy cURL")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .liquidGlass(.capsule, isClear: true)
                }
                .buttonStyle(.plain)

                // In-App Test Button
                Button {
                    runInAppTest()
                } label: {
                    HStack(spacing: 5) {
                        if isTestingRequest {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "play.circle.fill")
                        }
                        Text("Send Test Ping")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue)
                    .clipShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(!serverManager.isRunning || isTestingRequest)
            }

            // Command Snippet
            ScrollView(.horizontal, showsIndicators: false) {
                Text(sampleCurlCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(12)
                    .background(Color.black.opacity(0.3))
                    .clipShape(.rect(cornerRadius: 8))
            }

            if let testOutput = testResponseOutput {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Test Response:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(testOutput)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.green)
                        .padding(8)
                        .background(Color.black.opacity(0.4))
                        .clipShape(.rect(cornerRadius: 6))
                }
            }

            // Client snippet hint
            Text("Compatible with: LangChain, LlamaIndex, Continue.dev, Cursor, Open WebUI, and official `openai` Python/TypeScript packages (`base_url=\"\(serverManager.localhostURLString)\"`, `api_key=\"locally\"`).")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding(16)
        .liquidGlass(.rect(cornerRadius: 16))
    }

    // MARK: - Activity & Error Log Card

    private var activityLogCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Live Request & Error Logs")
                    .font(.headline)
                    .foregroundStyle(.white)

                Spacer()

                Text("\(serverManager.totalRequestsServed) requests served")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))

                if !serverManager.logs.isEmpty {
                    Button("Clear") {
                        serverManager.clearLogs()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                }
            }

            if serverManager.logs.isEmpty {
                VStack(spacing: 6) {
                    Text("No API requests recorded yet.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Send a request to \(serverManager.localhostURLString)/chat/completions to see live telemetry.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 6) {
                    ForEach(serverManager.logs.prefix(25)) { log in
                        HStack(spacing: 10) {
                            Text(log.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))

                            Text(log.method)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(log.method == "POST" ? .cyan : .green)

                            Text(log.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.9))

                            Spacer()

                            if log.isStream {
                                Text("SSE")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.purple.opacity(0.3))
                                    .clipShape(.capsule)
                            }

                            if log.tokensGenerated > 0 {
                                Text("\(log.tokensGenerated) tok")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.7))
                            }

                            Text("\(log.latencyMs)ms")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))

                            Text("\(log.statusCode)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(log.statusCode == 200 ? .green : .red)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.04))
                        .clipShape(.rect(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(16)
        .liquidGlass(.rect(cornerRadius: 16))
    }

    // MARK: - Testing Ping

    private func runInAppTest() {
        guard let url = URL(string: "\(serverManager.localhostURLString)/models") else { return }
        isTestingRequest = true
        testResponseOutput = "Pinging \(url.absoluteString)..."

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    testResponseOutput = "HTTP \(http.statusCode):\n\(body)"
                }
            } catch {
                testResponseOutput = "Ping Failed: \(error.localizedDescription)"
            }
            isTestingRequest = false
        }
    }
}
