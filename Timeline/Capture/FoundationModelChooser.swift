#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Apple's on-device model, asked to pick one of the candidates.
///
/// Everything stays on the phone, which matters here: the prompt contains where
/// someone has been and when. That is the whole reason this is worth doing with
/// a local model rather than a server.
@available(iOS 26.0, macOS 26.0, *)
struct FoundationModelChooser: PlaceChoosing {
    /// The answer shape. Constraining `title` to the candidate list is what stops
    /// the model naming a place that is not on screen.
    @Generable
    struct Choice {
        @Guide(description: "The name of the chosen place, copied exactly")
        let title: String
        @Guide(description: "How confident this is, from 0 to 1", .minimum(0.0), .maximum(1.0))
        let confidence: Double
        @Guide(description: "A short phrase explaining the choice, at most eight words")
        let reason: String
    }

    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Why the model cannot be used, for the settings screen — "not supported on
    /// this iPhone" and "turn on Apple Intelligence" are different problems.
    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This iPhone does not support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in Settings."
            case .modelNotReady:
                return "The on-device model is still downloading."
            @unknown default:
                return "The on-device model is unavailable."
            }
        @unknown default:
            return "The on-device model is unavailable."
        }
    }

    func choose(from titles: [String], prompt: String) async throws -> ModelPlaceChoice {
        guard !titles.isEmpty else { throw CocoaError(.featureUnsupported) }
        let session = LanguageModelSession(instructions: PlaceNamingPrompt.instructions)
        let response = try await session.respond(to: prompt, generating: Choice.self)
        let choice = response.content
        return ModelPlaceChoice(
            title: choice.title,
            confidence: min(max(choice.confidence, 0), 1),
            reason: choice.reason
        )
    }
}
#endif

/// Picks the best chooser this device can offer. Older systems and devices
/// without Apple Intelligence get one that politely declines, so the recorder
/// never branches on availability itself.
enum PlaceChooserFactory {
    static func make() -> any PlaceChoosing {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return FoundationModelChooser()
        }
        #endif
        return UnavailableChooser()
    }

    /// Nil when the model is usable, otherwise why it is not.
    static func unavailableReason() -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return FoundationModelChooser().unavailableReason
        }
        #endif
        return "Needs iOS 26 or later."
    }
}
