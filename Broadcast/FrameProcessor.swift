import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

/// Turns raw screen frames into upright frames of the right size.
///
/// ReplayKit always delivers the screen in its natural portrait layout and tells us
/// the real orientation separately. Rotating here means the viewer (and Picture in
/// Picture) always receives an upright picture.
///
/// Broadcast extensions only get about 50 MB of memory, so buffer pools are capped.
final class FrameProcessor {
    private var rotationSession: VTPixelRotationSession?
    private var currentRotation: CFString?
    private var transferSession: VTPixelTransferSession?
    private var scalePool = PixelBufferPoolCache()
    private var rotatePool = PixelBufferPoolCache()

    deinit {
        if let rotationSession { VTPixelRotationSessionInvalidate(rotationSession) }
        if let transferSession { VTPixelTransferSessionInvalidate(transferSession) }
    }

    func process(_ source: CVPixelBuffer, orientation: CGImagePropertyOrientation, maxLongSide: Int) -> CVPixelBuffer? {
        var buffer = source
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let longSide = max(width, height)

        // 1. Scale down first (cheaper to rotate a smaller picture).
        if longSide > maxLongSide {
            let scale = Double(maxLongSide) / Double(longSide)
            let targetWidth = Self.even(Double(width) * scale)
            let targetHeight = Self.even(Double(height) * scale)
            guard let scaled = scale(buffer, width: targetWidth, height: targetHeight) else { return nil }
            buffer = scaled
        }

        // 2. Rotate so the picture is upright.
        if let rotation = Self.rotation(for: orientation) {
            guard let rotated = rotate(buffer, rotation: rotation) else { return nil }
            buffer = rotated
        }
        return buffer
    }

    // MARK: Private

    private static func even(_ value: Double) -> Int {
        max(2, Int(value.rounded()) & ~1)
    }

    /// EXIF-style orientation tells us how the picture must be turned to look right.
    private static func rotation(for orientation: CGImagePropertyOrientation) -> CFString? {
        switch orientation {
        case .right, .rightMirrored: return kVTRotation_CW90
        case .left, .leftMirrored: return kVTRotation_CCW90
        case .down, .downMirrored: return kVTRotation_180
        default: return nil
        }
    }

    private func scale(_ source: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        if transferSession == nil {
            var session: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
            transferSession = session
        }
        guard let transferSession,
              let output = scalePool.makeBuffer(width: width, height: height, format: CVPixelBufferGetPixelFormatType(source)) else {
            return nil
        }
        guard VTPixelTransferSessionTransferImage(transferSession, from: source, to: output) == noErr else { return nil }
        CVBufferPropagateAttachments(source, output)
        return output
    }

    private func rotate(_ source: CVPixelBuffer, rotation: CFString) -> CVPixelBuffer? {
        if rotationSession == nil {
            var session: VTPixelRotationSession?
            VTPixelRotationSessionCreate(allocator: kCFAllocatorDefault, pixelRotationSessionOut: &session)
            rotationSession = session
            currentRotation = nil
        }
        guard let rotationSession else { return nil }

        if currentRotation != rotation {
            VTSessionSetProperty(rotationSession, key: kVTPixelRotationPropertyKey_Rotation, value: rotation)
            currentRotation = rotation
        }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let swapsSides = rotation != kVTRotation_180
        guard let output = rotatePool.makeBuffer(
            width: swapsSides ? height : width,
            height: swapsSides ? width : height,
            format: CVPixelBufferGetPixelFormatType(source)) else { return nil }

        guard VTPixelRotationSessionRotateImage(rotationSession, sourceBuffer: source, destinationBuffer: output) == noErr else {
            return nil
        }
        CVBufferPropagateAttachments(source, output)
        return output
    }
}

/// A pixel buffer pool that is rebuilt when the size changes and never grows past a few buffers.
private struct PixelBufferPoolCache {
    private var pool: CVPixelBufferPool?
    private var width = 0
    private var height = 0
    private var format: OSType = 0

    mutating func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        if pool == nil || width != self.width || height != self.height || format != self.format {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            self.width = width
            self.height = height
            self.format = format
        }
        guard let pool else { return nil }

        var buffer: CVPixelBuffer?
        let auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: 5] as CFDictionary
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &buffer)
        return status == kCVReturnSuccess ? buffer : nil
    }
}
