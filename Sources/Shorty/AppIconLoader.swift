import AppKit

/// Icons for rows, drawn off the main thread.
///
/// `NSWorkspace.icon(forFile:)` hands back a proxy that costs nothing until
/// something draws it, and drawing a few hundred of them takes over a second.
/// Doing that while the box is opening is the whole delay, so the work happens
/// elsewhere and the rows are told when each one is ready.
@MainActor
final class AppIconLoader {
    /// The largest a row draws an icon, which the detailed file rows set. A
    /// bitmap at twice that is sharp on every display, and scaling it down
    /// for the small rows costs nothing.
    nonisolated static let pointSize: CGFloat = 32

    private var icons: [String: NSImage] = [:]
    private var loading: Set<String> = []

    /// Called when icons have arrived, so the list can draw itself again.
    var didLoad: (() -> Void)?

    /// The icon if it is ready. Otherwise nothing, and it is fetched for next
    /// time: a row with no icon yet simply leaves the space empty.
    func icon(at path: String) -> NSImage? {
        if let icon = icons[path] {
            return icon
        }

        load(path)

        return nil
    }

    /// Reads ahead for rows the list is about to show.
    func prepare(_ paths: [String]) {
        paths.forEach(load)
    }

    private func load(_ path: String) {
        guard icons[path] == nil, !loading.contains(path) else {
            return
        }

        loading.insert(path)

        Task.detached(priority: .userInitiated) {
            let icon = Self.rasterised(path)

            await MainActor.run {
                self.loading.remove(path)

                guard let icon else {
                    return
                }

                self.icons[path] = icon
                self.didLoad?()
            }
        }
    }

    /// Draws the proxy once, into a bitmap of the size the row uses. What
    /// comes back carries no more work for the main thread to do.
    private nonisolated static func rasterised(_ path: String) -> NSImage? {
        let source = NSWorkspace.shared.icon(forFile: path)
        let pixels = Int(pointSize * 2)

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        source.draw(in: NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
        NSGraphicsContext.restoreGraphicsState()

        let icon = NSImage(size: NSSize(width: pointSize, height: pointSize))
        icon.addRepresentation(representation)

        return icon
    }
}
