// Level-2 planning contract. A planner turns free text into PROPOSED steps;
// it never executes. DeviceController's policy decides what actually runs,
// and anything ambiguous or multi-device comes back as a question.
import Foundation

public struct ProposedStep: Equatable, Sendable {
    /// Device ids the planner chose (from the registry it was shown).
    public var deviceIDs: [String]
    public var command: DeviceCommand

    public init(deviceIDs: [String], command: DeviceCommand) {
        self.deviceIDs = deviceIDs
        self.command = command
    }
}

public struct ProposedPlan: Equatable, Sendable {
    public var steps: [ProposedStep]
    /// Short model-authored explanation of the plan (shown, not spoken verbatim).
    public var summary: String
    /// A question to ask when the request cannot be planned safely.
    public var clarification: String?

    public init(steps: [ProposedStep], summary: String, clarification: String? = nil) {
        self.steps = steps
        self.summary = summary
        self.clarification = clarification
    }

    public var isEmpty: Bool { steps.isEmpty && clarification == nil }
}

public enum PlannerError: Error, Equatable {
    case unavailable(String)
    case failed(String)
}

/// Implemented by the Foundation Models adapter; tests use a scripted one.
@MainActor
public protocol NaturalLanguagePlanner: AnyObject {
    /// False when the model is missing, disabled or not ready — callers fall
    /// back to the Level-1 grammar.
    var isAvailable: Bool { get }
    /// Human-readable availability note for the UI (nil when available).
    var unavailableReason: String? { get }
    func plan(_ utterance: String, devices: [DeviceSummary]) async throws -> ProposedPlan
}
