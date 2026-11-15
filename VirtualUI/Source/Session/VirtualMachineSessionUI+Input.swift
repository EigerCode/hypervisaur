import AppKit
import Carbon.HIToolbox
import Virtualization
import VirtualCore

extension VirtualMachineSessionUI {
    /// Sends keyboard and pointer input to the guest as if it came from its keyboard and mouse.
    ///
    /// Events are sent a moment apart, like a person would, and any key or button that's still down at the end is released.
    /// - Returns: The size of the display in pixels, which is the size of a screenshot from ``screenshot()``.
    @MainActor
    public func sendInput(_ events: [VMInputEvent]) async throws -> (width: Int, height: Int) {
        guard let runtime = displayedRuntime else {
            throw Failure("“\(virtualMachine.name)” isn’t running.")
        }

        let device: any GuestInputDevice = switch runtime {
        case .qemu(let machine): try QEMUGuestInput(machine: machine)
        case .virtualization(let machine): try VirtualizationGuestInput(machine: machine, displayView: displayView)
        }

        try GuestInputPlayer.validate(events, for: device)

        let player = GuestInputPlayer(device: device)
        defer { player.releaseAll() }

        try await player.play(events)

        return device.displaySize
    }
}

/// What input is sent through for a guest.
@MainActor
private protocol GuestInputDevice {
    /// The display's size in pixels, which is the size of a screenshot.
    var displaySize: (width: Int, height: Int) { get }

    func canSendKey(_ keyCode: UInt16) -> Bool

    /// Sends a key press or release, with the modifier keys that are down after it.
    func sendKey(_ keyCode: UInt16, isDown: Bool, modifiers: Set<UInt16>)

    /// Moves the pointer to a pixel of the display, with the buttons that are down.
    func movePointer(to point: CGPoint, buttons: [VMMouseButton: Int], modifiers: Set<UInt16>)

    func sendButton(_ button: VMMouseButton, isDown: Bool, clickCount: Int, at point: CGPoint, buttons: [VMMouseButton: Int], modifiers: Set<UInt16>)

    func scroll(dx: Int, dy: Int, at point: CGPoint, buttons: [VMMouseButton: Int], modifiers: Set<UInt16>)
}

/// Sends events to a guest one after another, keeping track of the keys and buttons that are down.
@MainActor
private final class GuestInputPlayer {
    /// The time between events, so that the guest sees each of them.
    static let eventInterval = Duration.milliseconds(10)
    /// How long a mouse button is held down for a click.
    static let clickDuration = Duration.milliseconds(40)

    static let maximumPause = 60_000
    static let maximumScrollLines = 100

    private let device: any GuestInputDevice
    private var pointer: CGPoint?
    /// The buttons that are down, with the click count they were pressed with.
    private var buttons = [VMMouseButton: Int]()
    /// The keys that are down, in the order they were pressed.
    private var keys = [UInt16]()

    init(device: any GuestInputDevice) {
        self.device = device
    }

    /// Checks all events before any are sent, so that a request that can't be done doesn't do part of it.
    static func validate(_ events: [VMInputEvent], for device: any GuestInputDevice) throws {
        let size = device.displaySize
        var hasPointer = false

        for event in events {
            switch event {
            case .move(let x, let y):
                guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < Double(size.width), y < Double(size.height) else {
                    throw Failure("The point \(x.formatted()), \(y.formatted()) isn’t on the display, which is \(size.width)×\(size.height) pixels.")
                }
                hasPointer = true
            case .button(_, _, let clickCount):
                guard hasPointer else { throw Failure("The pointer must be moved before a button is pressed.") }
                guard (1...3).contains(clickCount) else { throw Failure("A click count must be 1, 2 or 3.") }
            case .scroll(let dx, let dy):
                guard hasPointer else { throw Failure("The pointer must be moved before scrolling.") }
                guard abs(dx) <= maximumScrollLines, abs(dy) <= maximumScrollLines else {
                    throw Failure("Scrolling is limited to \(maximumScrollLines) lines at a time.")
                }
            case .key(let code, _):
                guard device.canSendKey(code) else { throw Failure("The key with code \(code) can’t be sent to the virtual machine.") }
            case .pause(let milliseconds):
                guard (0...maximumPause).contains(milliseconds) else {
                    throw Failure("A pause must be between 0 and \(maximumPause) milliseconds.")
                }
            }
        }
    }

