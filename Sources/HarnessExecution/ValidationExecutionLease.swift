import Foundation
import HarnessCore

/// Root hashing matches the latest-run index; different projects remain independent.
enum ValidationExecutionLease {
    static func acquire(directory: URL, root: URL) throws -> LocalExecutionLease {
        let key = ValidationSourceIdentity.hash(Data(root.path.utf8))
        return try LocalExecutionLease(file: directory.appendingPathComponent("execution-\(key).lock"))
    }
}
