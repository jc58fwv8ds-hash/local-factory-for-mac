import Foundation

public enum LocalInferenceSessionPolicy {
    public static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }

    static func session() -> URLSession {
        URLSession(configuration: configuration())
    }
}
