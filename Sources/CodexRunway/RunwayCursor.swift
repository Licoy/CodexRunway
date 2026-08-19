import AppKit
import SwiftUI

/// Balanced cursor for hoverable controls. `NSCursor.push/pop` is an
/// app-global stack, so every push must be matched even when the hovered view is
/// removed by its own click action (SwiftUI delivers no closing onHover then) or
/// the control becomes disabled mid-hover.
private struct RunwayCursor: ViewModifier {
    var cursor: NSCursor
    var isEnabled: Bool

    @State private var isHovering = false
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                sync()
            }
            .onChange(of: isEnabled) { _ in
                sync()
            }
            .onDisappear {
                isHovering = false
                sync()
            }
    }

    private func sync() {
        let wantsCursor = isHovering && isEnabled
        guard wantsCursor != pushed else { return }
        pushed = wantsCursor
        if wantsCursor {
            cursor.push()
        } else {
            NSCursor.pop()
        }
    }
}

extension View {
    /// Shows the pointing-hand cursor while hovered; pops it when the pointer
    /// leaves, the control disables, or the view unmounts.
    func pointingHandCursor(enabled: Bool = true) -> some View {
        modifier(RunwayCursor(cursor: .pointingHand, isEnabled: enabled))
    }

    /// Shows the vertical resize cursor while hovering a draggable panel edge.
    func verticalResizeCursor(enabled: Bool = true) -> some View {
        modifier(RunwayCursor(cursor: .resizeUpDown, isEnabled: enabled))
    }
}
