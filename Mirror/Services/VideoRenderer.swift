import AVFoundation
import AVKit
import UIKit

/// Shows decoded frames and powers Picture in Picture.
/// One instance lives for the whole app so Picture in Picture survives reconnects.
final class VideoRenderer: NSObject {
    let displayLayer = AVSampleBufferDisplayLayer()
    private(set) var pipController: AVPictureInPictureController?

    var onPictureInPictureChange: ((Bool) -> Void)?
    var onRestoreUserInterface: (() -> Void)?

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor

        if AVPictureInPictureController.isPictureInPictureSupported() {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
            let controller = AVPictureInPictureController(contentSource: source)
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.requiresLinearPlayback = true
            controller.delegate = self
            pipController = controller
        }
    }

    var isPictureInPictureActive: Bool { pipController?.isPictureInPictureActive ?? false }

    /// Returns false if the decoder needs a fresh key frame.
    @discardableResult
    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            return false
        }
        renderer.enqueue(sampleBuffer)
        return true
    }

    func clear() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func togglePictureInPicture() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    func stopPictureInPicture() {
        if pipController?.isPictureInPictureActive == true {
            pipController?.stopPictureInPicture()
        }
    }
}

extension VideoRenderer: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // Live content: no scrubbing.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

extension VideoRenderer: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async { self.onPictureInPictureChange?(true) }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async { self.onPictureInPictureChange?(false) }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            self.onRestoreUserInterface?()
            completionHandler(true)
        }
    }
}
