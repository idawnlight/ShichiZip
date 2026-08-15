import AppKit

/// Draws a progress bar across the bottom of the Dock icon while archive
/// operations run.
@MainActor
final class DockProgressController {
    static let shared = DockProgressController()

    private static let canvasSize = NSSize(width: 128, height: 128)

    private var activeTokens: Set<UUID> = []
    private var fractions: [UUID: Double] = [:]
    private var renderedPercent: Int?
    private let tileView = NSImageView()

    func begin() -> UUID {
        let token = UUID()
        activeTokens.insert(token)
        return token
    }

    func update(_ token: UUID, fraction: Double?) {
        guard activeTokens.contains(token) else { return }
        fractions[token] = fraction
        render()
    }

    func end(_ token: UUID) {
        guard activeTokens.remove(token) != nil else { return }
        fractions[token] = nil

        guard activeTokens.isEmpty else {
            render()
            return
        }

        renderedPercent = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }

    /// Average of the operations that report a determinate fraction. Phases that
    /// cannot report progress, such as scanning, hold no entry rather than
    /// contributing a zero that would look stalled.
    private var aggregateFraction: Double? {
        guard !fractions.isEmpty else { return nil }
        return fractions.values.reduce(0, +) / Double(fractions.count)
    }

    private func render() {
        guard let fraction = aggregateFraction else { return }

        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        guard percent != renderedPercent else { return }
        renderedPercent = percent

        tileView.image = makeTileImage(fraction: Double(percent) / 100)
        NSApp.dockTile.contentView = tileView
        NSApp.dockTile.display()
    }

    private func makeTileImage(fraction: Double) -> NSImage {
        let size = Self.canvasSize
        let bounds = NSRect(origin: .zero, size: size)
        let image = NSImage(size: size)

        // Drawn synchronously rather than through NSImage's drawing handler,
        // which AppKit may invoke off the main actor when it caches.
        image.lockFocus()
        NSApp.applicationIconImage?.draw(in: bounds)
        Self.drawProgressBar(in: bounds, fraction: fraction)
        image.unlockFocus()

        return image
    }

    private static func drawProgressBar(in bounds: NSRect, fraction: Double) {
        let barHeight = bounds.height * 0.17
        let horizontalInset = bounds.width * 0.17
        let track = NSRect(x: horizontalInset,
                           y: bounds.height * 0.14,
                           width: bounds.width - horizontalInset * 2,
                           height: barHeight)
        let radius = barHeight / 2

        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }

        let trackPath = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.55).setFill()
        trackPath.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        trackPath.lineWidth = 1
        trackPath.stroke()

        let progress = min(max(fraction, 0), 1)
        guard progress > 0 else { return }

        let inset = track.insetBy(dx: 2.5, dy: 2.5)
        // Narrower than one full cap the rounded rect degenerates, so early
        // progress reads as a dot instead of a lopsided sliver.
        let fillWidth = max(inset.width * progress, inset.height)
        let fill = NSRect(x: inset.minX, y: inset.minY, width: fillWidth, height: inset.height)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill,
                     xRadius: inset.height / 2,
                     yRadius: inset.height / 2).fill()
    }
}
