import CoreGraphics
import XRealVision

/// Where a `.resizeAspect` layer actually draws an image inside its bounds. Landmarks are normalized to the IMAGE,
/// so every overlay drawing path goes through this rect — never the raw pane bounds (the letterbox trap).
enum AspectFitRect {
    static func fit(imageWidth: Int, imageHeight: Int, in container: CGRect) -> CGRect {
        guard imageWidth > 0, imageHeight > 0, container.width > 0, container.height > 0 else { return .zero }
        let iw = CGFloat(imageWidth), ih = CGFloat(imageHeight)
        let scale = min(container.width / iw, container.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: container.midX - w / 2, y: container.midY - h / 2, width: w, height: h)
    }
}

/// One hand's drawable geometry, in the coordinate space of the rect it was built for.
struct SkeletonGeometry: Equatable {
    var dots: [CGPoint]                 // 21, canonical HandJoint order
    var lines: [(CGPoint, CGPoint)]     // 21, HandSkeleton.connections order

    static func == (a: SkeletonGeometry, b: SkeletonGeometry) -> Bool {
        a.dots == b.dots && a.lines.count == b.lines.count
            && zip(a.lines, b.lines).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

enum SkeletonPathBuilder {
    /// Maps contract landmarks (normalized, origin top-left — no flip here) into `rect`. Draws every point; v1 does
    /// not filter by confidence. A connection whose endpoint index is out of range is skipped.
    static func geometry(hand: TrackedHand, in rect: CGRect) -> SkeletonGeometry {
        let dots = hand.landmarks.map { p in
            CGPoint(x: rect.minX + CGFloat(p.x) * rect.width, y: rect.minY + CGFloat(p.y) * rect.height)
        }
        let lines = HandSkeleton.connections.compactMap { c -> (CGPoint, CGPoint)? in
            guard dots.indices.contains(c.from), dots.indices.contains(c.to) else { return nil }
            return (dots[c.from], dots[c.to])
        }
        return SkeletonGeometry(dots: dots, lines: lines)
    }
}
