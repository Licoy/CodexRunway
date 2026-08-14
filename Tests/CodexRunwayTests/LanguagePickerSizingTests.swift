import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Language picker sizing")
struct LanguagePickerSizingTests {
    @Test("selected-title width stays compact and ignores longest menu item")
    func selectedTitleDrivesCompactWidth() {
        let longestItem = "Simplified Chinese"
        let longestWidth = LanguagePickerSizing.measuredTitleWidth(longestItem)

        for preference in LanguagePreference.explicitCases {
            let title = preference.menuTitle(uiLanguage: .english)
            let width = LanguagePickerSizing.controlWidth(selectedTitle: title)
            #expect(width <= LanguagePickerSizing.compactCap)
            #expect(width >= LanguagePickerSizing.minimumWidth)
            #expect(width < longestWidth)
        }

        let englishWidth = LanguagePickerSizing.controlWidth(
            selectedTitle: LanguagePreference.english.menuTitle(uiLanguage: .english))
        #expect(englishWidth <= LanguagePickerSizing.compactCap)
        #expect(englishWidth < longestWidth)
        #expect(englishWidth < LanguagePickerSizing.measuredTitleWidth(longestItem) + LanguagePickerSizing.horizontalChrome)
    }

    @Test("Auto label follows the current UI language")
    func autoLabelFollowsUILanguage() {
        #expect(LanguagePreference.system.menuTitle(uiLanguage: .english) == "Auto")
        #expect(LanguagePreference.system.menuTitle(uiLanguage: .simplifiedChinese) == "自动")
        #expect(LanguagePreference.system.menuTitle(uiLanguage: .traditionalChinese) == "自動")
        #expect(LanguagePreference.system.menuTitle(uiLanguage: .korean) == "자동")
        #expect(LanguagePreference.system.menuTitle(uiLanguage: .japanese) == "自動")
        #expect(LanguagePreference.system.menuTitle(uiLanguage: .russian) == "Авто")
        #expect(LanguagePreference.system.menuTitle(uiLanguage: .french) == "Auto")
    }
}
