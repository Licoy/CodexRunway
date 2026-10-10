import Testing
@testable import CodexRunwayCore

@Suite("Account privacy mask")
struct AccountPrivacyMaskTests {
    @Test("email keeps the first character and the top-level domain")
    func masksEmail() {
        #expect(AccountPrivacyMask.mask("example@qq.com") == "e***@***.com")
        #expect(AccountPrivacyMask.mask("maxwmm1999@outlook.com") == "m***@***.com")
        #expect(AccountPrivacyMask.mask("Example@QQ.COM") == "E***@***.COM")
        #expect(AccountPrivacyMask.mask("  example@qq.com  ") == "e***@***.com")
    }

    @Test("domain labels before the final suffix collapse together")
    func masksNestedDomain() {
        #expect(AccountPrivacyMask.mask("user@mail.qq.com") == "u***@***.com")
        #expect(AccountPrivacyMask.mask("a@qq.com") == "a@***.com")
        #expect(AccountPrivacyMask.mask("user@localhost") == "u***@***")
    }

    @Test("names and identifiers keep only the first character")
    func masksPlainText() {
        #expect(AccountPrivacyMask.mask("alice") == "a***")
        #expect(AccountPrivacyMask.mask("张三") == "张***")
        #expect(AccountPrivacyMask.mask("a") == "a")
        #expect(AccountPrivacyMask.mask("") == "")
        #expect(AccountPrivacyMask.mask("   ") == "   ")
    }

    @Test("email tokens inside a longer line are masked and the rest stays")
    func masksEmbeddedEmail() {
        #expect(AccountPrivacyMask.mask("example@qq.com: missing") == "e***@***.com: missing")
        #expect(AccountPrivacyMask.maskEmails(in: "see example@qq.com.") == "see e***@***.com.")
        #expect(AccountPrivacyMask.maskEmails(in: "no address here") == "no address here")
    }

    @Test("masking an already masked email stays stable")
    func maskIsStable() {
        let masked = AccountPrivacyMask.mask("example@qq.com")
        #expect(AccountPrivacyMask.mask(masked) == masked)
    }
}
