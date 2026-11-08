import Foundation
import VideoToolbox

/// Hardware H.264/HEVC encoder in low-latency real-time mode. Outputs Annex B (start-code) frames,
/// which is what Android's MediaCodec expects.
final class VideoEncoder {
    private var session: VTCompressionSession?
    private let hevc: Bool
    private let lock = NSLock()
    private var forceKeyframe = true
    private var encodeSum = 0.0, encodeMax = 0.0, encodeCount = 0

    /// (frame, parameter sets if keyframe, isKeyframe, pts µs). Called on a VideoToolbox thread.
    var onFrame: ((Data, Data?, Bool, UInt64) -> Void)?

    init?(width: Int32, height: Int32, hevc: Bool, bitrate: Int, fps: Int) {
        self.hevc = hevc
        let codec = hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        // Low-latency rate control: no frame buffering, encoder tuned for conferencing-style streaming.
        let specs: [[CFString: Any]] = [
            [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
             kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true],
            [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true],
        ]
        for spec in specs {
            var s: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil, width: width, height: height, codecType: codec,
                encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                compressionSessionOut: &s)
            if status == noErr, let s { session = s; break }
        }
        guard let session else { return nil }

        func set(_ key: CFString, _ value: Any) { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)   // no B-frames
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse!)
        set(kVTCompressionPropertyKey_ProfileLevel,
            hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
        // Cap bursts at 1.5× the average over one second so keyframes don't flood Wi-Fi.
        set(kVTCompressionPropertyKey_DataRateLimits, [bitrate * 3 / 2 / 8, 1] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 10)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { invalidate() }

    func invalidate() {
        // Take the session out under the lock, but invalidate it *outside* the lock: invalidating waits
        // for frames still in flight, whose output handler also takes the lock (that was a deadlock).
        lock.lock()
        let s = session
        session = nil
        lock.unlock()
        if let s {
            VTCompressionSessionInvalidate(s)
        }
    }

    func requestKeyframe() {
        lock.lock(); forceKeyframe = true; lock.unlock()
    }

    var keyframePending: Bool {
        lock.lock(); defer { lock.unlock() }
        return forceKeyframe
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        guard let session else { lock.unlock(); return }
        let key = forceKeyframe
        forceKeyframe = false
        lock.unlock()

        let start = DispatchTime.now().uptimeNanoseconds
        let props = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else {
                if status != noErr { self?.requestKeyframe() }
                return
            }
            self.recordEncode(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            self.output(sample)
        }
    }

    private func recordEncode(_ ms: Double) {
        lock.lock(); defer { lock.unlock() }
        encodeSum += ms; encodeMax = max(encodeMax, ms); encodeCount += 1
        if encodeCount >= 120 {
            statsLog.notice("encode: avg \(self.encodeSum / Double(self.encodeCount), format: .fixed(precision: 1)) ms max \(self.encodeMax, format: .fixed(precision: 1)) ms")
            encodeSum = 0; encodeMax = 0; encodeCount = 0
        }
    }

    private func output(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var isKey = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }

        // AVCC (4-byte lengths) → Annex B (start codes), in place.
        let total = CMBlockBufferGetDataLength(block)
        var data = Data(count: total)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: base)
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 4 <= total {
                let len = Int(p[i]) << 24 | Int(p[i + 1]) << 16 | Int(p[i + 2]) << 8 | Int(p[i + 3])
                p[i] = 0; p[i + 1] = 0; p[i + 2] = 0; p[i + 3] = 1
                i += 4 + len
            }
        }

        var config: Data?
        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            config = parameterSets(format)
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let ptsMicros = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000)) : 0
        onFrame?(data, config, isKey, ptsMicros)
    }

    private func parameterSets(_ format: CMFormatDescription) -> Data {
        var out = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]
        var count = 0
        if hevc {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let status = hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if status == noErr, let ptr {
                out.append(contentsOf: startCode)
                out.append(ptr, count: size)
            }
        }
        return out
    }
}
