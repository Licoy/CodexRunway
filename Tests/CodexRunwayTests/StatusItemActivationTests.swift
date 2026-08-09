import AppKit
import Testing
@testable import CodexRunway
@testable import CodexRunwayCore

@Suite("Status item activation")
struct StatusItemActivationTests {
    @Test("plain left click resolves to the left mouse button")
    func plainLeftClick() throws {
        let activation = try #require(StatusItemActivation(
            modifierFlags: [],
            pressedMouseButtons: 1 << 0))

        #expect(activation.mouseButton == .left)
    }

    @Test("right mouse button state resolves to the right mouse button")
    func rightClick() throws {
        let activation = try #require(StatusItemActivation(
            modifierFlags: [],
            pressedMouseButtons: 1 << 1))

        #expect(activation.mouseButton == .right)
    }

    @Test("control-click resolves to the right mouse button")
    func controlClick() throws {
        let activation = try #require(StatusItemActivation(
            modifierFlags: [.control],
            pressedMouseButtons: 1 << 0))

        #expect(activation.mouseButton == .right)
    }

    @Test("command-modified activation is ignored")
    func commandClickIsIgnored() {
        let activation = StatusItemActivation(
            modifierFlags: [.command],
            pressedMouseButtons: 1 << 1)

        #expect(activation?.mouseButton == nil)
    }

    @Test("keyboard activation without a pressed mouse button defaults to left")
    func keyboardActivation() throws {
        let activation = try #require(StatusItemActivation(
            modifierFlags: [],
            pressedMouseButtons: 0))

        #expect(activation.mouseButton == .left)
    }

    @Test("identical activation snapshots are independently accepted")
    func repeatedActivation() throws {
        let first = try #require(StatusItemActivation(
            modifierFlags: [],
            pressedMouseButtons: 1 << 0))
        let second = try #require(StatusItemActivation(
            modifierFlags: [],
            pressedMouseButtons: 1 << 0))

        #expect(first.mouseButton == .left)
        #expect(second.mouseButton == .left)
    }

    @Test("left activation can show, close, and reopen the popover")
    func showCloseReopenSequence() throws {
        let firstClick = try #require(StatusItemActivation(
            modifierFlags: [],
            pressedMouseButtons: 1 << 0))
        let secondClick = try #require(StatusItemActivation(
            modifierFlags: [],
            pressedMouseButtons: 1 << 0))
        let thirdClick = try #require(StatusItemActivation(
            modifierFlags: [],
            pressedMouseButtons: 1 << 0))

        #expect(StatusInteraction.route(
            mouseButton: firstClick.mouseButton,
            isPopoverShown: false) == .showPopover)
        #expect(StatusInteraction.route(
            mouseButton: secondClick.mouseButton,
            isPopoverShown: true) == .closePopover)
        #expect(StatusInteraction.route(
            mouseButton: thirdClick.mouseButton,
            isPopoverShown: false) == .showPopover)
    }
}
