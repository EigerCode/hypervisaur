import AppKit
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
        case .virtualization(let machine): try VirtualizationGuestInput(machine: machine, captureRegion: await resolveCaptureRegion())
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

    func sendKey(_ keyCode: UInt16, isDown: Bool)

    /// Moves the pointer to a pixel of the display, with the buttons that are down.
    func movePointer(to point: CGPoint, buttons: [VMMouseButton: Int])

    func sendButton(_ button: VMMouseButton, isDown: Bool, clickCount: Int, at point: CGPoint, buttons: [VMMouseButton: Int])

    func scroll(dx: Int, dy: Int, at point: CGPoint, buttons: [VMMouseButton: Int])
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
                device.movePointer(to: point, buttons: buttons)
            case .button(let button, let isDown, let clickCount):
                guard let pointer else { continue }
                if isDown {
                    buttons[button] = clickCount
                } else {
                    guard buttons.removeValue(forKey: button) != nil else { continue }
                }
                device.sendButton(button, isDown: isDown, clickCount: clickCount, at: pointer, buttons: buttons)
            case .scroll(let dx, let dy):
                guard let pointer else { continue }
                device.scroll(dx: dx, dy: dy, at: pointer, buttons: buttons)
            case .key(let code, let isDown):
                if isDown {
                    guard !keys.contains(code) else { continue }
                    keys.append(code)
                } else {
                    guard let index = keys.firstIndex(of: code) else { continue }
                    keys.remove(at: index)
                }
                device.sendKey(code, isDown: isDown)
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
                device.sendButton(button, isDown: false, clickCount: clickCount, at: pointer, buttons: buttons)
            }
        }

        while let code = keys.popLast() {
            device.sendKey(code, isDown: false)
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

    func sendKey(_ keyCode: UInt16, isDown: Bool) {
        guard let keyNumber = QEMUKeyMap.keyNumber(forKeyCode: keyCode) else { return }
        machine.sendKey(keyNumber, isDown: isDown)
    }

    func movePointer(to point: CGPoint, buttons: [VMMouseButton: Int]) {
        sendPointer(at: point, buttons: pointerButtons(buttons))
    }

    func sendButton(_ button: VMMouseButton, isDown: Bool, clickCount: Int, at point: CGPoint, buttons: [VMMouseButton: Int]) {
        sendPointer(at: point, buttons: pointerButtons(buttons))
    }

    /// QEMU's pointer has wheel buttons, which are pressed and released once for each line.
    func scroll(dx: Int, dy: Int, at point: CGPoint, buttons: [VMMouseButton: Int]) {
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

/// Sends input to a guest that runs with Virtualization through its USB keyboard and screen coordinate pointing device,
/// with private API.
///
/// Virtualization has no public API for input. `VZVirtualMachineView` only passes on pointer events while the Mac's own
/// pointer is over it, so events made for it are dropped, but the private `_VZKeyboard` and
/// `_VZScreenCoordinatePointingDevice` objects that it sends its input to take events directly. The guest gets them as
/// input from its keyboard and mouse, whether the window is in front, behind other windows, or not open at all.
@MainActor
private struct VirtualizationGuestInput: GuestInputDevice {
    let keyboard: _VZKeyboard
    let pointingDevice: _VZScreenCoordinatePointingDevice
    let displaySize: (width: Int, height: Int)

    /// - Parameter captureRegion: The part of the window that screenshots capture. Positions are in the pixels of a
    ///   screenshot, which are the window's pixels.
    init(machine: VZVirtualMachine, captureRegion: VMCaptureRegion?) throws {
        let classNames = ["_VZKeyboard", "_VZKeyEvent", "_VZScreenCoordinatePointingDevice", "_VZScreenCoordinatePointerEvent", "_VZScrollWheelEvent"]
        guard classNames.allSatisfy({ NSClassFromString($0) != nil }),
              machine.responds(to: NSSelectorFromString("_keyboards")),
              machine.responds(to: NSSelectorFromString("_pointingDevices"))
        else {
            throw Failure("This version of macOS doesn’t offer keyboard and pointer input for virtual machines.")
        }

        guard let keyboard = machine._keyboards.first else {
            throw Failure("The virtual machine has no keyboard.")
        }
        guard let pointingDevice = machine._pointingDevices.lazy.compactMap({ $0 as? _VZScreenCoordinatePointingDevice }).first else {
            throw Failure("The virtual machine has no USB pointing device to send pointer input to.")
        }

        guard let captureRegion, let scale = NSApp.window(withWindowNumber: Int(captureRegion.windowID))?.backingScaleFactor else {
            throw Failure("The virtual machine’s display isn’t on screen.")
        }
        let displaySize = VMDisplayGeometry.pixelSize(of: captureRegion.rect, scale: scale)
        guard displaySize.width > 0, displaySize.height > 0 else {
            throw Failure("The virtual machine’s display has no size yet.")
        }

        self.keyboard = keyboard
        self.pointingDevice = pointingDevice
        self.displaySize = displaySize
    }

    func canSendKey(_ keyCode: UInt16) -> Bool { keyCode < 128 }

    func sendKey(_ keyCode: UInt16, isDown: Bool) {
        keyboard.send([_VZKeyEvent(type: isDown ? 0 : 1, keyCode: keyCode)])
    }

    func movePointer(to point: CGPoint, buttons: [VMMouseButton: Int]) {
        sendPointer(at: point, buttons: buttons)
    }

    func sendButton(_ button: VMMouseButton, isDown: Bool, clickCount: Int, at point: CGPoint, buttons: [VMMouseButton: Int]) {
        sendPointer(at: point, buttons: buttons)
    }

    func scroll(dx: Int, dy: Int, at point: CGPoint, buttons: [VMMouseButton: Int]) {
        sendPointer(at: point, buttons: buttons)

        /// An event from a scroll wheel, in lines, as opposed to the precise deltas of a trackpad.
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0),
              let event = NSEvent(cgEvent: cgEvent)
        else { return }

        pointingDevice.send([_VZScrollWheelEvent(event: event)])
    }

    /// The pointing device takes positions as fractions of the display's size, and the buttons that are down as a mask
    /// like `NSEvent.pressedMouseButtons`.
    private func sendPointer(at point: CGPoint, buttons: [VMMouseButton: Int]) {
        let pressedButtons = buttons.keys.reduce(0) { mask, button in
            switch button {
            case .left: mask | 1 << 0
            case .right: mask | 1 << 1
            }
        }
        let location = VMDisplayGeometry.normalizedLocation(ofPixel: point, displaySize: displaySize)

        pointingDevice.send([_VZScreenCoordinatePointerEvent(location: location, pressedButtons: pressedButtons)])
    }
}
