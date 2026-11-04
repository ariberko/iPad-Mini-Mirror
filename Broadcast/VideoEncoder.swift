import CoreMedia
import Foundation
import VideoToolbox

struct EncodedFrame {
    let codec: VideoCodec
    let isKeyFrame: Bool
    let parameterSets: [Data]?
    let data: Data
    let timestampMicros: Int64
}

/// Hardware HEVC encoder (falls back to H.264), tuned for low delay.
final class VideoEncoder {
    var onEncodedFrame: ((EncodedFrame) -> Void)?

    private let bitRate: Int
    private let frameRate: Int
    private let lock = NSLock()

    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var codec: VideoCodec = .hevc
    private var hevcAvailable = true
    private var forceKey = true
    private var lastPresentationTime = CMTime.invalid

    init(bitRate: Int, frameRate: Int) {
        self.bitRate = bitRate
        self.frameRate = frameRate
    }

    deinit {
        invalidate()
    }

    func forceKeyFrame() {
        lock.withLock { forceKey = true }
    }

    func invalidate() {
        lock.withLock { invalidateLocked() }
    }

    /// Encodes one frame. `presentationTime` nil means "now" (used when repeating the last frame).
    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime?) {
        lock.lock()
        defer { lock.unlock() }

        let frameWidth = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let frameHeight = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if session == nil || frameWidth != width || frameHeight != height {
            guard makeSession(width: frameWidth, height: frameHeight) else { return }
        }
        guard let session else { return }

        // Timestamps must always move forward.
        var time = presentationTime ?? CMClockGetTime(CMClockGetHostTimeClock())
        if lastPresentationTime.isValid, CMTimeCompare(time, lastPresentationTime) <= 0 {
            time = CMTimeAdd(lastPresentationTime, CMTime(value: 1, timescale: 1000))
        }
        lastPresentationTime = time

        var properties: CFDictionary?
        if forceKey {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceKey = false
        }

        let codec = self.codec
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: time,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.emit(sampleBuffer, codec: codec)
        }

        if status != noErr {
            // The encoder can be reset by the system (for example, after the app goes to the background).
            invalidateLocked()
            forceKey = true
        }
    }

    // MARK: Private

    private func makeSession(width: Int32, height: Int32) -> Bool {
        invalidateLocked()

        let candidates: [VideoCodec] = hevcAvailable ? [.hevc, .h264] : [.h264]
        for candidate in candidates {
            var newSession: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: width,
                height: height,
                codecType: candidate.cmCodecType,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &newSession)

            guard status == noErr, let newSession else {
                if candidate == .hevc { hevcAvailable = false }
                continue
            }

            configure(newSession, codec: candidate)
            VTCompressionSessionPrepareToEncodeFrames(newSession)
            session = newSession
            codec = candidate
            self.width = width
            self.height = height
            forceKey = true
            return true
        }
        return false
    }

    private func configure(_ session: VTCompressionSession, codec: VideoCodec) {
        set(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(session, kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(session, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitRate))
        let bytesPerSecond = Double(bitRate) * 1.5 / 8
        set(session, kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: bytesPerSecond), NSNumber(value: 1)] as CFArray)
        set(session, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: frameRate))
        set(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: frameRate * 2))
        set(session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2))
        set(session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
    }

    private func set(_ session: VTCompressionSession, _ key: CFString, _ value: CFTypeRef?) {
        _ = VTSessionSetProperty(session, key: key, value: value)
    }

    private func invalidateLocked() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        width = 0
        height = 0
    }

    private func emit(_ sampleBuffer: CMSampleBuffer, codec: VideoCodec) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var isKeyFrame = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            isKeyFrame = !notSync
        }

        var parameterSets: [Data]?
        if isKeyFrame, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            parameterSets = CodecSupport.parameterSets(from: format, codec: codec)
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == kCMBlockBufferNoErr else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let micros = time.isNumeric ? Int64(CMTimeGetSeconds(time) * 1_000_000) : 0

        onEncodedFrame?(EncodedFrame(
            codec: codec,
            isKeyFrame: isKeyFrame,
            parameterSets: parameterSets,
            data: data,
            timestampMicros: micros))
    }
}
