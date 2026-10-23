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

struct ModelCatalogData {
    static let featuredFamilies: [ModelFamily] = [
        ModelFamily(
            id: "bonsai",
            name: "Bonsai",
            icon: "leaf.fill",
            provider: .other,
            description: "A new class of ultra-efficient models from PrismML. Built for performance where it matters most: on-device and in real time.",
            badges: [.new, .thinking, .vision],
            variants: [
                ModelCatalogVariant(
                    id: "mlx-community/Bonsai-3B-Instruct-4bit",
                    name: "Bonsai 3B Instruct",
                    description: "Ultra-compact reasoning and multi-turn instruction model. Optimized for Apple Silicon real-time response.",
                    sizeFormatted: "1.92 GB",
                    ramFormatted: "2.4 GB RAM",
                    badges: [.new, .thinking, .recommended],
                    rawModel: HFModel(id: "mlx-community/Bonsai-3B-Instruct-4bit", name: "Bonsai-3B-Instruct-4bit", downloads: 12000, likes: 450, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/Bonsai-1.5B-VL-4bit",
                    name: "Bonsai 1.5B VL",
                    description: "High-speed multimodal vision model capable of image question answering with minimal memory overhead.",
                    sizeFormatted: "1.10 GB",
                    ramFormatted: "1.6 GB RAM",
                    badges: [.new, .vision],
                    rawModel: HFModel(id: "mlx-community/Bonsai-1.5B-VL-4bit", name: "Bonsai-1.5B-VL-4bit", downloads: 8500, likes: 310, tags: ["image-text-to-text"], pipelineTag: "image-text-to-text", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/Bonsai-7B-Reasoning-4bit",
                    name: "Bonsai 7B Reasoning",
                    description: "Expanded parameter flagship for in-depth chain-of-thought analysis, math, and code synthesis.",
                    sizeFormatted: "4.45 GB",
                    ramFormatted: "5.8 GB RAM",
                    badges: [.new, .thinking],
                    rawModel: HFModel(id: "mlx-community/Bonsai-7B-Reasoning-4bit", name: "Bonsai-7B-Reasoning-4bit", downloads: 15400, likes: 620, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                )
            ]
        ),
        ModelFamily(
            id: "gemma-4",
            name: "Gemma 4",
            icon: "sparkle",
            provider: .gemma,
            description: "The latest generation of open models from Google. Optimized for multi-turn chat, image understanding, and advanced reasoning.",
            badges: [.new, .thinking, .vision],
            variants: [
                ModelCatalogVariant(
                    id: "mlx-community/gemma-2-2b-it-4bit",
                    name: "Gemma 2 2B Instruct",
                    description: "Google's lightweight model designed for exceptional general knowledge, conversational flow, and low-latency interaction.",
                    sizeFormatted: "1.60 GB",
                    ramFormatted: "2.1 GB RAM",
                    badges: [.new, .recommended],
                    rawModel: HFModel(id: "mlx-community/gemma-2-2b-it-4bit", name: "gemma-2-2b-it-4bit", downloads: 48000, likes: 920, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/gemma-2-9b-it-4bit",
                    name: "Gemma 2 9B Instruct",
                    description: "Google's balanced powerhouse, matching previous generation flagship models in reasoning and coding benchmarks.",
                    sizeFormatted: "5.40 GB",
                    ramFormatted: "6.8 GB RAM",
                    badges: [.thinking],
                    rawModel: HFModel(id: "mlx-community/gemma-2-9b-it-4bit", name: "gemma-2-9b-it-4bit", downloads: 82000, likes: 1400, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/paligemma-3b-pt-448-4bit",
                    name: "PaliGemma 3B Vision",
                    description: "Versatile vision-language model for image captioning, object detection, and visual question answering.",
                    sizeFormatted: "2.10 GB",
                    ramFormatted: "3.2 GB RAM",
                    badges: [.vision],
                    rawModel: HFModel(id: "mlx-community/paligemma-3b-pt-448-4bit", name: "paligemma-3b-pt-448-4bit", downloads: 29000, likes: 670, tags: ["image-text-to-text"], pipelineTag: "image-text-to-text", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/codegemma-7b-it-4bit",
                    name: "CodeGemma 7B Instruct",
                    description: "Specialized model trained on extensive code repositories for synthesis, bug-fixing, and technical documentation.",
                    sizeFormatted: "4.30 GB",
                    ramFormatted: "5.6 GB RAM",
                    badges: [.code],
                    rawModel: HFModel(id: "mlx-community/codegemma-7b-it-4bit", name: "codegemma-7b-it-4bit", downloads: 35000, likes: 810, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                )
            ]
        ),
        ModelFamily(
            id: "lfm-2.5",
            name: "LFM 2.5",
            icon: "drop.fill",
            provider: .other,
            description: "A new generation of hybrid models developed by Liquid AI. Improved performance compared to LFM 2 and designed for on-device deployment.",
            badges: [.new, .vision, .recommended, .thinking],
            variants: [
                ModelCatalogVariant(
                    id: "mlx-community/LFM-2.5-3B-VL-4bit",
                    name: "LFM 2.5 VL (3B)",
                    description: "A model from Liquid AI. Good for answering questions about images, reading text in photos, and understanding documents in multiple languages. Recommended for Mac with M1 or newer.",
                    sizeFormatted: "2.39 GB",
                    ramFormatted: "3.1 GB RAM",
                    badges: [.new, .vision, .recommended],
                    rawModel: HFModel(id: "mlx-community/LFM-2.5-3B-VL-4bit", name: "LFM-2.5-3B-VL-4bit", downloads: 31000, likes: 890, tags: ["image-text-to-text"], pipelineTag: "image-text-to-text", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/LFM-2.5-1.6B-VL-4bit",
                    name: "LFM 2.5 VL (1.6B)",
                    description: "An updated vision-language model from Liquid AI. Enhanced performance over LFM 2 VL with improved multilingual vision understanding. Recommended for Mac with M1 or newer.",
                    sizeFormatted: "1.50 GB",
                    ramFormatted: "2.0 GB RAM",
                    badges: [.vision],
                    rawModel: HFModel(id: "mlx-community/LFM-2.5-1.6B-VL-4bit", name: "LFM-2.5-1.6B-VL-4bit", downloads: 19000, likes: 420, tags: ["image-text-to-text"], pipelineTag: "image-text-to-text", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/LFM-2.5-450M-VL-4bit",
                    name: "LFM 2.5 VL (450M)",
                    description: "A compact vision-language model from Liquid AI. Built on the LFM 2.5 backbone with stronger multilingual image understanding. Great for Shortcut use. Recommended for Mac with M1 or newer.",
                    sizeFormatted: "471 MB",
                    ramFormatted: "0.8 GB RAM",
                    badges: [.vision],
                    rawModel: HFModel(id: "mlx-community/LFM-2.5-450M-VL-4bit", name: "LFM-2.5-450M-VL-4bit", downloads: 14000, likes: 310, tags: ["image-text-to-text"], pipelineTag: "image-text-to-text", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/LFM-2.5-8B-A1B-4bit",
                    name: "LFM 2.5 (8B A1B)",
                    description: "A reasoning-tuned hybrid model from Liquid AI with 8.3B total parameters and 1.5B active. Designed for on-device assistants, instruction following, math, and multilingual chat. Recommended for Mac with M2 or newer.",
                    sizeFormatted: "4.79 GB",
                    ramFormatted: "6.0 GB RAM",
                    badges: [.new, .thinking],
                    rawModel: HFModel(id: "mlx-community/LFM-2.5-8B-A1B-4bit", name: "LFM-2.5-8B-A1B-4bit", downloads: 27000, likes: 780, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/LFM-2.5-2.6B-4bit",
                    name: "LFM 2.5 (2.6B)",
                    description: "Latest 2.6B parameter model from Liquid AI. Designed for general-purpose chat, data extraction, RAG, creative writing, and summarization.",
                    sizeFormatted: "1.74 GB",
                    ramFormatted: "2.3 GB RAM",
                    badges: [.recommended],
                    rawModel: HFModel(id: "mlx-community/LFM-2.5-2.6B-4bit", name: "LFM-2.5-2.6B-4bit", downloads: 22000, likes: 510, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                )
            ]
        ),
        ModelFamily(
            id: "minicpm-5",
            name: "MiniCPM 5",
            icon: "cpu.fill",
            provider: .other,
            description: "Lightweight models from OpenBMB. Good for everyday conversations in English and Chinese, coding, and problem-solving.",
            badges: [.new, .thinking],
            variants: [
                ModelCatalogVariant(
                    id: "mlx-community/MiniCPM-3-4B-4bit",
                    name: "MiniCPM 3 (4B)",
                    description: "Strong English and bilingual reasoning engine outperforming many 7B and 13B models in common benchmarks.",
                    sizeFormatted: "2.40 GB",
                    ramFormatted: "3.2 GB RAM",
                    badges: [.new, .thinking],
                    rawModel: HFModel(id: "mlx-community/MiniCPM-3-4B-4bit", name: "MiniCPM-3-4B-4bit", downloads: 18000, likes: 490, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/MiniCPM-V-2_6-4bit",
                    name: "MiniCPM-V 2.6",
                    description: "SOTA edge multimodal model handling images and video streams with OCR and spatial reasoning.",
                    sizeFormatted: "4.80 GB",
                    ramFormatted: "6.2 GB RAM",
                    badges: [.vision],
                    rawModel: HFModel(id: "mlx-community/MiniCPM-V-2_6-4bit", name: "MiniCPM-V-2_6-4bit", downloads: 41000, likes: 1120, tags: ["image-text-to-text"], pipelineTag: "image-text-to-text", createdAt: nil)
                )
            ]
        ),
        ModelFamily(
            id: "qwen-3",
            name: "Qwen 2.5 & 3",
            icon: "sparkles",
            provider: .qwen,
            description: "High-capability foundation and coding models from Alibaba Cloud, supporting extensive languages, tool-use, and math.",
            badges: [.new, .code, .thinking, .vision, .tools],
            variants: [
                ModelCatalogVariant(
                    id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
                    name: "Qwen 2.5 7B Instruct",
                    description: "Versatile, highly capable instruction-following foundation model with 128k context support and strong multilingual competence.",
                    sizeFormatted: "4.68 GB",
                    ramFormatted: "5.8 GB RAM",
                    badges: [.new, .recommended, .tools],
                    rawModel: HFModel(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", name: "Qwen2.5-7B-Instruct-4bit", downloads: 95000, likes: 2100, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
                    name: "Qwen 2.5 Coder 7B",
                    description: "Dedicated coding specialist matching GPT-4o in Python, Swift, TypeScript, and full-stack software development.",
                    sizeFormatted: "4.70 GB",
                    ramFormatted: "5.8 GB RAM",
                    badges: [.new, .code, .tools],
                    rawModel: HFModel(id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit", name: "Qwen2.5-Coder-7B-Instruct-4bit", downloads: 110000, likes: 3400, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/QwQ-32B-Preview-4bit",
                    name: "QwQ 32B Preview",
                    description: "Reasoning model designed to compete with OpenAI o1, generating explicit chains of thought for difficult math and logic.",
                    sizeFormatted: "19.5 GB",
                    ramFormatted: "24.0 GB RAM",
                    badges: [.thinking],
                    rawModel: HFModel(id: "mlx-community/QwQ-32B-Preview-4bit", name: "QwQ-32B-Preview-4bit", downloads: 68000, likes: 1900, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
                    name: "Qwen 2.5 3B Instruct",
                    description: "Fast on-device model for quick tasks, chat assistance, and responsive interactions on any M-series Mac.",
                    sizeFormatted: "2.10 GB",
                    ramFormatted: "2.8 GB RAM",
                    badges: [.recommended],
                    rawModel: HFModel(id: "mlx-community/Qwen2.5-3B-Instruct-4bit", name: "Qwen2.5-3B-Instruct-4bit", downloads: 42000, likes: 890, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                )
            ]
        ),
        ModelFamily(
            id: "deepseek",
            name: "DeepSeek R1 & V3",
            icon: "brain.head.profile",
            provider: .deepseek,
            description: "Open reasoning and coding powerhouses from DeepSeek AI. Features pure chain-of-thought distillation and coding.",
            badges: [.new, .thinking, .code],
            variants: [
                ModelCatalogVariant(
                    id: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit",
                    name: "DeepSeek R1 Distill 7B",
                    description: "Distilled reasoning model that thinks aloud inside <think> tokens, solving complex science, math, and code problems.",
                    sizeFormatted: "4.68 GB",
                    ramFormatted: "5.8 GB RAM",
                    badges: [.new, .thinking, .recommended],
                    rawModel: HFModel(id: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit", name: "DeepSeek-R1-Distill-Qwen-7B-4bit", downloads: 145000, likes: 4200, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/DeepSeek-R1-Distill-Llama-8B-4bit",
                    name: "DeepSeek R1 Distill Llama 8B",
                    description: "Meta Llama backbone distilled with DeepSeek R1 reasoning patterns for structured problem solving.",
                    sizeFormatted: "5.20 GB",
                    ramFormatted: "6.4 GB RAM",
                    badges: [.thinking],
                    rawModel: HFModel(id: "mlx-community/DeepSeek-R1-Distill-Llama-8B-4bit", name: "DeepSeek-R1-Distill-Llama-8B-4bit", downloads: 89000, likes: 2100, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                )
            ]
        ),
        ModelFamily(
            id: "mistral",
            name: "Mistral & Codestral",
            icon: "wind",
            provider: .mistral,
            description: "Fast, efficient European language models with unmatched instruction precision, multilingual support, and coding mastery.",
            badges: [.new, .code, .tools],
            variants: [
                ModelCatalogVariant(
                    id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
                    name: "Mistral 7B Instruct v0.3",
                    description: "The classic benchmark-setting 7B model with native function calling and vocabulary expansion.",
                    sizeFormatted: "4.30 GB",
                    ramFormatted: "5.4 GB RAM",
                    badges: [.recommended, .tools],
                    rawModel: HFModel(id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit", name: "Mistral-7B-Instruct-v0.3-4bit", downloads: 78000, likes: 1600, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/Codestral-22B-v0.1-4bit",
                    name: "Codestral 22B",
                    description: "Mistral AI's premier generative code model, supporting over 80 programming languages with fill-in-the-middle.",
                    sizeFormatted: "12.8 GB",
                    ramFormatted: "16.0 GB RAM",
                    badges: [.code],
                    rawModel: HFModel(id: "mlx-community/Codestral-22B-v0.1-4bit", name: "Codestral-22B-v0.1-4bit", downloads: 54000, likes: 1300, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                )
            ]
        ),
        ModelFamily(
            id: "llama",
            name: "Llama 3.3 & 3.2",
            icon: "flame.fill",
            provider: .llama,
            description: "Meta's industry standard open-weights foundation models, supporting high-throughput conversational AI and vision.",
            badges: [.vision, .tools, .recommended],
            variants: [
                ModelCatalogVariant(
                    id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                    name: "Llama 3.2 3B Instruct",
                    description: "Meta's highly optimized lightweight model for on-device summarization, rewriting, and instruction following.",
                    sizeFormatted: "2.10 GB",
                    ramFormatted: "2.8 GB RAM",
                    badges: [.new, .recommended],
                    rawModel: HFModel(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", name: "Llama-3.2-3B-Instruct-4bit", downloads: 125000, likes: 3100, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                ),
                ModelCatalogVariant(
                    id: "mlx-community/Llama-3.2-11B-Vision-Instruct-4bit",
                    name: "Llama 3.2 11B Vision",
                    description: "Meta's multimodal model integrating vision adapters to reason about charts, images, and text jointly.",
                    sizeFormatted: "6.80 GB",
                    ramFormatted: "8.5 GB RAM",
                    badges: [.vision],
                    rawModel: HFModel(id: "mlx-community/Llama-3.2-11B-Vision-Instruct-4bit", name: "Llama-3.2-11B-Vision-Instruct-4bit", downloads: 64000, likes: 1700, tags: ["image-text-to-text"], pipelineTag: "image-text-to-text", createdAt: nil)
                )
            ]
        ),
        ModelFamily(
            id: "phi",
            name: "Microsoft Phi-4",
            icon: "apple.terminal",
            provider: .phi,
            description: "Small language models from Microsoft with state-of-the-art math, logic, and scientific problem-solving capabilities.",
            badges: [.thinking, .code],
            variants: [
                ModelCatalogVariant(
                    id: "mlx-community/phi-4-4bit",
                    name: "Phi-4 (14B)",
                    description: "Microsoft's 14B parameter model matching larger 70B models in mathematical reasoning, STEM tasks, and code.",
                    sizeFormatted: "8.60 GB",
                    ramFormatted: "10.8 GB RAM",
                    badges: [.new, .thinking, .code],
                    rawModel: HFModel(id: "mlx-community/phi-4-4bit", name: "phi-4-4bit", downloads: 58000, likes: 1450, tags: ["text-generation"], pipelineTag: "text-generation", createdAt: nil)
                )
            ]
        )
    ]
}
