import Foundation
import Testing

@Suite("README locale editions")
struct ReadmeLocaleTests {
    @Test("every edition lists the five new languages with working relative links")
    func readmeSwitchersLinkAllEditions() throws {
        let root = repoRoot()
        let editions: [(file: String, current: String)] = [
            ("README.md", "English"),
            ("README_ZH.md", "简体中文"),
            ("README_ZH_HANT.md", "繁體中文"),
            ("README_KO.md", "한국어"),
            ("README_JA.md", "日本語"),
            ("README_RU.md", "Русский"),
            ("README_FR.md", "Français"),
        ]
        let requiredLinks = [
            ("./README.md", "English"),
            ("./README_ZH.md", "简体中文"),
            ("./README_ZH_HANT.md", "繁體中文"),
            ("./README_KO.md", "한국어"),
            ("./README_JA.md", "日本語"),
            ("./README_RU.md", "Русский"),
            ("./README_FR.md", "Français"),
        ]

        for edition in editions {
            let url = root.appendingPathComponent(edition.file)
            let contents = try String(contentsOf: url, encoding: .utf8)
            #expect(!contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            for link in requiredLinks {
                if link.1 == edition.current {
                    #expect(contents.contains(link.1))
                } else {
                    #expect(contents.contains("[\(link.1)](\(link.0))"), "\(edition.file) missing \(link.1)")
                }
            }
        }
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            let candidate = url.appendingPathComponent("README.md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
