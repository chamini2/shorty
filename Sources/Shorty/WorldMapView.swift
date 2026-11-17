import AppKit
import ShortyCore

/// A faint world map that sits behind a list, with a dot on every place the
/// list holds and a beacon on the one selected. The land is barely lighter
/// than the box, so the rows stay readable over it; the beacon is the one
/// bright thing.
@MainActor
final class WorldMapView: NSView {
    private enum Metrics {
        static let inset: CGFloat = 14
        static let dotRadius: CGFloat = 3
        static let placeRadius: CGFloat = 2.5
        static let placeAlpha: CGFloat = 0.45
        static let pulseScale: CGFloat = 4.5
        static let pulseDuration: CFTimeInterval = 2.0
        static let landAlpha: CGFloat = 0.05
    }

    private let landLayer = CAShapeLayer()
    private let meridianLayer = CAShapeLayer()
    private let placesLayer = CALayer()
    private let beaconLayer = CALayer()
    private let dotLayer = CAShapeLayer()
    private let pulseLayer = CAShapeLayer()
    private var markers: [WorldMapMarker] = []
    private var marker: WorldMapMarker?
    private var mapRect: CGRect = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)

        wantsLayer = true
        layer?.masksToBounds = true

        landLayer.fillColor = NSColor(calibratedWhite: 1, alpha: Metrics.landAlpha).cgColor
        landLayer.fillRule = .nonZero
        layer?.addSublayer(landLayer)

        meridianLayer.strokeColor = accent.withAlphaComponent(0.45).cgColor
        meridianLayer.lineWidth = 1
        meridianLayer.lineDashPattern = [3, 4]
        meridianLayer.isHidden = true
        layer?.addSublayer(meridianLayer)

        layer?.addSublayer(placesLayer)

        let dot = CGPath(
            ellipseIn: CGRect(x: -Metrics.dotRadius, y: -Metrics.dotRadius, width: Metrics.dotRadius * 2, height: Metrics.dotRadius * 2),
            transform: nil
        )
        dotLayer.path = dot
        dotLayer.fillColor = accent.cgColor
        dotLayer.shadowColor = accent.cgColor
        dotLayer.shadowOpacity = 0.9
        dotLayer.shadowRadius = 4
        dotLayer.shadowOffset = .zero

        pulseLayer.path = dot
        pulseLayer.fillColor = nil
        pulseLayer.strokeColor = accent.cgColor
        pulseLayer.lineWidth = 1

        beaconLayer.addSublayer(pulseLayer)
        beaconLayer.addSublayer(dotLayer)
        beaconLayer.isHidden = true
        layer?.addSublayer(beaconLayer)

        startPulse()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private var accent: NSColor {
        .controlAccentColor
    }

    /// Dots every city in `markers`, and lights the beacon on `selected`, or
    /// on nothing when the selection has no place.
    func show(_ markers: [WorldMapMarker], selected: WorldMapMarker?) {
        if markers != self.markers {
            self.markers = markers
            rebuildPlaces()
        }

        marker = selected
        updateMarker()
    }

    override func layout() {
        super.layout()
        rebuildMap()
        rebuildPlaces()
        updateMarker()
    }

    /// One dim dot per city. The selected one gets the beacon drawn over it.
    private func rebuildPlaces() {
        placesLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        placesLayer.frame = bounds

        let dot = CGPath(
            ellipseIn: CGRect(
                x: -Metrics.placeRadius,
                y: -Metrics.placeRadius,
                width: Metrics.placeRadius * 2,
                height: Metrics.placeRadius * 2
            ),
            transform: nil
        )

        for case let .city(coordinate) in markers {
            let place = CAShapeLayer()
            place.path = dot
            place.fillColor = accent.withAlphaComponent(Metrics.placeAlpha).cgColor
            place.position = point(for: coordinate)
            placesLayer.addSublayer(place)
        }
    }

    /// Equirectangular, as wide as the view allows with the inset, and
    /// sitting at the bottom so the first rows have the empty north to
    /// themselves.
    private func rebuildMap() {
        let available = bounds.insetBy(dx: Metrics.inset, dy: Metrics.inset)
        let longitudeSpan = CGFloat(WorldMapOutline.longitudeRange.upperBound - WorldMapOutline.longitudeRange.lowerBound)
        let latitudeSpan = CGFloat(WorldMapOutline.latitudeRange.upperBound - WorldMapOutline.latitudeRange.lowerBound)
        let scale = min(available.width / longitudeSpan, available.height / latitudeSpan)
        let size = CGSize(width: longitudeSpan * scale, height: latitudeSpan * scale)

        mapRect = CGRect(
            x: available.midX - size.width / 2,
            y: available.minY,
            width: size.width,
            height: size.height
        )

        let path = CGMutablePath()
        for ring in WorldMapOutline.rings {
            guard let first = ring.first else {
                continue
            }

            path.move(to: point(for: first))
            for coordinate in ring.dropFirst() {
                path.addLine(to: point(for: coordinate))
            }
            path.closeSubpath()
        }

        landLayer.frame = bounds
        landLayer.path = path
        meridianLayer.frame = bounds
    }

    private func point(for coordinate: GeoCoordinate) -> CGPoint {
        let x = (coordinate.longitude - WorldMapOutline.longitudeRange.lowerBound)
            / (WorldMapOutline.longitudeRange.upperBound - WorldMapOutline.longitudeRange.lowerBound)
        let y = (coordinate.latitude - WorldMapOutline.latitudeRange.lowerBound)
            / (WorldMapOutline.latitudeRange.upperBound - WorldMapOutline.latitudeRange.lowerBound)

        return CGPoint(
            x: mapRect.minX + CGFloat(x) * mapRect.width,
            y: mapRect.minY + CGFloat(y) * mapRect.height
        )
    }

    /// Nothing here animates: the beacon goes out on one city and comes on
    /// at the next. The pulse is the only motion.
    private func updateMarker() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        switch marker {
        case let .city(coordinate)?:
            beaconLayer.isHidden = false
            meridianLayer.isHidden = true
            beaconLayer.position = point(for: coordinate)

        case let .meridian(longitude)?:
            beaconLayer.isHidden = true
            meridianLayer.isHidden = false
            let x = point(for: GeoCoordinate(latitude: 0, longitude: longitude)).x
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: mapRect.minY))
            path.addLine(to: CGPoint(x: x, y: mapRect.maxY))
            meridianLayer.path = path

        case nil:
            beaconLayer.isHidden = true
            meridianLayer.isHidden = true
        }

        CATransaction.commit()
    }

    /// A ring that grows out of the dot and fades, over and over.
    private func startPulse() {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = Metrics.pulseScale

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8
        fade.toValue = 0

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = Metrics.pulseDuration
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulseLayer.add(group, forKey: "pulse")
    }
}
