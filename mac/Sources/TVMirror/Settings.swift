import AppKit
import ScreenCaptureKit

enum Quality: String, CaseIterable {
    case p1080, p1440, p2160

    var title: String {
        switch self {
        case .p1080: "1080p (smoothest on Wi-Fi)"
        case .p1440: "1440p"
        case .p2160: "4K (best on Ethernet)"
        }
    }
    var boxHeight: Double {
        switch self { case .p1080: 1080; case .p1440: 1440; case .p2160: 2160 }
    }
    var bitrate: Int {
        switch self { case .p1080: 16_000_000; case .p1440: 28_000_000; case .p2160: 45_000_000 }
    }

    /// Fits the display (keeping its aspect ratio) inside a 16:9 box of this height, never upscaling.
    func size(for display: SCDisplay) -> (width: Int, height: Int) {
        let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2
        let nativeW = Double(display.width) * scale
        let nativeH = Double(display.height) * scale
        let s = min(1, min(boxHeight * 16 / 9 / nativeW, boxHeight / nativeH))
        func even(_ v: Double) -> Int { max(2, Int(v.rounded()) & ~1) }
        return (even(nativeW * s), even(nativeH * s))
    }
}

enum Codec: String, CaseIterable {
    case automatic, h264, hevc

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .h264: "H.264 (most compatible)"
        case .hevc: "HEVC (sharper, same bandwidth)"
        }
    }
    /// TV decoders often can't do H.264 at 4K60, so Automatic switches to HEVC above 1440p.
    func useHEVC(height: Int) -> Bool {
        switch self {
        case .automatic: height > 1440
        case .h264: false
        case .hevc: true
        }
    }
}

enum Mode: String, CaseIterable {
    case responsive, smooth

    var title: String {
        switch self {
        case .responsive: "Responsive (mouse & typing)"
        case .smooth: "Smooth (videos, sound in sync)"
        }
    }
    /// How long the TV holds frames back to ride out Wi-Fi pauses.
    var playoutDelayMs: Int { self == .smooth ? 150 : 0 }
}

struct Settings {
    private static let d = UserDefaults.standard

    static var quality: Quality {
        get { Quality(rawValue: d.string(forKey: "quality") ?? "") ?? .p1080 }
        set { d.set(newValue.rawValue, forKey: "quality") }
    }
    static var codec: Codec {
        get { Codec(rawValue: d.string(forKey: "codec") ?? "") ?? .automatic }
        set { d.set(newValue.rawValue, forKey: "codec") }
    }
    static var mode: Mode {
        get { Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .responsive }
        set { d.set(newValue.rawValue, forKey: "mode") }
    }
    static var sendAudio: Bool {
        get { d.object(forKey: "sendAudio") as? Bool ?? true }
        set { d.set(newValue, forKey: "sendAudio") }
    }
    static var muteMac: Bool {
        get { d.object(forKey: "muteMac") as? Bool ?? true }
        set { d.set(newValue, forKey: "muteMac") }
    }
    /// 0 = main display.
    static var displayID: CGDirectDisplayID {
        get { CGDirectDisplayID(d.integer(forKey: "displayID")) }
        set { d.set(Int(newValue), forKey: "displayID") }
    }
    static var lastManualHost: String {
        get { d.string(forKey: "lastManualHost") ?? "" }
        set { d.set(newValue, forKey: "lastManualHost") }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
