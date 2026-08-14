import AppKit
import CodexRunwayCore

/// Settings-window geometry derived from the localized native toolbar tabs.
enum ControlPanelLayout {
    static let minimumPanelWidth: CGFloat = 546
    static let panelHeight: CGFloat = 662
    static let horizontalContentPadding: CGFloat = 24
    /// Traffic lights and native toolbar margins measured around the tab group.
    static let titlebarChromeWidth: CGFloat = 104
    /// SwiftUI's installed equal-width tab group adds 10pt around its segments.
    static let nativeTabControlChromeWidth: CGFloat = 10
    /// Keeps the native tab group away from the exact overflow boundary.
    static let tabHeaderSafetyMargin: CGFloat = 8
    static let titleFontSize: CGFloat = 13
    @MainActor private static var cachedStripWidths: [[String]: CGFloat] = [:]

    @MainActor
    static func panelWidth(titles: [String]) -> CGFloat {
        max(
            minimumPanelWidth,
            naturalStripWidth(titles: titles)
                + titlebarChromeWidth
                + nativeTabControlChromeWidth
                + tabHeaderSafetyMargin)
    }

    @MainActor
    static func tabStripAvailableWidth(titles: [String]) -> CGFloat {
        panelWidth(titles: titles) - titlebarChromeWidth
    }

    @MainActor
    static func naturalStripWidth(titles: [String]) -> CGFloat {
        if let cached = cachedStripWidths[titles] {
            return cached
        }
        let control = makeTabStrip()
        apply(control, titles: titles, selectedIndex: 0)
        let width = ceil(control.fittingSize.width)
        cachedStripWidths[titles] = width
        return width
    }

    @MainActor
    static func needsTruncation(titles: [String]) -> Bool {
        naturalStripWidth(titles: titles) > tabStripAvailableWidth(titles: titles)
    }

    @MainActor
    static func contentSize(titles: [String]) -> NSSize {
        NSSize(width: panelWidth(titles: titles), height: panelHeight)
    }

    @MainActor
    private static func makeTabStrip() -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentStyle = .automatic
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.font = NSFont.systemFont(ofSize: titleFontSize)
        return control
    }

    @MainActor
    private static func apply(
        _ control: NSSegmentedControl,
        titles: [String],
        selectedIndex: Int)
    {
        control.segmentCount = titles.count
        for index in titles.indices {
            control.setLabel(titles[index], forSegment: index)
            control.setImage(nil, forSegment: index)
            control.setToolTip(titles[index], forSegment: index)
            control.setWidth(0, forSegment: index)
        }
        if titles.indices.contains(selectedIndex) {
            control.selectedSegment = selectedIndex
        }
        control.segmentDistribution = .fillEqually
    }

    @discardableResult
    @MainActor
    static func applyWindowLayout(
        _ window: NSWindow,
        title: String,
        titles: [String]) -> Bool
    {
        window.title = title
        let targetSize = contentSize(titles: titles)
        let currentSize = window.contentView?.bounds.size ?? window.contentLayoutRect.size
        let needsResize = abs(currentSize.width - targetSize.width) > 0.5
            || abs(currentSize.height - targetSize.height) > 0.5
        if needsResize {
            window.setContentSize(targetSize)
        }
        return needsResize
    }
}
