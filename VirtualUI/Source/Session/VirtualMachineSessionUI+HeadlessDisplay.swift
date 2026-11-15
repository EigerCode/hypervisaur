import AppKit
import Virtualization
import VirtualCore

/// How long a new headless display needs before ScreenCaptureKit sees what the guest shows in it.
private let headlessDisplayWarmUp = Duration.milliseconds(1500)

extension VirtualMachineSessionUI {
    /// The part of the window that screenshots and input use, which is a hidden window of its own while a Virtualization
    /// guest has no window to show it.
    ///
    /// A Virtualization display can only be captured through a window, and the only public way to show one is
    /// `VZVirtualMachineView`, so the guest is shown in a window that sits behind the desktop picture.
    @MainActor
    func resolveCaptureRegion() async throws -> VMCaptureRegion? {
        /// The window's own view takes over once it registers, but it may not have yet while the window opens, so whether
        /// there's a view to capture decides, and not whether there's a window.
        if captureRegion == nil, case .virtualization(let machine) = displayedRuntime {
            if let window = headlessDisplayWindow {
                displayView = window.contentView
            } else {
                try openHeadlessDisplay(for: machine)
            }
        }

        /// Closing the hidden window cancels the wait, and then there's whatever view has taken over.
        try? await headlessDisplayReady?.value

        return captureRegion
    }

    /// Closes the hidden window, so that the guest's own window can show the display.
    @MainActor
    func closeHeadlessDisplay() {
        guard let window = headlessDisplayWindow else { return }

        headlessDisplayReady?.cancel()
        headlessDisplayReady = nil
        headlessDisplayWindow = nil

        (window.contentView as? VZVirtualMachineView)?.virtualMachine = nil
        window.close()

        if displayView === window.contentView {
            displayView = nil
        }
    }

    @MainActor
    private func openHeadlessDisplay(for machine: VZVirtualMachine) throws {
        guard let display = machine.graphicsDevices.first?.displays.first,
              display.sizeInPixels.width > 0, display.sizeInPixels.height > 0
        else {
            throw Failure("The virtual machine’s display has no size yet.")
        }

        /// The window has to be on a screen, or ScreenCaptureKit can't capture it.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw Failure("There’s no screen to capture the virtual machine’s display on.")
        }

        /// The window's pixels are the display's pixels, so that screenshots are at the guest's resolution, unless that's
        /// larger than the screen: a window that doesn't fit is cut off, so it's made smaller, keeping the display's shape.
        let scale = screen.backingScaleFactor
        let fullSize = CGSize(width: display.sizeInPixels.width / scale, height: display.sizeInPixels.height / scale)
        let fit = min(1, screen.frame.width / fullSize.width, screen.frame.height / fullSize.height)
        let size = CGSize(width: (fullSize.width * fit).rounded(.down), height: (fullSize.height * fit).rounded(.down))

        let view = VZVirtualMachineView(frame: CGRect(origin: .zero, size: size))
        view.virtualMachine = machine

        let window = NSWindow(contentRect: CGRect(origin: screen.frame.origin, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.orderBack(nil)

        headlessDisplayWindow = window
        displayView = view
        headlessDisplayReady = Task { try await Task.sleep(for: headlessDisplayWarmUp) }
    }
}
