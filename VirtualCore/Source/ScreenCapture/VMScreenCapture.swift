import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import Virtualization

/// The part of a window that shows a virtual machine's display, which is what screenshots and recordings capture.
public struct VMCaptureRegion: Equatable, @unchecked Sendable {
    /// The window's number in the window server.
    public let windowID: CGWindowID
    /// The display's area in the window, in points, with the origin at the window's top left corner.
    public let rect: CGRect

    @MainActor
    public init?(view: NSView) {
        guard let window = view.window, window.windowNumber > 0, !view.bounds.isEmpty else { return nil }

        let frame = view.convert(view.bounds, to: nil)

        self.windowID = CGWindowID(window.windowNumber)
        self.rect = CGRect(x: frame.minX, y: window.frame.height - frame.maxY, width: frame.width, height: frame.height).integral
    }
}

/// Thrown when Hypervisaur isn't allowed to record the screen, which it needs to capture a virtual machine's window.
public struct ScreenCapturePermissionError: LocalizedError {
    public var errorDescription: String? {
        "Hypervisaur needs permission to record the screen to capture virtual machines. Allow Hypervisaur in System Settings › Privacy & Security › Screen & System Audio Recording, then try again."
    }

    /// Where the permission is given.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

/// Takes screenshots of virtual machines.
///
/// Guests that run in QEMU are captured from their display's frames, at the guest's resolution. Guests that run with
/// Virtualization are captured from their window with ScreenCaptureKit, which needs permission to record the screen, or
/// from their display, at the guest's resolution, when they run without a window.
public enum VMScreenCapture {
    @MainActor
    public static func screenshot(of runtime: VMRuntime, in region: VMCaptureRegion?) async throws -> CGImage {
        if let machine = runtime.qemuMachine {
            guard let frame = machine.currentFrame() else {
                throw Failure("The virtual machine hasn’t shown anything on its display yet.")
            }
            return frame
        }

        if let region {
            return try await screenshot(of: region)
        }

        guard let display = runtime.virtualMachine?.graphicsDevices.first?.displays.first else {
            throw Failure("The virtual machine’s display isn’t on screen.")
        }

        return try await screenshot(of: display)
    }

    /// A screenshot of a Virtualization display at the guest's resolution, which doesn't need a window.
    ///
    /// Virtualization only offers this through private API. There's no public way to capture a display that isn't on screen.
    @MainActor
    public static func screenshot(of display: VZGraphicsDisplay) async throws -> CGImage {
        guard display.responds(to: NSSelectorFromString("_takeScreenshotWithCompletionHandler:")) else {
            throw Failure("This version of macOS can’t take screenshots of virtual machines without a window. Open the virtual machine’s window, then try again.")
        }

        let screenshot: Any = try await withCheckedThrowingContinuation { continuation in
            display._takeScreenshot { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: (error as? Error) ?? Failure("The virtual machine’s display couldn’t be captured."))
                }
            }
        }

        let size = (width: Int(display.sizeInPixels.width), height: Int(display.sizeInPixels.height))
        let image: CGImage? = if CFGetTypeID(screenshot as CFTypeRef) == CGImage.typeID {
            (screenshot as! CGImage)
        } else {
            (screenshot as? NSImage)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        guard let image else {
            throw Failure("The virtual machine’s display couldn’t be captured.")
        }

        /// Pointer input is placed by the display's size in pixels, so screenshots are always that size.
        guard image.width != size.width || image.height != size.height else { return image }
        guard let resized = image.vb_resized(to: size) else {
            throw Failure("The virtual machine’s display couldn’t be captured.")
        }
        return resized
    }

