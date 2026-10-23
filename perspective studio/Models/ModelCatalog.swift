import Foundation
import SwiftUI

enum ModelCatalogBadge: String, CaseIterable, Identifiable, Sendable {
    case new = "New"
    case thinking = "Thinking"
    case vision = "Vision"
    case recommended = "Recommended"
    case code = "Code"
    case tools = "Tools"

    var id: String { rawValue }

    var title: String { rawValue }

    var icon: String {
        switch self {
        case .new: "sparkles"
        case .thinking: "lightbulb.fill"
        case .vision: "eye.fill"
        case .recommended: "checkmark.seal.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .tools: "wrench.and.screwdriver.fill"
        }
    }

    var color: Color {
        switch self {
        case .new: Color(hex: "F39C12") ?? .orange
        case .thinking: Color(hex: "D05CE3") ?? .purple
        case .vision: Color(hex: "E6B800") ?? .yellow
        case .recommended: Color(hex: "27AE60") ?? .green
        case .code: Color(hex: "3498DB") ?? .blue
        case .tools: Color(hex: "E67E22") ?? .orange
        }
    }
}

struct ModelCatalogVariant: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let description: String
    let sizeFormatted: String
    let ramFormatted: String
    let badges: [ModelCatalogBadge]
    let rawModel: HFModel

    static func == (lhs: ModelCatalogVariant, rhs: ModelCatalogVariant) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct ModelFamily: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let icon: String
    let provider: ModelProvider
    let description: String
    let badges: [ModelCatalogBadge]
    let variants: [ModelCatalogVariant]

    var modelCount: Int { variants.count }

    static func == (lhs: ModelFamily, rhs: ModelFamily) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

@Observable
@MainActor
final class ModelCatalog {
    static let shared = ModelCatalog()

    var families: [ModelFamily] = []
    var isLoading: Bool = false
    var lastError: String? = nil

    init() {
        // Initialize with default template families and trigger API fetch
        self.families = Self.initialSeedFamilies()
        Task {
            await fetchCatalogFromAPI()
        }
    }

