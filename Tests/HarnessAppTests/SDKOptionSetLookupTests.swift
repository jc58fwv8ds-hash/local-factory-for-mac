import Foundation
@testable import HarnessCore
import Testing

struct SDKOptionSetLookupTests {
    @Test func anOptionMissingFromOneSetIsFoundInTheSetThatHasIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-\(UUID().uuidString)")
        let headers = root.appendingPathComponent("System/Library/Frameworks/Foundation.framework/Headers")
        try FileManager.default.createDirectory(at: headers, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        @interface NSString : NSObject
        typedef NS_OPTIONS(NSUInteger, NSStringCompareOptions) {
            NSCaseInsensitiveSearch = 1,
            NSDiacriticInsensitiveSearch API_AVAILABLE(ios(2.0)) = 128,
        };
        @interface NSRegularExpression : NSObject
        typedef NS_OPTIONS(NSUInteger, NSRegularExpressionOptions) {
           NSRegularExpressionCaseInsensitive             = 1 << 0,
           NSRegularExpressionAllowCommentsAndWhitespace  = 1 << 1,
        };
        """.write(to: headers.appendingPathComponent("NSString.h"), atomically: true, encoding: .utf8)
        let lookup = SDKOptionSetLookup(sdkPath: { root.path })
        let text = try #require(lookup.hint(for: "type 'NSRegularExpression.Options.ArrayLiteralElement' (aka 'NSRegularExpression.Options') has no member 'diacriticInsensitive'"))
        #expect(text.contains("NSRegularExpression.Options にあるのは: caseInsensitive, allowCommentsAndWhitespace"))
        #expect(text.contains("「diacriticInsensitive」があるのは: NSString.CompareOptions(NSStringCompareOptions)"))
    }
}
