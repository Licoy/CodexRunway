import Testing
@testable import CodexRunway

@Suite("Self check")
struct SelfCheckTests {
    @Test("Grok version output is reduced to a safe version token")
    func sanitizesGrokVersion() {
        #expect(SelfCheck.sanitizedGrokVersion("grok 0.2.114\n") == "grok 0.2.114")
        #expect(SelfCheck.sanitizedGrokVersion("1.4.0-beta.2") == "grok 1.4.0-beta.2")
        #expect(SelfCheck.sanitizedGrokVersion("grok token-shaped-output") == nil)
        #expect(SelfCheck.sanitizedGrokVersion("unexpected secret output") == nil)
        #expect(SelfCheck.sanitizedGrokVersion("grok 1密钥.2") == nil)
    }
}
