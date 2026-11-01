import Foundation

/// A hardware-control result distinguishes a successful request from verified state.
enum ControlPhase: String {
    case requested
    case accepted
    case verified
    case active
    case failed
    case expired
    case restored
}

struct ControlEvidence {
    let operation: String
    let backend: String
    let phase: ControlPhase
    let target: String?
    let observed: String?
    let detail: String?
    let date: Date

    init(operation: String, backend: String, phase: ControlPhase,
         target: String? = nil, observed: String? = nil, detail: String? = nil,
         date: Date = Date()) {
        self.operation = operation
        self.backend = backend
        self.phase = phase
        self.target = target
        self.observed = observed
        self.detail = detail
        self.date = date
    }
}
