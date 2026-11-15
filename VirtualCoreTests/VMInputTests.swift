import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import VirtualCore

@MainActor
struct VMInputTests {
    /// Splits the events that type text back into keystrokes, by the modifiers that are down when each other key is pressed.
    private func keystrokes(in events: [VMInputEvent]) -> [VMKeystroke] {
        let modifierKeys: [UInt16: VMKeyModifiers] = [
            UInt16(kVK_Command): .command, UInt16(kVK_Control): .control, UInt16(kVK_Option): .option, UInt16(kVK_Shift): .shift,
        ]
        var modifiers = VMKeyModifiers()
        var strokes = [VMKeystroke]()

        for event in events {
            guard case .key(let code, let down) = event else { continue }
            if let modifier = modifierKeys[code] {
                if down { modifiers.insert(modifier) } else { modifiers.remove(modifier) }
            } else if down {
                strokes.append(VMKeystroke(keyCode: code, modifiers: modifiers))
            }
        }

        #expect(modifiers.isEmpty, "Every modifier is released")
        return strokes
    }

    @Test func typesOnTheUSLayout() throws {
        let layout = try VMKeyboardLayout()
        #expect(layout.identifier == "com.apple.keylayout.US")

        let strokes = keystrokes(in: try layout.events(typing: "Hello 123"))

        #expect(strokes.first == VMKeystroke(keyCode: UInt16(kVK_ANSI_H), modifiers: .shift))
        #expect(strokes[1] == VMKeystroke(keyCode: UInt16(kVK_ANSI_E)))
        #expect(strokes[5] == VMKeystroke(keyCode: UInt16(kVK_Space)))
        #expect(layout.text(typedBy: strokes) == "Hello 123")
    }

    @Test func typesOnTheSwissGermanLayout() throws {
        let layout = try VMKeyboardLayout(named: "Swiss German")
        #expect(layout.identifier == "com.apple.keylayout.SwissGerman")

        let text = "yz@#äöü"
        let strokes = keystrokes(in: try layout.events(typing: text))

        /// Swiss German swaps Y and Z.
        #expect(strokes[0] == VMKeystroke(keyCode: UInt16(kVK_ANSI_Z)))
        #expect(strokes[1] == VMKeystroke(keyCode: UInt16(kVK_ANSI_Y)))
        #expect(layout.text(typedBy: strokes) == text)
    }

    @Test func typesCharactersThatNeedADeadKey() throws {
        let layout = try VMKeyboardLayout(named: "com.apple.keylayout.SwissGerman")

        let strokes = try #require(layout.keystrokes(for: "ê"))

        #expect(strokes.count == 2)
        #expect(layout.text(typedBy: strokes) == "ê")
    }

    @Test func findsLayoutsByIdentifierOrName() throws {
        #expect(try VMKeyboardLayout(named: "U.S.").identifier == "com.apple.keylayout.US")
        #expect(try VMKeyboardLayout(named: "swissgerman").identifier == "com.apple.keylayout.SwissGerman")
        #expect(throws: Failure.self) { try VMKeyboardLayout(named: "Klingon") }
    }

    @Test func refusesTextThatTheLayoutCantType() throws {
        let layout = try VMKeyboardLayout()

        #expect(throws: Failure.self) { try layout.events(typing: "ok 🙂") }
    }

    @Test func typesNewlinesAndTabs() throws {
        let layout = try VMKeyboardLayout()

        let strokes = keystrokes(in: try layout.events(typing: "a\tb\n"))

        #expect(strokes.map(\.keyCode) == [kVK_ANSI_A, kVK_Tab, kVK_ANSI_B, kVK_Return].map { UInt16($0) })
    }

    @Test func pressesChords() throws {
        let layout = try VMKeyboardLayout()

        #expect(try layout.events(pressing: ["cmd+space"]) == [
            .key(code: UInt16(kVK_Command), down: true),
            .key(code: UInt16(kVK_Space), down: true),
            .key(code: UInt16(kVK_Space), down: false),
            .key(code: UInt16(kVK_Command), down: false),
        ])
        #expect(try layout.keystroke(forChord: "Return") == VMKeystroke(keyCode: UInt16(kVK_Return)))
        #expect(try layout.keystroke(forChord: "esc") == VMKeystroke(keyCode: UInt16(kVK_Escape)))
        #expect(try layout.keystroke(forChord: "f12") == VMKeystroke(keyCode: UInt16(kVK_F12)))
        #expect(try layout.keystroke(forChord: "win") == VMKeystroke(keyCode: UInt16(kVK_Command)))
        #expect(try layout.keystroke(forChord: "ctrl+alt+forward_delete") == VMKeystroke(keyCode: UInt16(kVK_ForwardDelete), modifiers: [.control, .option]))
        #expect(try layout.keystroke(forChord: "cmd++") == VMKeystroke(keyCode: UInt16(kVK_ANSI_Equal), modifiers: [.command, .shift]))
        #expect(throws: Failure.self) { try layout.keystroke(forChord: "hyper+a") }
        #expect(throws: Failure.self) { try layout.keystroke(forChord: "cmd+") }
    }

    @Test func shortcutsFollowTheLayout() throws {
        let layout = try VMKeyboardLayout(named: "Swiss German")

        #expect(try layout.keystroke(forChord: "cmd+z") == VMKeystroke(keyCode: UInt16(kVK_ANSI_Y), modifiers: .command))
    }

    @Test func encodesEvents() throws {
        let events: [VMInputEvent] = [.move(x: 10.5, y: 20), .button(.left, down: true, clickCount: 2), .scroll(dx: 0, dy: -3), .key(code: 36, down: false), .pause(milliseconds: 100)]

        let decoded = try JSONDecoder().decode([VMInputEvent].self, from: JSONEncoder().encode(events))

        #expect(decoded == events)
    }

    @Test func mapsScreenshotPixelsToThePointingDevice() {
        /// A display 1454×818 points at 2×, as a screenshot of the window captures it.
        let size = VMDisplayGeometry.pixelSize(of: CGRect(x: 0, y: 32, width: 1454, height: 818), scale: 2)
        #expect(size.width == 2908)
        #expect(size.height == 1636)

        #expect(VMDisplayGeometry.normalizedLocation(ofPixel: .zero, displaySize: size) == .zero)
        #expect(VMDisplayGeometry.normalizedLocation(ofPixel: CGPoint(x: 1454, y: 818), displaySize: size) == CGPoint(x: 0.5, y: 0.5))
        #expect(VMDisplayGeometry.normalizedLocation(ofPixel: CGPoint(x: 727, y: 1227), displaySize: size) == CGPoint(x: 0.25, y: 0.75))
    }
}
