import Foundation
import Combine

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

/// The single place charge, fan and sleep control report what they asked the
/// hardware for.
///
/// P0-01 exists because those three used to describe success differently: a fan
/// write was a thrown error, a sleep assertion was a silent no-op, and a charge
/// limit was a string. With one journal the UI and the exported report can
/// answer the same question for all of them — what was requested, was it
/// accepted, is it still in effect — and a request can never be dressed up as
/// verified state.
final class ControlJournal: ObservableObject {

    static let shared = ControlJournal()

    /// Newest first. Bounded: hardware control runs at up to 2.5 Hz, so an
    /// unbounded log would grow for as long as the app stays open.
    @Published private(set) var entries: [ControlEvidence] = []

    private let capacity = 60

    private init() {}

    /// Safe from any thread: controllers are driven from timers, helpers and
    /// UI actions alike, and the published array must change on main.
    func record(_ evidence: ControlEvidence) {
        if Thread.isMainThread {
            append(evidence)
        } else {
            DispatchQueue.main.async { [weak self] in self?.append(evidence) }
        }
    }

    func latest(_ operation: String) -> ControlEvidence? {
        entries.first { $0.operation == operation }
    }

    func clear() { entries.removeAll() }

    private func append(_ evidence: ControlEvidence) {
        // A held ceiling is re-written every 400 ms and the fan curve every few
        // seconds. Collapsing a repeat of the same state into one entry keeps
        // the list readable without hiding a phase change or a new target.
        if let first = entries.first,
           first.operation == evidence.operation,
           first.phase == evidence.phase,
           first.target == evidence.target,
           first.observed == evidence.observed,
           first.detail == evidence.detail {
            entries[0] = evidence
            return
        }
        entries.insert(evidence, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }
}

extension ControlPhase {

    /// Human wording for the diagnostics list. A phase describes what is known,
    /// never what is hoped for.
    var label: String {
        switch self {
        case .requested: return "已请求"
        case .accepted: return "已接受"
        case .verified: return "已回读确认"
        case .active: return "已生效"
        case .failed: return "失败"
        case .expired: return "已过期"
        case .restored: return "已恢复"
        }
    }
}