    /// A small picture of the virtual machine's display, for showing what it's doing at a glance.
    ///
    /// Unlike ``screenshot(of:in:)``, this never asks for anything: guests that are captured from their window only get a
    /// preview while it's on screen, and only once Hypervisaur is allowed to record the screen.
    /// - Returns: `nil` when there's nothing to show yet, or the display can't be captured without asking.
    @MainActor
    public static func preview(of runtime: VMRuntime, in region: VMCaptureRegion?, maxPixelSize: Int = previewMaxPixelSize) async -> CGImage? {
        if let machine = runtime.qemuMachine {
            guard let frame = machine.currentFrame() else { return nil }
            return try? await performOffMainActor { frame.vb_scaledToFit(maxPixelSize: maxPixelSize) }
        }

        guard let region, CGPreflightScreenCaptureAccess() else { return nil }

        do {
            let filter = try await contentFilter(for: region)

            let configuration = SCStreamConfiguration()
            let scale = min(CGFloat(filter.pointPixelScale), CGFloat(maxPixelSize) / max(region.rect.width, region.rect.height))
            configure(configuration, for: region, scale: scale)
            configuration.showsCursor = false

            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return nil
        }
    }

    /// The size of the longest side of previews, in pixels, which is plenty for the library.
    public static let previewMaxPixelSize = 640

    /// A screenshot of part of a window, without the pointer.
    public static func screenshot(of region: VMCaptureRegion) async throws -> CGImage {
        let filter = try await contentFilter(for: region)

        let configuration = SCStreamConfiguration()
        configure(configuration, for: region, scale: CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Writes an image to a PNG file, away from the main actor since large images take a moment to compress.
    public static func writePNG(_ image: CGImage, to url: URL) async throws {
        try await performOffMainActor { try writePNGSynchronously(image, to: url) }
    }

    private static func writePNGSynchronously(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure("Couldn’t create \(url.lastPathComponent).")
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw Failure("Couldn’t write \(url.lastPathComponent).")
        }
    }

    // MARK: - ScreenCaptureKit

    /// Asks for permission to record the screen the first time, and throws if it hasn't been given.
    static func requireScreenCapturePermission() throws {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw ScreenCapturePermissionError()
        }
    }

    /// Captures a window by itself, whether or not other windows cover it.
    static func contentFilter(for region: VMCaptureRegion) async throws -> SCContentFilter {
        try requireScreenCapturePermission()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == region.windowID }) else {
            throw Failure("The virtual machine’s window isn’t available to capture.")
        }

        return SCContentFilter(desktopIndependentWindow: window)
    }

    /// Captures the region at the size it has on screen, in pixels.
    static func configure(_ configuration: SCStreamConfiguration, for region: VMCaptureRegion, scale: CGFloat) {
        let size = VMDisplayGeometry.pixelSize(of: region.rect, scale: scale)
        configuration.sourceRect = region.rect
        configuration.width = size.width
        configuration.height = size.height
        configuration.ignoreShadowsSingleWindow = true
        configuration.colorSpaceName = CGColorSpace.sRGB
    }
}

/// Where screenshots and recordings of virtual machines are saved.
public enum VMCaptureLocation {
    /// The folder that macOS saves screenshots to, as chosen in the Screenshot app, or the desktop.
    public static var directoryURL: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            if url.isReadableDirectory {
                return url
            }
        }

        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// A file named after the virtual machine and the time, like the ones macOS makes, that doesn't exist yet.
    public static func newFileURL(for model: VBVirtualMachine, pathExtension: String, date: Date = .now, in directoryURL: URL = directoryURL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"

        /// Slashes and colons can't be part of a file name in Finder.
        let name = model.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let baseName = "\(name) \(formatter.string(from: date))"

        var url = directoryURL.appending(path: "\(baseName).\(pathExtension)")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directoryURL.appending(path: "\(baseName) \(number).\(pathExtension)")
            number += 1
        }
        return url
    }
}

private extension CGImage {
    /// The image at a size whose longest side is at most the given number of pixels, or the image itself when it's already that small.
    func vb_scaledToFit(maxPixelSize: Int) -> CGImage? {
        let longestSide = max(width, height)
        guard longestSide > maxPixelSize else { return self }

        let scale = CGFloat(maxPixelSize) / CGFloat(longestSide)
        return vb_resized(to: (Int((CGFloat(width) * scale).rounded()), Int((CGFloat(height) * scale).rounded())))
    }

    func vb_resized(to size: (width: Int, height: Int)) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))

        return context.makeImage()
    }
}
