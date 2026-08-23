import AppKit
import Foundation
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Main panel resizing")
struct MainPanelResizeTests {
    @Test("stable screen coordinates change height in the pointer direction")
    func screenPointerMovement() {
        #expect(MainPanelLayout.proposedHeight(
            startHeight: 584,
            initialPointerY: 300,
            currentPointerY: 180) == 704)
        #expect(MainPanelLayout.proposedHeight(
            startHeight: 584,
            initialPointerY: 300,
            currentPointerY: 384) == 500)
    }

    @Test("height updates align to whole window points")
    func alignedHeight() {
        #expect(MainPanelLayout.alignedHeight(584.49) == 584)
        #expect(MainPanelLayout.alignedHeight(584.5) == 585)
    }

    @Test("resizing preserves the anchored top edge")
    func anchoredTopEdge() {
        let frame = NSRect(x: 100, y: 200, width: 400, height: 584)
        let resized = MainPanelLayout.frameKeepingTopEdge(
            frame,
            size: NSSize(width: 400, height: 700),
            topEdge: frame.maxY)

        #expect(resized.maxY == frame.maxY)
        #expect(resized.minY == 84)
    }

    @Test("height stays within product and screen bounds")
    func heightBounds() {
        #expect(MainPanelLayout.clampedHeight(200) == MainPanelLayout.minimumHeight)
        #expect(MainPanelLayout.clampedHeight(1_200) == MainPanelLayout.maximumHeight)
        #expect(MainPanelLayout.clampedHeight(
            800,
            availableScreenHeight: 700) == 684)
        #expect(MainPanelLayout.clampedHeight(
            200,
            availableScreenHeight: 320) == MainPanelLayout.minimumHeight)
    }

    @Test("invalid height falls back to the shipped default")
    func invalidHeight() {
        #expect(MainPanelLayout.clampedHeight(.infinity) == MainPanelLayout.defaultHeight)
    }

    @Test("persisting panel height skips unrelated settings rebuilds")
    @MainActor
    func heightPersistenceIsGeometryOnly() {
        let suiteName = "CodexRunwayPanelHeight-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PreferencesStore(defaults: defaults)
        let settings = RunwaySettings(store: store)
        var broadChangeCount = 0
        settings.onChange = { broadChangeCount += 1 }

        settings.updateMainPanelHeight(720)

        #expect(settings.preferences.mainPanelHeight == 720)
        #expect(store.load().mainPanelHeight == 720)
        #expect(broadChangeCount == 0)
    }
}
