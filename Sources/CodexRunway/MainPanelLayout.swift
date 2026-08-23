import AppKit
import CodexRunwayCore

enum MainPanelLayout {
    static let width: CGFloat = 400
    static let defaultHeight = CGFloat(RunwayPreferences.defaultMainPanelHeight)
    static let minimumHeight = CGFloat(RunwayPreferences.minimumMainPanelHeight)
    static let maximumHeight = CGFloat(RunwayPreferences.maximumMainPanelHeight)

    /// Leaves room for the popover arrow and border inside the screen's visible frame.
    private static let popoverChromeAllowance: CGFloat = 16

    static var defaultSize: CGSize {
        CGSize(width: width, height: defaultHeight)
    }

    /// Screen coordinates stay stable while an NSPopover changes its own frame.
    /// Moving the bottom edge down lowers pointer Y and increases panel height.
    static func proposedHeight(
        startHeight: CGFloat,
        initialPointerY: CGFloat,
        currentPointerY: CGFloat
    ) -> CGFloat {
        startHeight + initialPointerY - currentPointerY
    }

    static func alignedHeight(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else { return height }
        return height.rounded()
    }

    static func frameKeepingTopEdge(
        _ frame: NSRect,
        size: NSSize,
        topEdge: CGFloat
    ) -> NSRect {
        var resizedFrame = frame
        resizedFrame.size = size
        resizedFrame.origin.y = topEdge - size.height
        return resizedFrame
    }

    static func clampedHeight(
        _ proposedHeight: CGFloat,
        availableScreenHeight: CGFloat? = nil
    ) -> CGFloat {
        let screenMaximum = availableScreenHeight.map {
            max(0, $0 - popoverChromeAllowance)
        } ?? maximumHeight
        let upperBound = min(maximumHeight, max(minimumHeight, screenMaximum))
        guard proposedHeight.isFinite else { return min(defaultHeight, upperBound) }
        return min(max(proposedHeight, minimumHeight), upperBound)
    }

    static func contentSize(
        height: CGFloat,
        availableScreenHeight: CGFloat? = nil
    ) -> NSSize {
        NSSize(
            width: width,
            height: clampedHeight(height, availableScreenHeight: availableScreenHeight))
    }
}
