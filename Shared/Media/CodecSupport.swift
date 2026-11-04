import CoreMedia
import Foundation
import VideoToolbox

extension VideoCodec {
    var cmCodecType: CMVideoCodecType {
        self == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
    }
}

/// Helpers to move compressed video between VideoToolbox and the wire format.
enum CodecSupport {
    /// Pulls the SPS/PPS (and VPS for HEVC) out of an encoder's format description.
    static func parameterSets(from format: CMFormatDescription, codec: VideoCodec) -> [Data] {
        var count = 0
        let countStatus = getParameterSet(format, codec: codec, index: 0, pointer: nil, size: nil, count: &count)
        guard countStatus == noErr, count > 0 else { return [] }

        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = getParameterSet(format, codec: codec, index: index, pointer: &pointer, size: &size, count: nil)
            if status == noErr, let pointer, size > 0 {
                sets.append(Data(bytes: pointer, count: size))
            }
        }
        return sets
    }

    private static func getParameterSet(_ format: CMFormatDescription,
                                        codec: VideoCodec,
                                        index: Int,
                                        pointer: UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
                                        size: UnsafeMutablePointer<Int>?,
                                        count: UnsafeMutablePointer<Int>?) -> OSStatus {
        switch codec {
        case .hevc:
            return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: pointer,
                parameterSetSizeOut: size, parameterSetCountOut: count, nalUnitHeaderLengthOut: nil)
        case .h264:
            return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: pointer,
                parameterSetSizeOut: size, parameterSetCountOut: count, nalUnitHeaderLengthOut: nil)
        }
    }

    /// Rebuilds a format description from parameter sets received over the network.
    static func makeFormatDescription(codec: VideoCodec, parameterSets: [Data]) -> CMVideoFormatDescription? {
        guard !parameterSets.isEmpty, parameterSets.allSatisfy({ !$0.isEmpty }) else { return nil }

        let buffers: [UnsafeMutablePointer<UInt8>] = parameterSets.map { set in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { buffers.forEach { $0.deallocate() } }

        let pointers: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0) }
        let sizes: [Int] = parameterSets.map(\.count)
        var format: CMFormatDescription?

        let status: OSStatus = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                switch codec {
                case .hevc:
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: parameterSets.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &format)
                case .h264:
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: parameterSets.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &format)
                }
            }
        }
        return status == noErr ? format : nil
    }

    /// Wraps one compressed frame in a sample buffer that a display layer shows right away.
    static func makeSampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let length = data.count
        guard length > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: length)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = length
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }
}
