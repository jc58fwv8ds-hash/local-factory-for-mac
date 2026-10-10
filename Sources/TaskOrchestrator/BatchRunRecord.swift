import Foundation

/// Durable result record shared by the batch runner stages; every save is atomic.
final class BatchRunRecord {
    private(set) var values: [String: Any]
    private let url: URL
    private let start: Date
    init(url: URL, start: Date, values: [String: Any]) { self.url = url; self.start = start; self.values = values }
    subscript(key: String) -> Any? {
        get { values[key] }
        set { values[key] = newValue }
    }
    func append(_ key: String, _ value: Any) { values[key] = ((values[key] as? [Any]) ?? []) + [value] }
    func increment(_ key: String) { values[key] = ((values[key] as? Int) ?? 0) + 1 }
    func save() throws {
        values["completionSeconds"] = Date().timeIntervalSince(start)
        try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

/// Current readable/editable split; promotions only through deterministic evidence.
struct BatchScope {
    var nominationOnly: Set<String> = []
    var editable: [String]
    var readOnly: [String]
    mutating func apply(_ decision: ContextEscalationDecisionView) {
        readOnly = Array(Set(readOnly + decision.added).subtracting(decision.promoted)).sorted()
        editable = Array(Set(editable + decision.promoted)).sorted()
    }
}

struct ContextEscalationDecisionView { let added: [String]; let promoted: [String] }