    func play(_ events: [VMInputEvent]) async throws {
        var previous: VMInputEvent?

        for event in events {
            if let previous {
                let isClick = if case .button(_, true, _) = previous, case .button(_, false, _) = event { true } else { false }
                try await Task.sleep(for: isClick ? Self.clickDuration : Self.eventInterval)
            }
            previous = event

            switch event {
            case .move(let x, let y):
                let point = CGPoint(x: x, y: y)
                pointer = point
                device.movePointer(to: point, buttons: buttons, modifiers: Set(keys))
            case .button(let button, let isDown, let clickCount):
                guard let pointer else { continue }
                if isDown {
                    buttons[button] = clickCount
                } else {
                    guard buttons.removeValue(forKey: button) != nil else { continue }
                }
                device.sendButton(button, isDown: isDown, clickCount: clickCount, at: pointer, buttons: buttons, modifiers: Set(keys))
            case .scroll(let dx, let dy):
                guard let pointer else { continue }
                device.scroll(dx: dx, dy: dy, at: pointer, buttons: buttons, modifiers: Set(keys))
            case .key(let code, let isDown):
                if isDown {
                    guard !keys.contains(code) else { continue }
                    keys.append(code)
                } else {
                    guard let index = keys.firstIndex(of: code) else { continue }
                    keys.remove(at: index)
                }
                device.sendKey(code, isDown: isDown, modifiers: Set(keys))
            case .pause(let milliseconds):
                try await Task.sleep(for: .milliseconds(milliseconds))
            }
        }
    }

    /// Releases whatever is still down, so that the guest isn't left with a key or button held.
    func releaseAll() {
        if let pointer {
            for (button, clickCount) in buttons {
                buttons[button] = nil
                device.sendButton(button, isDown: false, clickCount: clickCount, at: pointer, buttons: buttons, modifiers: Set(keys))
            }
        }

        while let code = keys.popLast() {
            device.sendKey(code, isDown: false, modifiers: Set(keys))
        }
    }
}

// MARK: - QEMU

/// Sends input through QEMU's keyboard and its absolute pointing device, so it doesn't matter whether the window is visible.
@MainActor
private struct QEMUGuestInput: GuestInputDevice {
    let machine: QEMUVirtualMachine
    let displaySize: (width: Int, height: Int)

    init(machine: QEMUVirtualMachine) throws {
        guard let size = machine.displaySurface?.bounds.size, size.width > 0, size.height > 0 else {
            throw Failure("The virtual machine hasn’t shown anything on its display yet.")
        }
        self.machine = machine
        self.displaySize = (Int(size.width), Int(size.height))
    }

    func canSendKey(_ keyCode: UInt16) -> Bool {
        QEMUKeyMap.keyNumber(forKeyCode: keyCode) != nil
    }

    func sendKey(_ keyCode: UInt16, isDown: Bool, modifiers: Set<UInt16>) {
        guard let keyNumber = QEMUKeyMap.keyNumber(forKeyCode: keyCode) else { return }
        machine.sendKey(keyNumber, isDown: isDown)
    }

    func movePointer(to point: CGPoint, buttons: [VMMouseButton: Int], modifiers: Set<UInt16>) {
        sendPointer(at: point, buttons: pointerButtons(buttons))
    }

    func sendButton(_ button: VMMouseButton, isDown: Bool, clickCount: Int, at point: CGPoint, buttons: [VMMouseButton: Int], modifiers: Set<UInt16>) {
        sendPointer(at: point, buttons: pointerButtons(buttons))
    }

    /// QEMU's pointer has wheel buttons, which are pressed and released once for each line.
    func scroll(dx: Int, dy: Int, at point: CGPoint, buttons: [VMMouseButton: Int], modifiers: Set<UInt16>) {
        let pressed = pointerButtons(buttons)

        func turn(_ wheel: VNCClient.PointerButtons, times: Int) {
            for _ in 0..<abs(times) {
                sendPointer(at: point, buttons: pressed.union(wheel))
                sendPointer(at: point, buttons: pressed)
            }
        }

        turn(dy > 0 ? .wheelUp : .wheelDown, times: dy)
        turn(dx > 0 ? .wheelLeft : .wheelRight, times: dx)
    }

    private func sendPointer(at point: CGPoint, buttons: VNCClient.PointerButtons) {
        machine.sendPointer(x: Int(point.x.rounded(.down)), y: Int(point.y.rounded(.down)), buttons: buttons)
    }

    private func pointerButtons(_ buttons: [VMMouseButton: Int]) -> VNCClient.PointerButtons {
        buttons.keys.reduce(into: []) { result, button in
            switch button {
            case .left: result.insert(.left)
            case .right: result.insert(.right)
            }
        }
    }
}

// MARK: - Virtualization

/// Sends input to a guest that runs with Virtualization, which has no public API for it.
///
/// Input is sent as `NSEvent`s made here and given straight to the `VZVirtualMachineView` that shows the guest, in this
/// process, which turns them into input from the guest's USB keyboard and pointer, the same as events from the Mac's own
/// keyboard and mouse. The events aren't posted to the window server or the app, so they don't depend on the window being
/// key or the app being active, and they don't move the Mac's own pointer. The view must be in a window, since it places
/// the guest's pointer from where events are in it.
@MainActor
private struct VirtualizationGuestInput: GuestInputDevice {
    let view: VirtualBuddyVMView
    let window: NSWindow
    /// The part of the window that screenshots capture, in points, with the origin at the window's top left corner.
    let captureRect: CGRect
    let scale: CGFloat
    let displaySize: (width: Int, height: Int)

