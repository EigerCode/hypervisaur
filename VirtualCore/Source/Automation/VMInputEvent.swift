import CoreGraphics

public enum VMMouseButton: String, Codable, Sendable {
    case left
    case right
}

/// Keyboard and pointer input that's sent to a virtual machine as if it came from its keyboard and mouse,
/// such as on behalf of `vbmcp`.
public enum VMInputEvent: Codable, Sendable, Equatable {
    /// Moves the pointer to a pixel of a full-size screenshot of the display, with the origin at its top left corner.
    case move(x: Double, y: Double)
    /// Presses or releases a mouse button where the pointer is.
    case button(VMMouseButton, down: Bool, clickCount: Int)
    /// Turns the scroll wheel by a number of lines where the pointer is. Positive values turn the wheel up and left,
    /// which shows what's above or to the left, the same as `NSEvent.scrollingDeltaY` and `scrollingDeltaX`.
    case scroll(dx: Int, dy: Int)
    /// Presses or releases a key, by its macOS virtual key code (`kVK_*`).
    case key(code: UInt16, down: Bool)
    /// Waits before the next event.
    case pause(milliseconds: Int)
}

/// Maps between screenshots of a virtual machine's display and the positions its pointing device takes.
public enum VMDisplayGeometry {
    /// The size in pixels of a capture of a region of a window, which is the size of its screenshots.
    public static func pixelSize(of rect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (Int(rect.width * scale), Int(rect.height * scale))
    }

    /// A pixel of a screenshot as a fraction of the display's width and height, with the origin at the top left corner,
    /// which is how Virtualization's pointing device takes positions.
    public static func normalizedLocation(ofPixel pixel: CGPoint, displaySize: (width: Int, height: Int)) -> CGPoint {
        CGPoint(x: pixel.x / CGFloat(displaySize.width), y: pixel.y / CGFloat(displaySize.height))
    }
}
