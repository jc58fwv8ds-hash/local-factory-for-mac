import Foundation

public extension ProjectLibrary {
    func records(matching query: ProjectLibraryQuery) -> [ProjectRecord] {
        let search = query.searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        let matches = records.filter { record in
            let matchesLifecycle = query.lifecycle.map { record.lifecycle == $0 } ?? true
            guard matchesLifecycle else { return false }
            guard !search.isEmpty else { return true }

            let searchableText = [
                record.project.name,
                record.project.summary,
                record.sourceLocation ?? "",
                record.project.targets.map(\.rawValue).joined(separator: " ")
            ]
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

            return searchableText.localizedStandardContains(search)
        }

        switch query.sort {
        case .recent:
            return matches.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        case .name:
            return matches.sorted {
                $0.project.name.localizedStandardCompare($1.project.name) == .orderedAscending
            }
        case .progress:
            return matches.sorted { lhs, rhs in
                if lhs.project.progress == rhs.project.progress {
                    return lhs.project.name.localizedStandardCompare(rhs.project.name) == .orderedAscending
                }
                return lhs.project.progress > rhs.project.progress
            }
        }
    }

    func sourceRecord(at sourceURL: URL) -> ProjectRecord? {
        let standardizedPath = sourceURL.standardizedFileURL.path
        return records.first { record in
            guard let sourceLocation = record.sourceLocation else {
                return false
            }
            return URL(fileURLWithPath: sourceLocation).standardizedFileURL.path == standardizedPath
        }
    }
}
