import AppKit

/// Menu bar icon: a small grape cluster of rings with a stem, after the Gather V2 app icon.
/// A coloured dot shows what is currently being mirrored.
enum Icon {
    static let size = NSSize(width: 18, height: 18)

    private static let ringRadius: CGFloat = 2.05
    private static let ringWidth: CGFloat = 1.35
    private static let rings: [CGPoint] = [
        CGPoint(x: 14.6, y: 14.2),
        CGPoint(x: 3.6, y: 8.9),
        CGPoint(x: 9.1, y: 10.4),
        CGPoint(x: 14.5, y: 8.6),
        CGPoint(x: 9.0, y: 4.6),
    ]

    static let teamsPurple = NSColor(srgbRed: 0.384, green: 0.392, blue: 0.655, alpha: 1)
    static let busyRed = NSColor(srgbRed: 0.90, green: 0.22, blue: 0.21, alpha: 1)
    static let warningOrange = NSColor(srgbRed: 0.96, green: 0.62, blue: 0.04, alpha: 1)

    static func image(for mode: Snapshot.Mode, problem: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            drawGrapes(NSColor.labelColor.withAlphaComponent(mode == .paused ? 0.35 : 1))

            let badge: NSColor? = switch mode {
            case .gatherCall: busyRed
            case .teamsCall: teamsPurple
            case .idle, .paused: problem ? warningOrange : nil
            }
            if let badge {
                let rect = CGRect(x: 12.4, y: 0.4, width: 5.2, height: 5.2)
                badge.setFill()
                NSBezierPath(ovalIn: rect).fill()
            }
            if mode == .paused {
                let slash = NSBezierPath()
                slash.lineWidth = 1.5
                slash.lineCapStyle = .round
                slash.move(to: CGPoint(x: 1.5, y: 1.5))
                slash.line(to: CGPoint(x: 16.5, y: 16.5))
                NSColor.labelColor.setStroke()
                slash.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Stem and rings in the 18×18 menu bar coordinate space.
    private static func drawGrapes(_ ink: NSColor) {
        ink.setStroke()

        let stem = NSBezierPath()
        stem.lineWidth = 1.35
        stem.lineCapStyle = .round
        stem.move(to: CGPoint(x: 7.4, y: 13.0))
        stem.line(to: CGPoint(x: 5.6, y: 15.4))
        stem.line(to: CGPoint(x: 3.0, y: 15.9))
        stem.move(to: CGPoint(x: 5.6, y: 15.4))
        stem.line(to: CGPoint(x: 6.1, y: 17.6))
        stem.stroke()

        for center in rings {
            let ring = NSBezierPath(ovalIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                                   width: ringRadius * 2, height: ringRadius * 2))
            ring.lineWidth = ringWidth
            ring.stroke()
        }
    }

    /// Writes the app icon as an .iconset for `iconutil`: `StatusSync --render-app-icon <dir>.iconset`.
    /// A dark tile like the Gather app icon, white grapes and a Teams-purple dot.
    static func renderAppIcon(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                let unit = CGFloat(pixels) / 1024 // design on a 1024 canvas, macOS icon grid

                let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
                    .applying(CGAffineTransform(scaleX: unit, y: unit))
                let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * unit, yRadius: 185 * unit)
                NSGradient(starting: NSColor(white: 0.22, alpha: 1), ending: NSColor(white: 0.08, alpha: 1))!
                    .draw(in: tilePath, angle: -90)

                let transform = NSAffineTransform()
                transform.translateX(by: 232 * unit, yBy: 232 * unit)
                transform.scale(by: 560 / size.width * unit)
                NSGraphicsContext.saveGraphicsState()
                transform.concat()
                drawGrapes(NSColor(white: 0.95, alpha: 1))
                teamsPurple.setFill()
                NSBezierPath(ovalIn: CGRect(x: 12.4, y: 0.4, width: 5.2, height: 5.2)).fill()
                NSGraphicsContext.restoreGraphicsState()

                NSGraphicsContext.restoreGraphicsState()
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
            }
        }
    }

    /// Writes every state as PNG (8x) for a visual check: `StatusSync --render-icons <dir>`.
    static func render(to directory: URL) throws {
        let states: [(String, Snapshot.Mode, Bool)] = [
            ("idle", .idle, false), ("gather-call", .gatherCall, false),
            ("teams-call", .teamsCall, false), ("paused", .paused, false), ("problem", .idle, true),
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, mode, problem) in states {
                let scale: CGFloat = 8
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                           pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    (appearance == .aqua ? NSColor.white : NSColor(white: 0.15, alpha: 1)).setFill()
                    CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)).fill()
                    image(for: mode, problem: problem).draw(in: CGRect(x: 0, y: 0, width: size.width * scale,
                                                                       height: size.height * scale))
                    NSGraphicsContext.restoreGraphicsState()
                }
                let suffix = appearance == .aqua ? "light" : "dark"
                try rep.representation(using: .png, properties: [:])!
                    .write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
    }
}
