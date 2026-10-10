import Foundation
import HarnessCore
import Testing

struct LocalInferencePrivacyTests {
    @Test func defaultConfigurationNeverUsesDiskCacheOrCookies() {
        let configuration = LocalInferenceSessionPolicy.configuration()

        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpMaximumConnectionsPerHost == 1)
    }
}
