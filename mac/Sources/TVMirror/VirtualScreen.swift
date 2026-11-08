import AppKit
import CGVirtualDisplayPrivate

/// A virtual monitor for "Extend" mode: macOS treats the TV as a real second display
/// (arrange it or change its resolution in System Settings → Displays). It disappears, and its
/// windows move back, when the object is released.
final class VirtualScreen {
    private let display: CGVirtualDisplay
    var displayID: CGDirectDisplayID { display.displayID }

    init?(name: String) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = name
        descriptor.maxPixelsWide = 3840
        descriptor.maxPixelsHigh = 2160
        descriptor.sizeInMillimeters = CGSize(width: 1210, height: 680) // a 55" TV
        descriptor.vendorID = 0x7476   // "tv"
        descriptor.productID = 0x6D72  // "mr"
        descriptor.serialNum = 1
        descriptor.terminationHandler = { _, _ in }
        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        self.display = display

        // HiDPI modes ("looks like" sizes), rendered at 2× and scaled to the stream size, so text stays
        // sharp. 1920×1080 first (the TV's own resolution); larger-text options are in Displays settings.
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [(1920, 1080), (1600, 900), (1280, 720)].map {
            CGVirtualDisplayMode(width: UInt32($0.0), height: UInt32($0.1), refreshRate: 60)
        }
        guard display.apply(settings), display.displayID != 0 else { return nil }
    }
}
