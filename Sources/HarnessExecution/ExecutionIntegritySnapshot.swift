import Foundation
import CryptoKit

enum ExecutionIntegritySnapshot {
    static func capture(_ root: URL, excluding: Set<String> = []) throws -> [String: String] {
        let fm = FileManager.default
        guard let items = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw IsolatedPackageExecution.Failure.invalidScope
        }
        var result: [String: String] = [:]
        while let url = items.nextObject() as? URL {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if excluding.contains(relative.split(separator: "/").first.map(String.init) ?? "") {
                items.skipDescendants(); continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                result[relative] = "symlink:" + (try fm.destinationOfSymbolicLink(atPath: url.path))
            } else if values.isRegularFile == true {
                result[relative] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }
    static func changes(_ before: [String: String], _ after: [String: String]) -> [String] {
        Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
    }
}
