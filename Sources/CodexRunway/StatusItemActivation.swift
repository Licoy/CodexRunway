import AppKit
import CodexRunwayCore

struct StatusItemActivation {
    let mouseButton: StatusMouseButton

    init?(
        modifierFlags: NSEvent.ModifierFlags,
        pressedMouseButtons: Int
    ) {
        guard !modifierFlags.contains(.command) else { return nil }

        let rightButtonPressed = (pressedMouseButtons & (1 << 1)) != 0
        mouseButton = rightButtonPressed || modifierFlags.contains(.control)
            ? .right
            : .left
    }

    static var current: StatusItemActivation? {
        StatusItemActivation(
            modifierFlags: NSEvent.modifierFlags,
            pressedMouseButtons: NSEvent.pressedMouseButtons)
    }
}
