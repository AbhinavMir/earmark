import Foundation
import Testing
import AudibleKit
@testable import Earmarky

/// Every address the sign-in view sees comes from a web page, which is the
/// least trusted thing the application touches.
@Suite("Fuzzing what the sign-in view is shown")
struct SignInFuzzTests {

    /// The rule the view follows for each address it passes through.
    static func wouldRegister(_ text: String) -> Bool {
        guard let url = URL(string: text) else { return false }
        return DeviceRegistration.authorizationCode(in: url) != nil
    }

    @Test("A code is taken only from Amazon's own landing page")
    func onlyAmazon() {
        #expect(Self.wouldRegister(
            "https://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=GOOD"))

        let refused = [
            "https://evil.invalid/ap/maplanding?openid.oa2.authorization_code=BAD",
            "https://www.amazon.com.evil.invalid/ap/maplanding?openid.oa2.authorization_code=BAD",
            "https://amazonn.com/ap/maplanding?openid.oa2.authorization_code=BAD",
            "http://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=BAD",
            "https://www.amazon.com/ap/maplanding/../../x?openid.oa2.authorization_code=BAD",
            "javascript:alert(1)",
            "data:text/html,<script>x</script>",
            "file:///etc/passwd",
            "about:blank",
            "https://www.amazon.com@evil.invalid/ap/maplanding?openid.oa2.authorization_code=BAD",
            "https://evil.invalid/?redirect=https://www.amazon.com/ap/maplanding&openid.oa2.authorization_code=BAD"
        ]
        for text in refused {
            #expect(!Self.wouldRegister(text), "took a code from \(text)")
        }
    }

    @Test("Text of any kind offered as an address is handled")
    func anyText() {
        var state: UInt64 = 4242
        func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        for _ in 0..<400 {
            let noise = String(decoding: (0..<Int(next() % 40)).map {
                _ in UInt8(truncatingIfNeeded: next())
            }, as: UTF8.self)
            for shape in ["https://www.amazon.com/ap/maplanding?\(noise)",
                          "https://\(noise)/ap/maplanding?openid.oa2.authorization_code=X",
                          noise] {
                _ = Self.wouldRegister(shape)
            }
        }
    }

    @Test("A code carrying anything is still only a code")
    func codeContents() {
        // The code is put in a request body. Nothing it contains may change
        // the shape of that body.
        let codes = ["A", "A B", "A&b=c", "A\"b", "A\\b", "A\nb", "A%00b",
                     String(repeating: "A", count: 5_000), "🎧"]
        for code in codes {
            guard let encoded = code.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed),
                let url = URL(string:
                    "https://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=\(encoded)")
            else { continue }

            guard let read = DeviceRegistration.authorizationCode(in: url) else { continue }
            // Whatever was read becomes JSON, and JSON escapes it.
            let body = try? JSONSerialization.data(withJSONObject: ["code": read])
            #expect(body != nil, "a code of \(code.prefix(10)) could not be sent safely")
        }
    }
}
