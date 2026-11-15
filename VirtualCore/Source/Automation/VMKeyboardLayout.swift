import Carbon.HIToolbox
import Foundation

/// Modifier keys that are held down for a keystroke, pressed in the order they're declared and released in reverse.
public struct VMKeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = VMKeyModifiers(rawValue: 1 << 0)
    public static let control = VMKeyModifiers(rawValue: 1 << 1)
    public static let option = VMKeyModifiers(rawValue: 1 << 2)
    public static let shift = VMKeyModifiers(rawValue: 1 << 3)

    /// The virtual key codes of the left modifier keys, in the order they're pressed.
    var keyCodes: [UInt16] {
        [(VMKeyModifiers.command, kVK_Command), (.control, kVK_Control), (.option, kVK_Option), (.shift, kVK_Shift)]
            .filter { contains($0.0) }
            .map { UInt16($0.1) }
    }
}

/// A key that's pressed while modifier keys are held down.
public struct VMKeystroke: Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: VMKeyModifiers

    public init(keyCode: UInt16, modifiers: VMKeyModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// Turns text and key names into the key presses that type them on one of the keyboard layouts that macOS has,
/// so that text comes out right when the guest uses the same layout.
///
/// Characters that need a dead key, such as `ê` on many layouts, are typed with the dead key followed by the key that
/// completes them.
public struct VMKeyboardLayout: Sendable {
    public static let defaultIdentifier = "com.apple.keylayout.US"

    /// The input source identifier, such as `com.apple.keylayout.SwissGerman`.
    public let identifier: String
    /// The layout's name in the Mac's language, such as “Swiss German”.
    public let name: String

    private let layoutData: Data
    private let keystrokes: [Character: [VMKeystroke]]

    /// The layout with an input source identifier such as `com.apple.keylayout.SwissGerman`, or a name such as
    /// “Swiss German”, which may also be the English name when the Mac uses another language. Defaults to U.S.
    @MainActor
    public init(named nameOrIdentifier: String? = nil) throws {
        let wanted = nameOrIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? Self.defaultIdentifier
        let normalizedWanted = Self.normalized(wanted)

        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        let sources = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []

        for source in sources {
            guard let identifier = source.stringProperty(kTISPropertyInputSourceID) else { continue }
            let name = source.stringProperty(kTISPropertyLocalizedName) ?? identifier
            let shortIdentifier = identifier.replacingOccurrences(of: "com.apple.keylayout.", with: "")

            guard identifier.caseInsensitiveCompare(wanted) == .orderedSame
                    || Self.normalized(name) == normalizedWanted
                    || Self.normalized(shortIdentifier) == normalizedWanted
            else { continue }

            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
                throw Failure("The keyboard layout “\(name)” can’t be used to type.")
            }

            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            self.init(identifier: identifier, name: name, layoutData: data)
            return
        }

        throw Failure("Couldn’t find the keyboard layout “\(wanted)”. Pass the name of a macOS keyboard layout, such as “Swiss German”, or its input source ID, such as com.apple.keylayout.SwissGerman.")
    }

    private init(identifier: String, name: String, layoutData: Data) {
        self.identifier = identifier
        self.name = name
        self.layoutData = layoutData
        self.keystrokes = Self.keystrokes(in: layoutData)
    }

    /// Lowercase letters and digits only, so that “U.S.” matches “US” and “Swiss German” matches “SwissGerman”.
    private static func normalized(_ string: String) -> String {
        String(string.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: - Typing

    /// The keystrokes that type a character, which are two for characters that need a dead key.
    public func keystrokes(for character: Character) -> [VMKeystroke]? {
        switch character {
        case "\n", "\r", "\r\n": [VMKeystroke(keyCode: UInt16(kVK_Return))]
        case "\t": [VMKeystroke(keyCode: UInt16(kVK_Tab))]
        default: keystrokes[character]
        }
    }

    /// The events that type some text.
    /// - Throws: When the layout has no keys for some of the characters, before making any events.
    public func events(typing text: String) throws -> [VMInputEvent] {
        var events = [VMInputEvent]()
        var missing = [Character]()

        for character in text {
            guard let strokes = keystrokes(for: character) else {
                if !missing.contains(character) { missing.append(character) }
                continue
            }
            strokes.forEach { events.append(contentsOf: Self.events(for: $0)) }
        }

        guard missing.isEmpty else {
            let list = missing.map { "“\($0)”" }.joined(separator: ", ")
            throw Failure("The keyboard layout “\(name)” can’t type \(list). Pass the layout that the guest uses.")
        }
        return events
    }

    /// The events that press key chords one after another, such as `cmd+space`, `return` or `ctrl+alt+delete`.
    ///
    /// A chord is key names joined by `+`, where all but the last are modifiers. A key that's a single character is
    /// found on the layout, so that shortcuts such as `cmd+z` press the key that types “z” in the guest.
    public func events(pressing chords: [String]) throws -> [VMInputEvent] {
        try chords.flatMap { Self.events(for: try keystroke(forChord: $0)) }
    }

    func keystroke(forChord chord: String) throws -> VMKeystroke {
        var parts = chord.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        /// A chord that ends in “+” presses the key that types it, such as “cmd++”.
        if parts.count >= 2, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
            parts.removeLast(2)
            parts.append("+")
        }

        guard let keyName = parts.last, !parts.contains(where: \.isEmpty) else {
            throw Failure("“\(chord)” isn’t a key or a combination of keys such as “cmd+space”.")
        }

        var modifiers = VMKeyModifiers()
        for name in parts.dropLast() {
            guard let modifier = Self.modifiers[name.lowercased()] else {
                throw Failure("“\(name)” in “\(chord)” isn’t a modifier key. Modifiers are cmd, ctrl, alt, shift and win.")
            }
            modifiers.insert(modifier.modifier)
        }

        if let modifier = Self.modifiers[keyName.lowercased()] {
            return VMKeystroke(keyCode: modifier.keyCode, modifiers: modifiers)
        }
        if let keyCode = Self.namedKeys[keyName.lowercased()] {
            return VMKeystroke(keyCode: keyCode, modifiers: modifiers)
        }
        if keyName.count == 1, let strokes = keystrokes(for: keyName.first!) {
            guard strokes.count == 1 else {
                throw Failure("“\(keyName)” needs more than one key on the keyboard layout “\(name)”, so it can’t be part of a combination of keys.")
            }
            return VMKeystroke(keyCode: strokes[0].keyCode, modifiers: modifiers.union(strokes[0].modifiers))
        }

        throw Failure("“\(keyName)” isn’t a key name or a character that the keyboard layout “\(name)” can type. Key names are return, escape, tab, space, delete, forward_delete, up, down, left, right, home, end, pageup, pagedown and f1 to f12.")
    }

    /// Presses the modifiers, then presses and releases the key, then releases the modifiers.
    static func events(for stroke: VMKeystroke) -> [VMInputEvent] {
        let modifiers = stroke.modifiers.keyCodes
        return modifiers.map { .key(code: $0, down: true) }
            + [.key(code: stroke.keyCode, down: true), .key(code: stroke.keyCode, down: false)]
            + modifiers.reversed().map { .key(code: $0, down: false) }
    }

    private static let modifiers: [String: (modifier: VMKeyModifiers, keyCode: UInt16)] = {
        let command = (VMKeyModifiers.command, UInt16(kVK_Command))
        let control = (VMKeyModifiers.control, UInt16(kVK_Control))
        let option = (VMKeyModifiers.option, UInt16(kVK_Option))
        let shift = (VMKeyModifiers.shift, UInt16(kVK_Shift))
        /// The Windows key is where Command is, and QEMU's key map makes Command the Windows key.
        return [
            "cmd": command, "command": command, "win": command, "windows": command, "super": command,
            "ctrl": control, "control": control,
            "alt": option, "option": option, "opt": option,
            "shift": shift,
        ]
    }()

    private static let namedKeys: [String: UInt16] = {
        var keys: [String: Int] = [
            "return": kVK_Return, "enter": kVK_Return,
            "escape": kVK_Escape, "esc": kVK_Escape,
            "tab": kVK_Tab,
            "space": kVK_Space,
            "delete": kVK_Delete, "backspace": kVK_Delete,
            "forward_delete": kVK_ForwardDelete, "forwarddelete": kVK_ForwardDelete,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "home": kVK_Home, "end": kVK_End,
            "pageup": kVK_PageUp, "page_up": kVK_PageUp, "pagedown": kVK_PageDown, "page_down": kVK_PageDown,
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, keyCode) in functionKeys.enumerated() {
            keys["f\(index + 1)"] = keyCode
        }
        return keys.mapValues { UInt16($0) }
    }()

    // MARK: - Translation

    /// The modifier combinations that characters are looked for with, from the one that's most likely meant.
    private static let characterModifiers: [VMKeyModifiers] = [[], [.shift], [.option], [.shift, .option]]

    /// Keys whose characters are typed with the keys on the main part of the keyboard instead, since the keypad's keys
    /// depend on Num Lock in some guests.
    private static let keypadKeyCodes: Set<Int> = [
        kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadClear, kVK_ANSI_KeypadDivide,
        kVK_ANSI_KeypadEnter, kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadEquals, kVK_ANSI_Keypad0, kVK_ANSI_Keypad1,
        kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7,
        kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
    ]

    private static let typingKeyCodes = (UInt16(0)..<128).filter { !keypadKeyCodes.contains(Int($0)) }

    // ponytail: assumes the guest's keyboard is ANSI, which only matters for the keys that ISO keyboards have in other
    // places, such as “<” and “§” on European layouts; pass the guest's keyboard type here if those come out wrong.
    private static let keyboardType = UInt32(40)

    /// Every character that the layout types with one keystroke, or with a dead key followed by another keystroke.
    private static func keystrokes(in layoutData: Data) -> [Character: [VMKeystroke]] {
        var result = [Character: [VMKeystroke]]()
        var deadKeys = [(VMKeystroke, UInt32)]()

        for modifiers in characterModifiers {
            for keyCode in typingKeyCodes {
                let stroke = VMKeystroke(keyCode: keyCode, modifiers: modifiers)
                var deadKeyState: UInt32 = 0
                let output = translate(stroke, deadKeyState: &deadKeyState, in: layoutData)

                if output.isEmpty, deadKeyState != 0 {
                    deadKeys.append((stroke, deadKeyState))
                } else if let character = typedCharacter(output), result[character] == nil {
                    result[character] = [stroke]
                }
            }
        }

        for (deadKey, state) in deadKeys {
            for modifiers in characterModifiers {
                for keyCode in typingKeyCodes {
                    let stroke = VMKeystroke(keyCode: keyCode, modifiers: modifiers)
                    var deadKeyState = state
                    let output = translate(stroke, deadKeyState: &deadKeyState, in: layoutData)

                    if let character = typedCharacter(output), result[character] == nil {
                        result[character] = [deadKey, stroke]
                    }
                }
            }
        }

        return result
    }

    /// The text that keystrokes type, from the start of a line with no dead key pending.
    func text(typedBy strokes: [VMKeystroke]) -> String {
        var deadKeyState: UInt32 = 0
        return strokes.map { Self.translate($0, deadKeyState: &deadKeyState, in: layoutData) }.joined()
    }

    private static func typedCharacter(_ output: String) -> Character? {
        guard output.count == 1, let character = output.first,
              !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .privateUse })
        else { return nil }
        return character
    }

    private static func translate(_ stroke: VMKeystroke, deadKeyState: inout UInt32, in layoutData: Data) -> String {
        var carbonModifiers = 0
        if stroke.modifiers.contains(.shift) { carbonModifiers |= shiftKey }
        if stroke.modifiers.contains(.option) { carbonModifiers |= optionKey }
        if stroke.modifiers.contains(.control) { carbonModifiers |= controlKey }
        if stroke.modifiers.contains(.command) { carbonModifiers |= cmdKey }

        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0

        let status = layoutData.withUnsafeBytes { buffer in
            UCKeyTranslate(
                buffer.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self),
                stroke.keyCode,
                UInt16(kUCKeyActionDown),
                UInt32(carbonModifiers >> 8) & 0xFF,
                keyboardType,
                0,
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }

        guard status == noErr else { return "" }
        return String(utf16CodeUnits: characters, count: length)
    }
}

private extension TISInputSource {
    func stringProperty(_ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(self, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
