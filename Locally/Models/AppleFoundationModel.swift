import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The built-in Apple Intelligence model (`FoundationModels.SystemLanguageModel`).
///
/// Unlike every other model in Locally this one is not a Hugging Face artifact:
/// there is nothing to download, no weights on disk and no MLX container. It is
/// the language model that ships with macOS 26 and later, so it is identified by
/// a reserved ID and never appears in the Hugging Face cache.
nonisolated enum AppleFoundationModel {
    /// Reserved identifier used everywhere a model ID is stored (conversations,
    /// routing overrides, app storage).
    static let modelID = "apple.on-device.foundation"
    /// Identifier of the `InferenceBackend` that serves this model.
    static let backendID = "foundation-models"
    static let displayName = "Apple Intelligence"
    static let author = "Apple"

    static func isAppleModel(_ id: String?) -> Bool {
        id == modelID
    }

    /// The model as the rest of the app already understands models.
    static var descriptor: InstalledModel {
        InstalledModel(id: modelID, displayName: displayName, author: author, isVisual: false)
    }

    /// Whether the system model can actually run a request right now.
    /// Apple can take a while to download the model after Apple Intelligence
    /// is turned on, so this is checked at use time rather than cached.
    static var availability: AppleModelAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable("This Mac does not support Apple Intelligence, so the built-in model cannot run here.")
                case .appleIntelligenceNotEnabled:
                    return .unavailable("Apple Intelligence is turned off. Turn it on in System Settings → Apple Intelligence & Siri to use the built-in model.")
                case .modelNotReady:
                    return .unavailable("Apple Intelligence is still downloading its model. It becomes available when the download finishes.")
                @unknown default:
                    return .unavailable("The built-in Apple model is not available on this Mac right now.")
                }
            }
        }
        #endif
        return .unsupportedSystem
    }

    static var isAvailable: Bool {
        availability.isAvailable
    }
}

/// Plain-language availability, so views never have to interpret framework
/// error types themselves.
nonisolated enum AppleModelAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
    case unsupportedSystem

    var isAvailable: Bool {
        self == .available
    }

    /// Full sentence for banners, errors and accessibility hints.
    var explanation: String {
        switch self {
        case .available:
            "Apple Intelligence is ready on this Mac."
        case .unavailable(let reason):
            reason
        case .unsupportedSystem:
            "The built-in Apple model needs macOS 26 or later."
        }
    }

    /// Compact menu-row status, or nil when there is nothing to warn about.
    var shortStatus: String? {
        switch self {
        case .available:
            nil
        case .unavailable:
            "Unavailable"
        case .unsupportedSystem:
            "Requires macOS 26"
        }
    }
}

/// A user-facing failure from the system model, already translated from
/// `LanguageModelError` into something a person can act on.
nonisolated struct AppleFoundationModelError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
