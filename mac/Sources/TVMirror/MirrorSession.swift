import AppKit
import Network
import ScreenCaptureKit

enum MirrorError: LocalizedError {
    case message(String)
    case screenPermission

    var errorDescription: String? {
        switch self {
        case .message(let m): m
        case .screenPermission:
            "TVMirror needs permission to record the screen. Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        }
    }
}

/// One mirroring run: capture → encode → send. Lives on the main thread; the media path runs on
/// the capture, VideoToolbox and network queues without touching the main thread.
final class MirrorSession {
    enum Event { case mirroring, ended(Error?) }

    let name: String
    private let endpoint: NWEndpoint
    private var connection: StreamConnection?
    private var capture: ScreenCapture?
    private var encoder: VideoEncoder?
    private let muter = AudioMuter()
    private var virtualScreen: VirtualScreen?
    private var ended = false
    private var connectTimeout: DispatchWorkItem?

    /// Main thread.
    var onEvent: ((Event) -> Void)?

    init(endpoint: NWEndpoint, name: String) {
        self.endpoint = endpoint
        self.name = name
    }

    func start() {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            end(MirrorError.screenPermission)
            return
        }
        let conn = StreamConnection(endpoint: endpoint)
        connection = conn
        conn.onClosed = { [weak self] message in
            self?.end(message.map { MirrorError.message($0) })
        }
        conn.onReady = { [weak self] in
            DispatchQueue.main.async { self?.connected() }
        }
        conn.start()

        let timeout = DispatchWorkItem { [weak self] in
            self?.end(MirrorError.message("Couldn't connect to “\(self?.name ?? "the TV")”. Make sure the TVMirror app is installed on the TV and both are on the same network."))
        }
        connectTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    func stop() { end(nil) }

    private func connected() {
        connectTimeout?.cancel()
        guard !ended else { return }
        Task { @MainActor in
            do {
                try await startMedia()
                guard !ended else { return }
                if Settings.sendAudio && Settings.muteMac { muter.mute() }
                onEvent?(.mirroring)
            } catch {
                let nsError = error as NSError
                if nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.userDeclined.rawValue {
                    end(MirrorError.screenPermission)
                } else {
                    end(error)
                }
            }
        }
    }

    @MainActor
    private func startMedia() async throws {
        guard let connection else { return }
        let display: SCDisplay
        if Settings.screenUse == .extend {
            guard let screen = VirtualScreen(name: name) else {
                throw MirrorError.message("Couldn't create the extended display.")
            }
            virtualScreen = screen
            display = try await findDisplay(screen.displayID)
        } else {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let wanted = Settings.displayID == 0 ? CGMainDisplayID() : Settings.displayID
            guard let d = content.displays.first(where: { $0.displayID == wanted })
                    ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? content.displays.first else {
                throw MirrorError.message("No display found to mirror.")
            }
            display = d
        }

        let quality = Settings.quality
        let (width, height) = quality.size(for: display)
        let hevc = Settings.codec.useHEVC(height: height)
        let fps = 60
        guard let encoder = VideoEncoder(width: Int32(width), height: Int32(height), hevc: hevc,
                                         bitrate: quality.bitrate, fps: fps) else {
            throw MirrorError.message("Couldn't start the hardware video encoder.")
        }
        self.encoder = encoder
        let audio = Settings.sendAudio

        connection.sendHello([
            "v": 1,
            "name": Host.current().localizedName ?? "Mac",
            "width": width, "height": height, "fps": fps,
            "codec": hevc ? "hevc" : "h264",
            "audio": audio, "sampleRate": 48_000, "channels": 2,
            "playoutDelayMs": Settings.mode.playoutDelayMs,
        ])

        encoder.onFrame = { [weak connection] frame, config, key, pts in
            connection?.sendVideo(frame: frame, config: config, keyframe: key, pts: pts)
        }
        connection.onKeyframeRequest = { [weak encoder] in encoder?.requestKeyframe() }

        let capture = ScreenCapture()
        self.capture = capture
        capture.onVideo = { [weak encoder] buffer, pts in encoder?.encode(buffer, pts: pts) }
        capture.needsRefresh = { [weak encoder] in encoder?.keyframePending ?? false }
        if audio {
            capture.onAudio = { [weak connection] sample in
                guard let pcm = pcm16Stereo(from: sample) else { return }
                let pts = sample.presentationTimeStamp
                connection?.sendAudio(pcm, pts: UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000)))
            }
        }
        capture.onError = { [weak self] error in
            DispatchQueue.main.async { self?.end(MirrorError.message("Screen capture stopped: \(error.localizedDescription)")) }
        }
        try await capture.start(display: display, width: width, height: height, fps: fps, audio: audio)
    }

    /// A new virtual display takes a moment to show up in ScreenCaptureKit.
    @MainActor
    private func findDisplay(_ id: CGDirectDisplayID) async throws -> SCDisplay {
        for _ in 0..<30 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let d = content.displays.first(where: { $0.displayID == id }) { return d }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw MirrorError.message("The extended display didn't appear.")
    }

    private func end(_ error: Error?) {
        guard !ended else { return }
        ended = true
        connectTimeout?.cancel()
        capture?.stop()
        capture = nil
        encoder?.invalidate()
        encoder = nil
        connection?.close(sayBye: error == nil)
        connection = nil
        AudioMuter.restore()
        // Release the virtual display after capture has stopped; macOS moves its windows back.
        if let screen = virtualScreen {
            virtualScreen = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { _ = screen }
        }
        onEvent?(.ended(error))
    }
}
