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

        // HiDPI modes ("looks like" sizes), rendered at 2× and scaled to the stream, so text stays sharp.
        // The first mode is the starting one. On macOS 27 the display only comes online with certain
        // starting modes (1280×720 and 1600×900 work; 1920×1080 doesn't), so the list must start at
        // 1280×720 – also a comfortable text size from the couch. 1920×1080 is in Displays settings.
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [(1280, 720), (1600, 900), (1920, 1080)].map {
            CGVirtualDisplayMode(width: UInt32($0.0), height: UInt32($0.1), refreshRate: 60)
        }
        guard display.apply(settings), display.displayID != 0 else { return nil }
    }

    /// Once online: switch to the HiDPI "looks like 1280×720" mode (macOS otherwise picks a tiny
    /// 2560×1440 1× mode) and place the TV right of the main display with the bottom edges aligned,
    /// so the Dock and the mouse behave normally along the bottom.
    func arrange() {
        let id = display.displayID
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        statsLog.notice("virtual display modes: \(modes.map { "\($0.width)x\($0.height)@\($0.pixelWidth)x\($0.pixelHeight)" }.joined(separator: ", "), privacy: .public)")
        let hidpi = modes.first { $0.width == 1280 && $0.pixelWidth == 2560 }
        let main = CGDisplayBounds(CGMainDisplayID())
        let height = Double(hidpi?.height ?? 720)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        if let hidpi { CGConfigureDisplayWithDisplayMode(config, id, hidpi, nil) }
        CGConfigureDisplayOrigin(config, id, Int32(main.maxX), Int32(main.maxY - height))
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        let now = CGDisplayCopyDisplayMode(id)
        statsLog.notice("virtual display arranged (\(result.rawValue)): \(now?.width ?? 0)x\(now?.height ?? 0) points, origin \(Int(CGDisplayBounds(id).minX)),\(Int(CGDisplayBounds(id).minY))")
    }
}
