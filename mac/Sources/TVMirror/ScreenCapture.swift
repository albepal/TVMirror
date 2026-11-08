import Foundation
import ScreenCaptureKit
import CoreMedia

/// Captures one display (and system audio) with ScreenCaptureKit. Frames arrive as GPU-backed
/// NV12 pixel buffers that go straight into the hardware encoder without any copy.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "tvmirror.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "tvmirror.audio", qos: .userInteractive)
    private var repeatTimer: DispatchSourceTimer?

    // videoQueue only
    private var lastBuffer: CVPixelBuffer?
    private var lastFrameTime = DispatchTime.now()
    private var delaySum = 0.0, delayMax = 0.0, delayCount = 0

    var onVideo: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    /// Asked periodically; when true and the screen is static, the last frame is re-sent
    /// (ScreenCaptureKit delivers nothing while the screen doesn't change).
    var needsRefresh: (() -> Bool)?
    var onError: ((Error) -> Void)?

    func start(display: SCDisplay, width: Int, height: Int, fps: Int, audio: Bool) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = true
        cfg.queueDepth = 6
        cfg.scalesToFit = true
        if audio {
            cfg.capturesAudio = true
            cfg.sampleRate = 48_000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true
        }

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if audio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        try await s.startCapture()
        stream = s

        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.refreshIfNeeded() }
        timer.resume()
        repeatTimer = timer
    }

    func stop() {
        repeatTimer?.cancel()
        repeatTimer = nil
        onVideo = nil
        onAudio = nil
        if let stream {
            self.stream = nil
            Task { try? await stream.stopCapture() }
        }
    }

    private func refreshIfNeeded() {
        guard let lastBuffer, needsRefresh?() == true,
              DispatchTime.now().uptimeNanoseconds > lastFrameTime.uptimeNanoseconds + 80_000_000 else { return }
        onVideo?(lastBuffer, CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete,
                  let pixelBuffer = sample.imageBuffer else { return }
            lastBuffer = pixelBuffer
            lastFrameTime = .now()
            // How long after macOS rendered the frame we received it.
            let delay = (CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - CMTimeGetSeconds(sample.presentationTimeStamp)) * 1000
            delaySum += delay; delayMax = max(delayMax, delay); delayCount += 1
            if delayCount >= 120 {
                statsLog.notice("capture: delay avg \(self.delaySum / Double(self.delayCount), format: .fixed(precision: 1)) ms max \(self.delayMax, format: .fixed(precision: 1)) ms")
                delaySum = 0; delayMax = 0; delayCount = 0
            }
            onVideo?(pixelBuffer, sample.presentationTimeStamp)
        case .audio:
            onAudio?(sample)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

/// Converts ScreenCaptureKit audio (usually Float32 planar) to 16-bit interleaved stereo.
func pcm16Stereo(from sample: CMSampleBuffer) -> Data? {
    guard let format = sample.formatDescription,
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
    let frames = sample.numSamples
    guard frames > 0 else { return nil }
    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let channels = Int(asbd.mChannelsPerFrame)
    guard isFloat, asbd.mBitsPerChannel == 32, channels > 0 else { return nil }

    var out = Data(count: frames * 4)
    do {
        try sample.withAudioBufferList { list, _ in
            out.withUnsafeMutableBytes { raw in
                let dst = raw.bindMemory(to: Int16.self)
                func clamp(_ v: Float) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }
                if planar {
                    guard let l = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
                    let r = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) ?? l : l
                    for i in 0..<frames {
                        dst[2 * i] = clamp(l[i])
                        dst[2 * i + 1] = clamp(r[i])
                    }
                } else {
                    guard let src = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
                    for i in 0..<frames {
                        let left = src[i * channels]
                        dst[2 * i] = clamp(left)
                        dst[2 * i + 1] = clamp(channels > 1 ? src[i * channels + 1] : left)
                    }
                }
            }
        }
    } catch {
        return nil
    }
    return out
}
