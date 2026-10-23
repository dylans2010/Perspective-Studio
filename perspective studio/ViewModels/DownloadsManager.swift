import Foundation
import SwiftUI
import AppKit

enum ModelProvider: String, CaseIterable, Identifiable, Sendable {
    case qwen = "Qwen"
    case gemma = "Gemma"
    case mistral = "Mistral"
    case deepseek = "DeepSeek"
    case llama = "Llama"
    case phi = "Microsoft Phi"
    case apple = "Apple"
    case other = "Community"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .qwen: "sparkle"
        case .gemma: "diamond.fill"
        case .mistral: "wind"
        case .deepseek: "brain.head.profile"
        case .llama: "flame.fill"
        case .phi: "apple.terminal"
        case .apple: "apple.logo"
        case .other: "globe"
        }
    }

    var brandColor: Color {
        switch self {
        case .qwen: .orange
        case .gemma: .blue
        case .mistral: .purple
        case .deepseek: .indigo
        case .llama: .cyan
        case .phi: .teal
        case .apple: .gray
        case .other: .secondary
        }
    }

    static func identify(for model: HFModel) -> ModelProvider {
        let name = model.displayName.lowercased()
        if name.contains("qwen") || name.contains("qwq") {
            return .qwen
        } else if name.contains("gemma") || name.contains("paligemma") {
            return .gemma
        } else if name.contains("mistral") || name.contains("mixtral") || name.contains("codestral") || name.contains("pixtral") {
            return .mistral
        } else if name.contains("deepseek") {
            return .deepseek
        } else if name.contains("llama") {
            return .llama
        } else if name.contains("phi") {
            return .phi
        } else if name.contains("openelm") || name.contains("apple") {
            return .apple
        } else {
            return .other
        }
    }
}

enum ModelCapability: String, CaseIterable, Identifiable, Sendable {
    case tools = "Tools"
    case vision = "Vision"
    case thinking = "Thinking"
    case code = "Code"
    case chat = "Chat"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .tools: "wrench.and.screwdriver.fill"
        case .vision: "eye.fill"
        case .thinking: "brain"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .chat: "bubble.left.and.bubble.right.fill"
        }
    }

    var color: Color {
        switch self {
        case .tools: .orange
        case .vision: .purple
        case .thinking: .pink
        case .code: .blue
        case .chat: .green
        }
    }
}

struct ManagedHFModel: Identifiable, Hashable {
    let rawModel: HFModel
    let provider: ModelProvider
    let capabilities: [ModelCapability]

    var id: String { rawModel.id }
    var displayName: String { rawModel.displayName }
    var downloads: Int { rawModel.downloads }
    var likes: Int { rawModel.likes }
    var parameterSize: Double? { rawModel.parameterSize }
    var quantization: String? { rawModel.quantization }
    var estimatedRAMGB: Double? { rawModel.estimatedRAMGB }

    var sizeFormatted: String {
        if let params = parameterSize {
            return params >= 1 ? "\(params.formatted(.number.precision(.fractionLength(1))))B" : "\(Int(params * 1000))M"
        }
        return "Unknown"
    }

    var ramFormatted: String {
        if let ram = estimatedRAMGB {
            return "\(ram.formatted(.number.precision(.fractionLength(1)))) GB RAM"
        }
        return "Unknown RAM"
    }

    var isDownloaded: Bool {
        rawModel.isDownloaded
    }

    static func build(from model: HFModel) -> ManagedHFModel {
        let provider = ModelProvider.identify(for: model)
        var caps: [ModelCapability] = []

        let nameLower = model.displayName.lowercased()
        let tagsLower = model.tags.map { $0.lowercased() }

        // Vision
        if model.category == .vision || model.category == .video || tagsLower.contains("image-text-to-text") || nameLower.contains("vision") || nameLower.contains("vl") || nameLower.contains("pixtral") {
            caps.append(.vision)
        }

        // Thinking / Reasoning
        if model.category == .reasoning || nameLower.contains("r1") || nameLower.contains("qwq") || nameLower.contains("thinking") || nameLower.contains("reasoning") {
            caps.append(.thinking)
        }

        // Code
        if model.category == .code || nameLower.contains("code") || nameLower.contains("coder") || nameLower.contains("starcoder") {
            caps.append(.code)
        }

        // Tools
        if tagsLower.contains("tools") || tagsLower.contains("function-calling") || nameLower.contains("tool") || nameLower.contains("instruct") || nameLower.contains("qwen2.5") {
            caps.append(.tools)
        }

        // Chat
        if model.category == .chat || tagsLower.contains("conversational") || nameLower.contains("instruct") || nameLower.contains("chat") {
            caps.append(.chat)
        }

        if caps.isEmpty {
            caps.append(.chat)
        }

        return ManagedHFModel(rawModel: model, provider: provider, capabilities: caps)
    }
}

@Observable @MainActor
final class DownloadsManager {
    static let shared = DownloadsManager()

    var allModels: [ManagedHFModel] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var selectedCapabilityFilter: ModelCapability?
    var searchQuery: String = ""

    var groupedByProvider: [(provider: ModelProvider, models: [ManagedHFModel])] {
        let filtered = filteredModels
        var dict: [ModelProvider: [ManagedHFModel]] = [:]
        for model in filtered {
            dict[model.provider, default: []].append(model)
        }

        return ModelProvider.allCases.compactMap { prov in
            guard let models = dict[prov], !models.isEmpty else { return nil }
            return (prov, models)
        }
    }

    var filteredModels: [ManagedHFModel] {
        allModels.filter { model in
            let matchesSearch: Bool
            if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                matchesSearch = true
            } else {
                matchesSearch = model.displayName.localizedStandardContains(searchQuery)
                    || model.provider.rawValue.localizedStandardContains(searchQuery)
            }

            let matchesCapability: Bool
            if let cap = selectedCapabilityFilter {
                matchesCapability = model.capabilities.contains(cap)
            } else {
                matchesCapability = true
            }

            return matchesSearch && matchesCapability
        }
    }

    func fetchModelsFromHF(forceRefresh: Bool = false) async {
        isLoading = true
        errorMessage = nil
        do {
            let rawList = try await HuggingFaceService.shared.fetchMLXModels(forceRefresh: forceRefresh)
            self.allModels = rawList.map { ManagedHFModel.build(from: $0) }
        } catch {
            self.errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