    init(machine: VZVirtualMachine, displayView: NSView?) throws {
        guard let displayView, let window = displayView.window, let region = VMCaptureRegion(view: displayView) else {
            throw Failure("The virtual machine’s window must be open to send it input.")
        }
        guard let view = Self.virtualMachineView(showing: machine, in: window.contentView) else {
            throw Failure("The virtual machine’s display isn’t in its window.")
        }

        self.view = view
        self.window = window
        self.captureRect = region.rect
        self.scale = window.backingScaleFactor
        self.displaySize = VMDisplayGeometry.pixelSize(of: region.rect, scale: scale)
    }

    private static func virtualMachineView(showing machine: VZVirtualMachine, in view: NSView?) -> VirtualBuddyVMView? {
        guard let view else { return nil }
        if let vmView = view as? VirtualBuddyVMView, vmView.virtualMachine === machine {
            return vmView
        }
        return view.subviews.lazy.compactMap { virtualMachineView(showing: machine, in: $0) }.first
    }

    func canSendKey(_ keyCode: UInt16) -> Bool { keyCode < 128 }

    func sendKey(_ keyCode: UInt16, isDown: Bool, modifiers: Set<UInt16>) {
        guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) else { return }

        cgEvent.flags = Self.flags(for: modifiers)
        if Self.modifierFlags[keyCode] != nil {
            cgEvent.type = .flagsChanged
        }

        guard let event = NSEvent(cgEvent: cgEvent) else { return }
        view.deliverSynthesizedEvent(event)
    }

    func movePointer(to point: CGPoint, buttons: [VMMouseButton: Int], modifiers: Set<UInt16>) {
        let type: NSEvent.EventType = if buttons[.left] != nil { .leftMouseDragged } else if buttons[.right] != nil { .rightMouseDragged } else { .mouseMoved }
        sendMouseEvent(type, at: point, clickCount: buttons[.left] ?? buttons[.right] ?? 0, modifiers: modifiers)
    }

    func sendButton(_ button: VMMouseButton, isDown: Bool, clickCount: Int, at point: CGPoint, buttons: [VMMouseButton: Int], modifiers: Set<UInt16>) {
        let type: NSEvent.EventType = switch (button, isDown) {
        case (.left, true): .leftMouseDown
        case (.left, false): .leftMouseUp
        case (.right, true): .rightMouseDown
        case (.right, false): .rightMouseUp
        }
        sendMouseEvent(type, at: point, clickCount: clickCount, modifiers: modifiers)
    }

    func scroll(dx: Int, dy: Int, at point: CGPoint, buttons: [VMMouseButton: Int], modifiers: Set<UInt16>) {
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }

        /// Scroll events are placed on the screen, in Core Graphics' coordinates, which have their origin at the top left
        /// corner of the main display.
        let screenPoint = window.convertPoint(toScreen: windowLocation(of: point))
        let mainDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        cgEvent.location = CGPoint(x: screenPoint.x, y: mainDisplayHeight - screenPoint.y)
        cgEvent.flags = Self.flags(for: modifiers)
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))

        guard let event = NSEvent(cgEvent: cgEvent) else { return }
        view.deliverSynthesizedEvent(event)
    }

    private func sendMouseEvent(_ type: NSEvent.EventType, at point: CGPoint, clickCount: Int, modifiers: Set<UInt16>) {
        let isUp = type == .leftMouseUp || type == .rightMouseUp

        guard let event = NSEvent.mouseEvent(
            with: type,
            location: windowLocation(of: point),
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(Self.flags(for: modifiers).rawValue)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: isUp || type == .mouseMoved ? 0 : 1
        ) else { return }

        view.deliverSynthesizedEvent(event)
    }

    private func windowLocation(of point: CGPoint) -> CGPoint {
        VMDisplayGeometry.windowLocation(ofPixel: point, in: captureRect, scale: scale, windowHeight: window.frame.height)
    }

    /// The modifier flags for the modifier keys that are down, including the device-dependent flags from IOKit that tell
    /// the left and right keys apart.
    private static func flags(for keys: Set<UInt16>) -> CGEventFlags {
        keys.reduce(into: CGEventFlags()) { flags, keyCode in
            guard let modifier = modifierFlags[keyCode] else { return }
            flags.insert(modifier.flag)
            flags.insert(CGEventFlags(rawValue: modifier.deviceFlag))
        }
    }

    private static let modifierFlags: [UInt16: (flag: CGEventFlags, deviceFlag: UInt64)] = [
        UInt16(kVK_Control): (.maskControl, 0x0001),
        UInt16(kVK_Shift): (.maskShift, 0x0002),
        UInt16(kVK_RightShift): (.maskShift, 0x0004),
        UInt16(kVK_Command): (.maskCommand, 0x0008),
        UInt16(kVK_RightCommand): (.maskCommand, 0x0010),
        UInt16(kVK_Option): (.maskAlternate, 0x0020),
        UInt16(kVK_RightOption): (.maskAlternate, 0x0040),
        UInt16(kVK_RightControl): (.maskControl, 0x2000),
    ]
}