    func fetchCatalogFromAPI(forceRefresh: Bool = false) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let hfModels = try await HuggingFaceService.shared.fetchMLXModels(forceRefresh: forceRefresh)
            let built = Self.buildFamiliesFromAPI(models: hfModels)
            if !built.isEmpty {
                self.families = built
            }
        } catch {
            self.lastError = error.localizedDescription
            if self.families.isEmpty {
                self.families = Self.initialSeedFamilies()
            }
        }
    }

    // MARK: - Dynamic API Builder

    static func buildFamiliesFromAPI(models: [HFModel]) -> [ModelFamily] {
        // Family definitions mapped to detection patterns
        struct FamilyDefinition {
            let id: String
            let name: String
            let icon: String
            let provider: ModelProvider
            let description: String
            let defaultBadges: [ModelCatalogBadge]
            let keywords: [String]
        }

        let definitions: [FamilyDefinition] = [
            FamilyDefinition(
                id: "qwen",
                name: "Qwen",
                icon: "sparkle",
                provider: .qwen,
                description: "State-of-the-art multilingual and reasoning models by Alibaba Cloud.",
                defaultBadges: [.new, .thinking, .code],
                keywords: ["qwen", "qwq"]
            ),
            FamilyDefinition(
                id: "gemma",
                name: "Gemma 4",
                icon: "diamond.fill",
                provider: .gemma,
                description: "Open models built from Google DeepMind Gemini research and technology.",
                defaultBadges: [.new, .thinking, .vision],
                keywords: ["gemma", "paligemma"]
            ),
            FamilyDefinition(
                id: "lfm",
                name: "LFM 2.5",
                icon: "drop.fill",
                provider: .other,
                description: "Next-gen hybrid neural network models developed by Liquid AI for on-device deployment.",
                defaultBadges: [.new, .vision, .recommended],
                keywords: ["lfm", "liquid"]
            ),
            FamilyDefinition(
                id: "minicpm",
                name: "MiniCPM 5",
                icon: "cube.fill",
                provider: .other,
                description: "Efficient on-device models by OpenBMB optimized for language and multimodal tasks.",
                defaultBadges: [.new, .thinking],
                keywords: ["minicpm"]
            ),
            FamilyDefinition(
                id: "deepseek",
                name: "DeepSeek R1",
                icon: "brain.head.profile",
                provider: .deepseek,
                description: "High-capability reasoning and coding models with advanced chain-of-thought distillation.",
                defaultBadges: [.thinking, .code, .recommended],
                keywords: ["deepseek", "r1"]
            ),
            FamilyDefinition(
                id: "mistral",
                name: "Mistral",
                icon: "wind",
                provider: .mistral,
                description: "High-performance European open weights engineered for reasoning, code, and speed.",
                defaultBadges: [.code, .recommended],
                keywords: ["mistral", "mixtral", "codestral", "pixtral"]
            ),
            FamilyDefinition(
                id: "llama",
                name: "Llama 3.3",
                icon: "flame.fill",
                provider: .llama,
                description: "Meta's flagship open-weights architecture with world-class instruction tuning.",
                defaultBadges: [.tools, .recommended],
                keywords: ["llama"]
            ),
            FamilyDefinition(
                id: "phi",
                name: "Microsoft Phi",
                icon: "apple.terminal",
                provider: .phi,
                description: "Ultra-compact small language models trained on synthetic textbooks and reasoning datasets.",
                defaultBadges: [.thinking, .code],
                keywords: ["phi"]
            ),
            FamilyDefinition(
                id: "bonsai",
                name: "Bonsai",
                icon: "leaf.fill",
                provider: .other,
                description: "Ultra-efficient models from PrismML tuned for real-time edge processing.",
                defaultBadges: [.new, .thinking, .vision],
                keywords: ["bonsai"]
            )
        ]

        var result: [ModelFamily] = []

        for def in definitions {
            // Filter all HF models matching keywords
            let matchedModels = models.filter { model in
                let lower = model.displayName.lowercased()
                return def.keywords.contains { kw in lower.contains(kw) }
            }

            guard !matchedModels.isEmpty else { continue }

            // Transform HFModel records into dynamic ModelCatalogVariant
            let variants: [ModelCatalogVariant] = matchedModels.prefix(12).map { model in
                let name = model.displayName
                let (sizeStr, ramStr) = estimateSizeAndRAM(from: name)
                let badges = deriveBadges(from: model, defaultBadges: def.defaultBadges)
                let desc = generateDescription(for: name, pipeline: model.pipelineTag)

                return ModelCatalogVariant(
                    id: model.id,
                    name: formatVariantName(model.id),
                    description: desc,
                    sizeFormatted: sizeStr,
                    ramFormatted: ramStr,
                    badges: badges,
                    rawModel: model
                )
            }

            let familyBadges = Array(Set(variants.flatMap { $0.badges })).sorted { $0.title < $1.title }

            result.append(
                ModelFamily(
                    id: def.id,
                    name: def.name,
                    icon: def.icon,
                    provider: def.provider,
                    description: def.description,
                    badges: familyBadges.isEmpty ? def.defaultBadges : familyBadges,
                    variants: variants
                )
            )
        }

        return result
    }

    private static func formatVariantName(_ id: String) -> String {
        let clean = id.replacingOccurrences(of: "mlx-community/", with: "")
        return clean.replacingOccurrences(of: "-", with: " ")
    }

    private static func estimateSizeAndRAM(from name: String) -> (String, String) {
        let lower = name.lowercased()
        if lower.contains("70b") || lower.contains("72b") {
            return ("39.5 GB", "48.0 GB RAM")
        } else if lower.contains("32b") || lower.contains("35b") {
            return ("18.4 GB", "24.0 GB RAM")
        } else if lower.contains("27b") {
            return ("16.2 GB", "20.5 GB RAM")
        } else if lower.contains("14b") {
            return ("8.9 GB", "12.0 GB RAM")
        } else if lower.contains("8b") || lower.contains("9b") {
            return ("4.9 GB", "6.8 GB RAM")
        } else if lower.contains("7b") {
            return ("4.3 GB", "6.0 GB RAM")
        } else if lower.contains("3b") || lower.contains("4b") {
            return ("2.4 GB", "3.6 GB RAM")
        } else if lower.contains("1.5b") || lower.contains("2b") {
            return ("1.4 GB", "2.1 GB RAM")
        } else if lower.contains("0.5b") || lower.contains("0.6b") || lower.contains("450m") {
            return ("480 MB", "1.1 GB RAM")
        }
        return ("3.8 GB", "5.2 GB RAM")
    }

    private static func deriveBadges(from model: HFModel, defaultBadges: [ModelCatalogBadge]) -> [ModelCatalogBadge] {
        var badges = Set<ModelCatalogBadge>()
        let nameLower = model.displayName.lowercased()
        let tagsLower = model.tags.map { $0.lowercased() }

        if nameLower.contains("r1") || nameLower.contains("qwq") || nameLower.contains("think") || nameLower.contains("reason") {
            badges.insert(.thinking)
        }
        if nameLower.contains("vl") || nameLower.contains("vision") || tagsLower.contains("image-text-to-text") {
            badges.insert(.vision)
        }
        if nameLower.contains("coder") || nameLower.contains("code") || tagsLower.contains("code") {
            badges.insert(.code)
        }
        if nameLower.contains("tool") || nameLower.contains("instruct") {
            badges.insert(.tools)
        }
        if model.downloads > 5000 {
            badges.insert(.recommended)
        }
        badges.insert(.new)

        if badges.isEmpty {
            return defaultBadges
        }
        return Array(badges)
    }

    private static func generateDescription(for name: String, pipeline: String?) -> String {
        let lower = name.lowercased()
        if lower.contains("vision") || lower.contains("vl") {
            return "Vision-language model capable of analyzing images, documents, and answering visual questions."
        } else if lower.contains("coder") || lower.contains("code") {
            return "Specialized for programming, code completion, refactoring, and technical reasoning."
        } else if lower.contains("r1") || lower.contains("qwq") || lower.contains("reason") {
            return "Reasoning-tuned architecture with step-by-step thinking for math, logic, and deep analysis."
        } else {
            return "General-purpose instruction model for conversational chat, summarization, and task execution."
        }
    }

    // Initial placeholder seeds while the HuggingFace API call resolves
    private static func initialSeedFamilies() -> [ModelFamily] {
        [
            ModelFamily(
                id: "qwen",
                name: "Qwen",
                icon: "sparkle",
                provider: .qwen,
                description: "State-of-the-art multilingual and reasoning models by Alibaba Cloud.",
                badges: [.new, .thinking, .code],
                variants: [
                    ModelCatalogVariant(
                        id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
                        name: "Qwen 2.5 7B Instruct",
                        description: "High-accuracy open instruction model with strong coding, math, and multilingual abilities.",
                        sizeFormatted: "4.3 GB",
                        ramFormatted: "6.0 GB RAM",
                        badges: [.new, .code, .recommended],
                        rawModel: HFModel(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", name: "Qwen2.5-7B-Instruct-4bit", downloads: 54000, likes: 1200, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                    ),
                    ModelCatalogVariant(
                        id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
                        name: "Qwen 2.5 Coder 7B",
                        description: "Code intelligence specialist benchmarked against top-tier programming models.",
                        sizeFormatted: "4.3 GB",
                        ramFormatted: "6.0 GB RAM",
                        badges: [.code, .tools],
                        rawModel: HFModel(id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit", name: "Qwen2.5-Coder-7B-Instruct-4bit", downloads: 41000, likes: 980, tags: ["code"], pipelineTag: "text-generation", createdAt: nil)
                    )
                ]
            ),
            ModelFamily(
                id: "gemma",
                name: "Gemma 4",
                icon: "diamond.fill",
                provider: .gemma,
                description: "Open models built from Google DeepMind Gemini research and technology.",
                badges: [.new, .thinking, .vision],
                variants: [
                    ModelCatalogVariant(
                        id: "mlx-community/gemma-2-2b-it-4bit",
                        name: "Gemma 2 2B Instruct",
                        description: "Lightweight conversational model with rapid latency on Apple Silicon.",
                        sizeFormatted: "1.6 GB",
                        ramFormatted: "2.1 GB RAM",
                        badges: [.new, .recommended],
                        rawModel: HFModel(id: "mlx-community/gemma-2-2b-it-4bit", name: "gemma-2-2b-it-4bit", downloads: 32000, likes: 850, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                    ),
                    ModelCatalogVariant(
                        id: "mlx-community/gemma-2-9b-it-4bit",
                        name: "Gemma 2 9B Instruct",
                        description: "Flagship Google open weights offering high factual precision.",
                        sizeFormatted: "5.4 GB",
                        ramFormatted: "7.2 GB RAM",
                        badges: [.new, .thinking],
                        rawModel: HFModel(id: "mlx-community/gemma-2-9b-it-4bit", name: "gemma-2-9b-it-4bit", downloads: 48000, likes: 1100, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                    )
                ]
            ),
            ModelFamily(
                id: "deepseek",
                name: "DeepSeek R1",
                icon: "brain.head.profile",
                provider: .deepseek,
                description: "High-capability reasoning and coding models with advanced chain-of-thought distillation.",
                badges: [.thinking, .code, .recommended],
                variants: [
                    ModelCatalogVariant(
                        id: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit",
                        name: "DeepSeek R1 Distill Qwen 7B",
                        description: "Reasoning distilled model that explores deep analytical steps before concluding.",
                        sizeFormatted: "4.4 GB",
                        ramFormatted: "6.2 GB RAM",
                        badges: [.thinking, .recommended],
                        rawModel: HFModel(id: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit", name: "DeepSeek-R1-Distill-Qwen-7B-4bit", downloads: 98000, likes: 3200, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                    ),
                    ModelCatalogVariant(
                        id: "mlx-community/DeepSeek-R1-Distill-Llama-8B-4bit",
                        name: "DeepSeek R1 Distill Llama 8B",
                        description: "Meta Llama backbone augmented with DeepSeek reasoning traces.",
                        sizeFormatted: "4.9 GB",
                        ramFormatted: "6.8 GB RAM",
                        badges: [.thinking, .code],
                        rawModel: HFModel(id: "mlx-community/DeepSeek-R1-Distill-Llama-8B-4bit", name: "DeepSeek-R1-Distill-Llama-8B-4bit", downloads: 64000, likes: 2100, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                    )
                ]
            )
        ]
    }
}

// Backwards-compatible struct so existing view references compile seamlessly
struct ModelCatalogData {
    static var featuredFamilies: [ModelFamily] {
        ModelCatalog.shared.families
    }
}
