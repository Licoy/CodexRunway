import CodexRunwayCore
import Foundation

enum SelfCheck {
    static func run() async {
        let store = CodexAuthStore()
        do {
            let auth = try store.load()
            print(auth.redactedDescription)
            print(TokenInspector.isExpired(auth.tokens.accessToken) ? "token: expired" : "token: valid")
            print(sessionSummary())
        } catch {
            print("auth: unavailable (\(error.localizedDescription))")
        }
        await printGrokSummary()
    }

    static func sanitizedGrokVersion(_ rawValue: String) -> String? {
        let components = rawValue.split(whereSeparator: \Character.isWhitespace)
        guard !components.isEmpty else { return nil }
        let candidate: Substring
        if components[0].lowercased() == "grok", components.count > 1 {
            candidate = components[1]
        } else {
            candidate = components[0]
        }
        guard candidate.count <= 32,
              candidate.first?.isNumber == true,
              candidate.contains("."),
              candidate.utf8.allSatisfy(Self.isSafeVersionByte)
        else {
            return nil
        }
        return "grok \(candidate)"
    }

    private static func sessionSummary() -> String {
        do {
            let report = try SessionRepairService().dryRun()
            return "sessions: \(report.plannedEntries), missing: \(report.missingIndexIDs.count), orphan: \(report.orphanIndexIDs.count)"
        } catch {
            return "sessions: unavailable"
        }
    }

    private static func printGrokSummary() async {
        if let executableURL = GrokExecutableLocator.locate() {
            do {
                let rawVersion = try await GrokCLIClient(executableURL: executableURL).version()
                let version = sanitizedGrokVersion(rawVersion) ?? "unrecognized (redacted)"
                print("grok cli: \(version)")
            } catch {
                print("grok cli: available (version unavailable)")
            }
        } else {
            print("grok cli: unavailable")
        }

        switch GrokAccountStore().loadOfficialCredentialStatus() {
        case .missing:
            print("grok auth: missing")
            print("grok identity: unavailable")
        case .malformed:
            print("grok auth: malformed")
            print("grok identity: unavailable")
        case .unreadable:
            print("grok auth: unreadable")
            print("grok identity: unavailable")
        case .apiKeyOnly:
            print("grok auth: api-key-only (not managed)")
            print("grok identity: unavailable")
        case .unsupported:
            print("grok auth: unsupported")
            print("grok identity: unavailable")
        case let .authenticated(identity):
            print("grok auth: authenticated")
            print(identitySummary(identity))
        case let .requiresReauthentication(identity):
            print("grok auth: reauthentication required")
            print(identitySummary(identity))
        }
    }

    private static func identitySummary(_ identity: GrokCredentialIdentity) -> String {
        let kind = identity.kind == .oauth ? "oauth" : "legacy-session"
        return "grok identity: available (\(kind), redacted)"
    }

    private static func isSafeVersionByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48 ... 57, 65 ... 90, 97 ... 122, 43, 45, 46, 95:
            true
        default:
            false
        }
    }
}
