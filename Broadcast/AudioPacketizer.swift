import AVFoundation
import CoreMedia

/// Converts ReplayKit app audio (any format) into 48 kHz stereo 16-bit PCM.
final class AudioPacketizer {
    static let sampleRate: Double = 48_000
    static let channels: AVAudioChannelCount = 2

    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: AudioPacketizer.sampleRate,
        channels: AudioPacketizer.channels,
        interleaved: true)!

    private var converter: AVAudioConverter?
    private var inputDescription: AudioStreamBasicDescription?

    func convert(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let descriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return nil }

        var description = descriptionPointer.pointee
        guard description.mFormatID == kAudioFormatLinearPCM else { return nil }

        // ReplayKit app audio is often big-endian. Swap it ourselves so the converter
        // only ever sees native-endian samples.
        let isBigEndian = description.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        if isBigEndian {
            description.mFormatFlags &= ~kAudioFormatFlagIsBigEndian
        }

        guard let inputFormat = AVAudioFormat(streamDescription: &description) else { return nil }
        if converter == nil || !Self.same(description, inputDescription) {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            inputDescription = description
        }
        guard let converter else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else { return nil }
        input.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: input.mutableAudioBufferList)
        guard copyStatus == noErr else { return nil }

        if isBigEndian {
            Self.swapBytes(in: input, bitsPerChannel: description.mBitsPerChannel)
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }

        guard result != .error, output.frameLength > 0, let channelData = output.int16ChannelData else { return nil }
        let byteCount = Int(output.frameLength) * Int(Self.channels) * MemoryLayout<Int16>.size
        return Data(bytes: channelData[0], count: byteCount)
    }

    private static func same(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription?) -> Bool {
        guard let b else { return false }
        return a.mSampleRate == b.mSampleRate
            && a.mFormatFlags == b.mFormatFlags
            && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
            && a.mBytesPerFrame == b.mBytesPerFrame
    }

    private static func swapBytes(in buffer: AVAudioPCMBuffer, bitsPerChannel: UInt32) {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in list {
            guard let raw = audioBuffer.mData else { continue }
            let byteCount = Int(audioBuffer.mDataByteSize)
            switch bitsPerChannel {
            case 16:
                let samples = raw.bindMemory(to: UInt16.self, capacity: byteCount / 2)
                for index in 0..<(byteCount / 2) { samples[index] = samples[index].byteSwapped }
            case 32:
                let samples = raw.bindMemory(to: UInt32.self, capacity: byteCount / 4)
                for index in 0..<(byteCount / 4) { samples[index] = samples[index].byteSwapped }
            default:
                break
            }
        }
    }
}
