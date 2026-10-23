import Foundation

enum RoutingTask: String, CaseIterable, Identifiable, Sendable {
    case chat
    case code
    case vision
    case reasoning
    case writing
    case research

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chat: "General Chat"
        case .code: "Coding"
        case .vision: "Vision / Images"
        case .reasoning: "Reasoning"
        case .writing: "Writing"
        case .research: "Research & Summaries"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .vision: "eye"
        case .reasoning: "brain"
        case .writing: "pencil.line"
        case .research: "doc.text.magnifyingglass"
        }
    }
}

struct RoutingDecision: Sendable {
    let model: InstalledModel
    /// Plain-language reasons, each tied to evidence (name/metadata/RAM).
    let reasons: [String]
    let usedFallback: Bool
    /// Set when the user pinned a model for this task — routing explains that
    /// it is an override rather than pretending it scored highest.
    let isManualOverride: Bool
}

/// Model routing (feature J). Scores *installed, validated* models for a task
/// using only evidence the app actually has: the model's name/tags (via its
/// catalog category), its vision flag, and a RAM estimate checked against this
/// Mac. It never invents a capability: a model with no evidence for a task
/// simply scores low, and when nothing fits, it falls back to the smallest
/// complete model and says so.
enum ModelRouter {
    private static let overrideKeyPrefix = "routingOverride."

    nonisolated static func manualOverride(for task: RoutingTask) -> String? {
        UserDefaults.standard.string(forKey: overrideKeyPrefix + task.rawValue)
    }

    static func setManualOverride(_ modelID: String?, for task: RoutingTask) {
        if let modelID {
            UserDefaults.standard.set(modelID, forKey: overrideKeyPrefix + task.rawValue)
        } else {
            UserDefaults.standard.removeObject(forKey: overrideKeyPrefix + task.rawValue)
        }
    }

    static func route(
        task: RoutingTask,
        installedModels: [InstalledModel],
        overrideModelID: String?
    ) -> RoutingDecision? {
        guard !installedModels.isEmpty else { return nil }

        if let overrideModelID, let override = installedModels.first(where: { $0.id == overrideModelID }) {
            return RoutingDecision(
                model: override,
                reasons: ["You pinned \(override.displayName) for this task — manual override wins over automatic routing."],
                usedFallback: false,
                isManualOverride: true
            )
        }

        let availableRAM = RAMService.availableRAMForModels
        var best: (model: InstalledModel, score: Double, reasons: [String])?
        var smallestFitting: (model: InstalledModel, ram: Double)?

        for model in installedModels {
            let probe = HFModel(id: model.id, name: model.id, downloads: 0, likes: 0, tags: [], pipelineTag: nil, createdAt: nil)
            let ram = probe.estimatedRAMGB ?? 4.0
            var score = 0.0
            var reasons: [String] = []

            // Memory is a hard constraint first, a preference second.
            if ram <= availableRAM {
                score += 10
                reasons.append("Estimated \(ram.formatted(.number.precision(.fractionLength(1)))) GB fits this Mac's \(availableRAM.formatted(.number.precision(.fractionLength(0)))) GB available for models")
                if smallestFitting.map({ ram < $0.ram }) ?? true {
                    smallestFitting = (model, ram)
                }
            } else {
                score -= 100
                reasons.append("Estimated \(ram.formatted(.number.precision(.fractionLength(1)))) GB exceeds this Mac's available memory")
            }

            switch task {
            case .vision:
                if model.isVisual {
                    score += 50
                    reasons.append("Flagged as a vision model — the VLM backend can load it with images")
                } else {
                    score -= 50
                    reasons.append("No vision evidence — it cannot accept images")
                }
            case .code:
                if probe.category == .code || model.displayName.lowercased().contains("code") || model.displayName.lowercased().contains("coder") {
                    score += 40
                    reasons.append("Name/catalog identify it as a code model")
                }
            case .reasoning:
                if probe.category == .reasoning || model.displayName.lowercased().contains("r1") || model.displayName.lowercased().contains("qwq") {
                    score += 40
                    reasons.append("Name/catalog identify it as a reasoning model")
                }
            case .writing, .research, .chat:
                if probe.category == .chat || probe.category == .writing {
                    score += 25
                    reasons.append("Catalog category suits \(task.displayName.lowercased())")
                }
                if !model.isVisual {
                    score += 5
                    reasons.append("Text model — no memory spent on a vision tower for a text task")
                }
            }

            if best.map({ score > $0.score }) ?? true {
                best = (model, score, reasons)
            }
        }

        guard let best else { return nil }
        // Vision has no honest fallback: a text model cannot see images.
        if task == .vision && !best.model.isVisual {
            return nil
        }
        let usedFallback = best.score < 0
        if usedFallback, let fallback = smallestFitting {
            return RoutingDecision(
                model: fallback.model,
                reasons: ["No installed model is a comfortable fit, so routing fell back to the smallest complete model (\(fallback.model.displayName))."],
                usedFallback: true,
                isManualOverride: false
            )
        }
        return RoutingDecision(model: best.model, reasons: best.reasons, usedFallback: false, isManualOverride: false)
    }
}
