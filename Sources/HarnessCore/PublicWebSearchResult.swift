import Foundation

public struct PublicWebSearchResult: Codable, Equatable, Sendable {
    public let title: String
    public let urlString: String

    public init(title: String, urlString: String) {
        self.title = title
        self.urlString = urlString
    }
}

public enum PublicWebSearchResultPolicy {
    public static let maximumResults = 8

    public static func filtered(
        _ candidates: [PublicWebSearchResult]
    ) -> [PublicWebSearchResult] {
        var seen = Set<String>()
        var results: [PublicWebSearchResult] = []
        for candidate in candidates {
            guard let result = sanitized(candidate),
                  seen.insert(result.urlString).inserted else { continue }
            results.append(result)
            if results.count == maximumResults { break }
        }
        return results
    }

    private static func sanitized(
        _ candidate: PublicWebSearchResult
    ) -> PublicWebSearchResult? {
        let title = collapsed(candidate.title)
        guard !title.isEmpty,
              title.count <= 240,
              !containsPrivateText(title),
              var components = URLComponents(string: candidate.urlString) else {
            return nil
        }
        components = redirectedTarget(from: components) ?? components
        guard
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              isPublic(host: host),
              !isSearchOrAccountPage(host: host, path: components.path) else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        guard let sanitizedURL = components.url?.absoluteString,
              sanitizedURL.count <= 1_024 else { return nil }
        return PublicWebSearchResult(
            title: String(title.prefix(200)),
            urlString: sanitizedURL
        )
    }

    private static func redirectedTarget(
        from components: URLComponents
    ) -> URLComponents? {
        guard let host = components.host?.lowercased() else { return nil }
        let redirectKeys: [String]
        if ["google.com", "www.google.com"].contains(host),
           components.path == "/url" {
            redirectKeys = ["q", "url"]
        } else if host == "duckduckgo.com", components.path == "/l/" {
            redirectKeys = ["uddg"]
        } else {
            return nil
        }
        for key in redirectKeys {
            guard let target = components.queryItems?.first(where: {
                $0.name == key
            })?.value,
            let targetComponents = URLComponents(string: target) else { continue }
            return targetComponents
        }
        return nil
    }

    private static func collapsed(_ value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsPrivateText(_ title: String) -> Bool {
        let lowered = title.lowercased()
        let blockedWords = [
            "sign in", "log in", "account", "profile", "password",
            "ログイン", "サインイン", "アカウント", "プロフィール", "パスワード",
            "郵便番号", "現在地"
        ]
        if blockedWords.contains(where: lowered.contains) { return true }
        return title.range(
            of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isSearchOrAccountPage(host: String, path: String) -> Bool {
        let normalizedPath = path.lowercased()
        let isSearchHost = [
            "google.com", "www.google.com", "bing.com", "www.bing.com",
            "duckduckgo.com", "search.yahoo.com"
        ].contains(host)
        if isSearchHost { return true }
        return normalizedPath.contains("/account")
            || normalizedPath.contains("/signin")
            || normalizedPath.contains("/login")
    }

    private static func isPublic(host: String) -> Bool {
        let normalized = host.trimmingCharacters(
            in: CharacterSet(charactersIn: "[]")
        )
        guard normalized != "localhost", !normalized.hasSuffix(".local") else {
            return false
        }
        if normalized == "::1" || normalized.hasPrefix("fc")
            || normalized.hasPrefix("fd") || normalized.hasPrefix("fe80:") {
            return false
        }
        let parts = normalized.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return true }
        let first = parts[0]
        let second = parts[1]
        if first == 0 || first == 10 || first == 127 { return false }
        if first == 169 && second == 254 { return false }
        if first == 192 && second == 168 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        return true
    }
}
