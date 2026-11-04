import CoreVideo
import UIKit

/// Draws a lively, home-screen-like picture used as the "shared screen" in the simulation:
/// a live clock, a playing song, and a finger tapping around, so motion is easy to see.
final class DemoScreenRenderer {
    let pixelSize: CGSize
    let scale: CGFloat
    let kind: DeviceKind

    private var size: CGSize { CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale) }
    private var isLandscape: Bool { size.width > size.height }

    private var background: CGImage?
    private var layout = Layout()

    private struct App {
        let name: String
        let symbol: String
        let top: UIColor
        let bottom: UIColor
    }

    private struct Layout {
        var iconSize: CGFloat = 60
        var iconFrames: [CGRect] = []
        var clockWidget: CGRect = .zero
        var musicWidget: CGRect = .zero
        var statusBarY: CGFloat = 0
    }

    private let apps: [App] = [
        App(name: "Messages", symbol: "message.fill", top: .systemGreen, bottom: UIColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1)),
        App(name: "Photos", symbol: "photo.on.rectangle.angled", top: .systemOrange, bottom: .systemPink),
        App(name: "Camera", symbol: "camera.fill", top: .systemGray2, bottom: .darkGray),
        App(name: "Mail", symbol: "envelope.fill", top: .systemCyan, bottom: .systemBlue),
        App(name: "Maps", symbol: "map.fill", top: .systemMint, bottom: .systemGreen),
        App(name: "Weather", symbol: "cloud.sun.fill", top: .systemCyan, bottom: .systemIndigo),
        App(name: "Notes", symbol: "note.text", top: .systemYellow, bottom: .systemOrange),
        App(name: "Music", symbol: "music.note", top: .systemPink, bottom: .systemRed),
        App(name: "Calendar", symbol: "calendar", top: .systemRed, bottom: UIColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1)),
        App(name: "Podcasts", symbol: "mic.fill", top: .systemPurple, bottom: .systemIndigo),
        App(name: "Files", symbol: "folder.fill", top: .systemBlue, bottom: .systemIndigo),
        App(name: "Mirror", symbol: "rectangle.on.rectangle", top: .systemBlue, bottom: .systemPurple),
        App(name: "Clock", symbol: "clock.fill", top: .darkGray, bottom: .black),
        App(name: "Health", symbol: "heart.fill", top: .systemPink, bottom: .systemRed),
        App(name: "Books", symbol: "book.fill", top: .systemOrange, bottom: .systemBrown),
        App(name: "Settings", symbol: "gearshape.fill", top: .systemGray, bottom: .darkGray),
        App(name: "TV", symbol: "tv.fill", top: .darkGray, bottom: .black),
        App(name: "Fitness", symbol: "figure.run", top: .systemGreen, bottom: .systemTeal)
    ]

    private let dockApps: [App] = [
        App(name: "Phone", symbol: "phone.fill", top: .systemGreen, bottom: UIColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1)),
        App(name: "Safari", symbol: "safari.fill", top: .systemCyan, bottom: .systemBlue),
        App(name: "Messages", symbol: "message.fill", top: .systemGreen, bottom: UIColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1)),
        App(name: "Music", symbol: "music.note", top: .systemPink, bottom: .systemRed)
    ]

    init(pixelSize: CGSize, scale: CGFloat, kind: DeviceKind) {
        self.pixelSize = pixelSize
        self.scale = scale
        self.kind = kind
    }

    func draw(into buffer: CVPixelBuffer, time: Double) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        if background == nil { background = makeBackground() }
        if let background {
            context.draw(background, in: CGRect(origin: .zero, size: pixelSize))
        }

        // Switch to UIKit's top-left coordinates in points.
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        drawLiveContent(time: time)
        UIGraphicsPopContext()
    }

    // MARK: Static background

    private func makeBackground() -> CGImage? {
        computeLayout()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            // Wallpaper
            let colors = [UIColor(red: 0.25, green: 0.45, blue: 0.95, alpha: 1).cgColor,
                          UIColor(red: 0.55, green: 0.3, blue: 0.85, alpha: 1).cgColor,
                          UIColor(red: 0.95, green: 0.45, blue: 0.55, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width * 0.6, y: size.height), options: [])
            }
            // Soft light blobs
            for (center, radius, alpha) in [(CGPoint(x: size.width * 0.8, y: size.height * 0.2), size.width * 0.5, 0.18),
                                            (CGPoint(x: size.width * 0.1, y: size.height * 0.75), size.width * 0.45, 0.12)] {
                UIColor.white.withAlphaComponent(alpha).setFill()
                UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            }

            // Widgets (backgrounds only; the live parts are drawn every frame)
            UIColor.black.withAlphaComponent(0.28).setFill()
            UIBezierPath(roundedRect: layout.clockWidget, cornerRadius: 22).fill()
            let musicColors = [UIColor.systemPink.cgColor, UIColor.systemOrange.cgColor] as CFArray
            cg.saveGState()
            UIBezierPath(roundedRect: layout.musicWidget, cornerRadius: 22).addClip()
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: musicColors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: layout.musicWidget.origin,
                                      end: CGPoint(x: layout.musicWidget.maxX, y: layout.musicWidget.maxY), options: [])
            }
            cg.restoreGState()

            // App icons
            for (index, frame) in layout.iconFrames.enumerated() where index < apps.count {
                drawIcon(apps[index], in: frame, label: true)
            }

            // Dock
            let dockWidth = min(size.width - 24, CGFloat(dockApps.count) * (layout.iconSize + 22) + 26)
            let dockRect = CGRect(x: (size.width - dockWidth) / 2, y: size.height - layout.iconSize - 44, width: dockWidth, height: layout.iconSize + 28)
            UIColor.white.withAlphaComponent(0.22).setFill()
            UIBezierPath(roundedRect: dockRect, cornerRadius: 30).fill()
            for (index, app) in dockApps.enumerated() {
                let x = dockRect.minX + 13 + CGFloat(index) * (layout.iconSize + 22) + 11
                drawIcon(app, in: CGRect(x: x, y: dockRect.minY + 14, width: layout.iconSize, height: layout.iconSize), label: false)
            }

            // Page dots
            for index in 0..<3 {
                (index == 0 ? UIColor.white : UIColor.white.withAlphaComponent(0.45)).setFill()
                UIBezierPath(ovalIn: CGRect(x: size.width / 2 - 20 + CGFloat(index) * 16, y: dockRect.minY - 22, width: 7, height: 7)).fill()
            }
        }
        return image.cgImage
    }

    private func computeLayout() {
        var layout = Layout()
        layout.iconSize = isLandscape ? 64 : 60
        layout.statusBarY = isLandscape ? 10 : 16

        let margin: CGFloat = isLandscape ? 40 : 24
        let top: CGFloat = isLandscape ? 50 : 66

        if isLandscape {
            let widgetWidth: CGFloat = 300
            layout.clockWidget = CGRect(x: margin, y: top, width: widgetWidth, height: 150)
            layout.musicWidget = CGRect(x: margin, y: top + 170, width: widgetWidth, height: 150)
            let gridX = margin + widgetWidth + 40
            let columns = 6
            let spacingX = (size.width - gridX - margin - CGFloat(columns) * layout.iconSize) / CGFloat(columns - 1)
            for index in 0..<apps.count {
                let row = index / columns, column = index % columns
                layout.iconFrames.append(CGRect(x: gridX + CGFloat(column) * (layout.iconSize + spacingX),
                                                y: top + CGFloat(row) * (layout.iconSize + 44),
                                                width: layout.iconSize, height: layout.iconSize))
            }
        } else {
            let widgetSide = (size.width - margin * 2 - 20) / 2
            layout.clockWidget = CGRect(x: margin, y: top, width: widgetSide, height: widgetSide)
            layout.musicWidget = CGRect(x: margin + widgetSide + 20, y: top, width: widgetSide, height: widgetSide)
            let columns = 4
            let spacingX = (size.width - margin * 2 - CGFloat(columns) * layout.iconSize) / CGFloat(columns - 1)
            let gridTop = top + widgetSide + 34
            for index in 0..<16 {
                let row = index / columns, column = index % columns
                layout.iconFrames.append(CGRect(x: margin + CGFloat(column) * (layout.iconSize + spacingX),
                                                y: gridTop + CGFloat(row) * (layout.iconSize + 34),
                                                width: layout.iconSize, height: layout.iconSize))
            }
        }
        self.layout = layout
    }

    private func drawIcon(_ app: App, in frame: CGRect, label: Bool) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        cg.saveGState()
        UIBezierPath(roundedRect: frame, cornerRadius: frame.width * 0.225).addClip()
        let colors = [app.top.cgColor, app.bottom.cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            cg.drawLinearGradient(gradient, start: frame.origin, end: CGPoint(x: frame.minX, y: frame.maxY), options: [])
        }
        cg.restoreGState()

        let config = UIImage.SymbolConfiguration(pointSize: frame.width * 0.45, weight: .medium)
        if let glyph = UIImage(systemName: app.symbol, withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
            let glyphRect = CGRect(x: frame.midX - glyph.size.width / 2, y: frame.midY - glyph.size.height / 2,
                                   width: glyph.size.width, height: glyph.size.height)
            glyph.draw(in: glyphRect)
        }

        if label {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: UIColor.white,
                .paragraphStyle: style
            ]
            (app.name as NSString).draw(in: CGRect(x: frame.minX - 14, y: frame.maxY + 6, width: frame.width + 28, height: 16), withAttributes: attributes)
        }
    }

    // MARK: Live content

    private func drawLiveContent(time: Double) {
        let now = Date()

        // Status bar
        let statusFont = UIFont.systemFont(ofSize: 16, weight: .semibold)
        let timeText = now.formatted(date: .omitted, time: .shortened)
        (timeText as NSString).draw(at: CGPoint(x: isLandscape ? 28 : 36, y: layout.statusBarY),
                                    withAttributes: [.font: statusFont, .foregroundColor: UIColor.white])
        drawBattery(at: CGPoint(x: size.width - (isLandscape ? 60 : 64), y: layout.statusBarY + 3))

        // Clock widget with seconds, so it's obvious the picture is live
        let clock = layout.clockWidget
        let seconds = now.formatted(.dateTime.hour().minute().second())
        let bigFont = UIFont.monospacedDigitSystemFont(ofSize: clock.width * 0.17, weight: .semibold)
        (seconds as NSString).draw(at: CGPoint(x: clock.minX + 16, y: clock.midY - bigFont.lineHeight / 2),
                                   withAttributes: [.font: bigFont, .foregroundColor: UIColor.white])
        let day = now.formatted(.dateTime.weekday(.wide).month().day())
        (day.uppercased() as NSString).draw(at: CGPoint(x: clock.minX + 16, y: clock.minY + 16),
                                            withAttributes: [.font: UIFont.systemFont(ofSize: 12, weight: .bold),
                                                             .foregroundColor: UIColor.white.withAlphaComponent(0.75)])
        ("Live from \(kind.displayName)" as NSString).draw(at: CGPoint(x: clock.minX + 16, y: clock.maxY - 30),
                                                           withAttributes: [.font: UIFont.systemFont(ofSize: 12, weight: .medium),
                                                                            .foregroundColor: UIColor.white.withAlphaComponent(0.75)])

        // Music widget: equalizer + progress
        let music = layout.musicWidget
        ("Now Playing" as NSString).draw(at: CGPoint(x: music.minX + 16, y: music.minY + 16),
                                         withAttributes: [.font: UIFont.systemFont(ofSize: 12, weight: .bold),
                                                          .foregroundColor: UIColor.white.withAlphaComponent(0.8)])
        ("Mirror Mode" as NSString).draw(at: CGPoint(x: music.minX + 16, y: music.maxY - 62),
                                         withAttributes: [.font: UIFont.systemFont(ofSize: 17, weight: .bold),
                                                          .foregroundColor: UIColor.white])
        UIColor.white.setFill()
        let barCount = 7
        let barArea = CGRect(x: music.minX + 16, y: music.minY + 40, width: music.width - 32, height: music.height - 110)
        let barWidth = barArea.width / CGFloat(barCount * 2 - 1)
        for index in 0..<barCount {
            let level = 0.25 + 0.75 * abs(sin(time * (2.2 + Double(index) * 0.35) + Double(index)))
            let height = barArea.height * CGFloat(level)
            UIBezierPath(roundedRect: CGRect(x: barArea.minX + CGFloat(index) * barWidth * 2, y: barArea.maxY - height,
                                             width: barWidth, height: height), cornerRadius: barWidth / 2).fill()
        }
        let progress = CGFloat(time.truncatingRemainder(dividingBy: 30) / 30)
        let track = CGRect(x: music.minX + 16, y: music.maxY - 24, width: music.width - 32, height: 5)
        UIColor.white.withAlphaComponent(0.35).setFill()
        UIBezierPath(roundedRect: track, cornerRadius: 2.5).fill()
        UIColor.white.setFill()
        UIBezierPath(roundedRect: CGRect(x: track.minX, y: track.minY, width: track.width * progress, height: track.height), cornerRadius: 2.5).fill()

        // A finger moving between apps and tapping them
        drawFinger(time: time)
    }

    private func drawBattery(at origin: CGPoint) {
        UIColor.white.setStroke()
        let body = UIBezierPath(roundedRect: CGRect(x: origin.x, y: origin.y, width: 25, height: 12), cornerRadius: 3.5)
        body.lineWidth = 1
        body.stroke()
        UIColor.white.setFill()
        UIBezierPath(roundedRect: CGRect(x: origin.x + 2, y: origin.y + 2, width: 21, height: 8), cornerRadius: 2).fill()
        UIBezierPath(roundedRect: CGRect(x: origin.x + 26, y: origin.y + 4, width: 2, height: 4), cornerRadius: 1).fill()
    }

    private func drawFinger(time: Double) {
        let frames = layout.iconFrames
        guard frames.count > 1 else { return }
        let stepDuration = 1.6
        let step = Int(time / stepDuration)
        let phase = (time / stepDuration) - Double(step)
        let from = frames[(step * 5) % frames.count]
        let to = frames[((step + 1) * 5) % frames.count]

        let moveFraction = min(1, phase / 0.6)
        let eased = moveFraction < 0.5 ? 2 * moveFraction * moveFraction : 1 - pow(-2 * moveFraction + 2, 2) / 2
        let position = CGPoint(x: from.midX + (to.midX - from.midX) * eased,
                               y: from.midY + (to.midY - from.midY) * eased)

        if phase > 0.6 {
            // Tap: the icon dims and a ripple grows
            let tap = (phase - 0.6) / 0.4
            UIColor.black.withAlphaComponent(0.25 * (1 - tap)).setFill()
            UIBezierPath(roundedRect: to, cornerRadius: to.width * 0.225).fill()
            let radius = 20 + 30 * tap
            UIColor.white.withAlphaComponent(0.5 * (1 - tap)).setStroke()
            let ripple = UIBezierPath(ovalIn: CGRect(x: position.x - radius, y: position.y - radius, width: radius * 2, height: radius * 2))
            ripple.lineWidth = 3
            ripple.stroke()
        }

        UIColor.white.withAlphaComponent(0.55).setFill()
        UIBezierPath(ovalIn: CGRect(x: position.x - 20, y: position.y - 20, width: 40, height: 40)).fill()
        UIColor.white.withAlphaComponent(0.9).setStroke()
        let ring = UIBezierPath(ovalIn: CGRect(x: position.x - 20, y: position.y - 20, width: 40, height: 40))
        ring.lineWidth = 2
        ring.stroke()
    }
}
