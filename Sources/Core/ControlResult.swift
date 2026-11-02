import Foundation

/// Recovery never infers a fanless machine from failed enumeration.
/// Injected operations keep partial failures testable without SMC access.
enum FanRecovery {
    static func restore(count: Int?, restoreAndVerify: (Int) throws -> Void) -> [String] {
        guard let count, (0...8).contains(count) else { return ["countUnknown"] }
        var failures: [String] = []
        for index in 0..<count {
            do { try restoreAndVerify(index) }
            catch { failures.append("F\(index): \(error.localizedDescription)") }
        }
        return failures
    }
}

/// Hardware-free predicates shared by entry points and regression tests.
enum ControlSafety {
    static func ordinaryAllowed(running: Bool, recovering: Bool) -> Bool {
        !running && !recovering
    }

    static func loadAllowed(running: Bool, dischargePhase: Bool, current: Double,
                            failed: Bool, waiting: Bool, hot: Bool) -> Bool {
        running && dischargePhase && current.isFinite && current < -0.05
            && !failed && !waiting && !hot
    }
}

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
