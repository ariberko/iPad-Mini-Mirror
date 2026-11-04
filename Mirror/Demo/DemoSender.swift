import CoreMedia
import QuartzCore
import UIKit

/// Streams a drawn, animated demo screen through the real pipeline
/// (HostSession → encoder → encrypted connection → the other device's decoder).
///
/// iOS Simulators can't run a screen broadcast, so this stands in for ReplayKit.
/// Everything after the frame source is the same code a real broadcast uses.
final class DemoSender {
    private let session: HostSession
    private let renderer: DemoScreenRenderer
    private let queue = DispatchQueue(label: "mirror.demo.sender", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private let startTime = CACurrentMediaTime()
    private var frames = 0

    init(device: NearbyDevice, passcode: String) {
        let target = BroadcastTarget(deviceID: device.id, serviceName: device.serviceName, displayName: device.serviceName, kind: device.kind)
        session = HostSession(target: target, passcode: passcode)

        // Draw at 2x points: sharp, but light enough for a CI machine.
        let points = UIScreen.main.bounds.size
        var pixels = CGSize(width: points.width * 2, height: points.height * 2)
        if DeviceKind.current == .iPad, pixels.height > pixels.width {
            pixels = CGSize(width: pixels.height, height: pixels.width) // iPad shares in landscape
        }
        renderer = DemoScreenRenderer(pixelSize: pixels, scale: 2, kind: .current)

        session.onFatalError = { message in
            DemoMode.log("sender stopped: \(message)")
        }
    }

    func start() {
        DemoMode.log("sender starting at \(Int(renderer.pixelSize.width))x\(Int(renderer.pixelSize.height))")
        session.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 1.0 / 30)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        session.stop(sendGoodbye: true)
    }

    private func tick() {
        let time = CACurrentMediaTime() - startTime
        guard let buffer = makePixelBuffer() else { return }
        renderer.draw(into: buffer, time: time)
        guard let sample = makeSampleBuffer(buffer, time: time) else { return }
        session.handleVideo(sample)
        frames += 1
        if frames % 150 == 0 { DemoMode.log("sender rendered \(frames) frames") }
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(renderer.pixelSize.width),
                kCVPixelBufferHeightKey as String: Int(renderer.pixelSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private func makeSampleBuffer(_ buffer: CVPixelBuffer, time: Double) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample)
        return sample
    }
}
