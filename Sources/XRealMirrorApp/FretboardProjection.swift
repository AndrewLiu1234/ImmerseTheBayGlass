import AppKit
import QuartzCore
import simd
import XRealVision

/// Projects the fretboard (nut, frets, strings, edges) into one eye's image. Straight lines curve in a fisheye, so
/// every line is sampled every few millimetres and projected point by point; points behind the camera or far outside
/// the image break the line into separate segments.
enum FretboardProjection {
    enum Eye: Sendable { case left, right }

    struct Line: Sendable, Equatable {
        enum Kind: Sendable { case nut, fret, string, edge }
        var kind: Kind
        /// Polylines in contract-normalized image coordinates (origin top-left, 0…1 over the 480×640 image).
        var segments: [[SIMD2<Float>]]
    }

    static let imageSize = SIMD2<Double>(Double(FrameLayout.uprightWidth), Double(FrameLayout.uprightHeight))

    /// Guitar-frame point → normalized image point in `eye`, or nil if it's behind that camera / far off-image.
    static func project(_ g: SIMD3<Double>, pose: GuitarPose, eye: Eye, calibration: StereoCalibration) -> SIMD2<Float>? {
        let left = pose.toCamera(g)
        let px: SIMD2<Double>?
        switch eye {
        case .left: px = calibration.left.project(left)
        case .right: px = calibration.right.project(calibration.leftToRight(left))
        }
        guard let px else { return nil }
        let n = (px + 0.5) / imageSize                         // OpenCV pixel centres → normalized
        guard (-0.2...1.2).contains(n.x), (-0.2...1.2).contains(n.y) else { return nil }
        return SIMD2(Float(n.x), Float(n.y))
    }

    static func lines(board: Fretboard, pose: GuitarPose, eye: Eye, calibration: StereoCalibration,
                      step: Double = 0.005) -> [Line] {
        func polyline(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> [[SIMD2<Float>]] {
            let n = max(1, Int((simd_distance(a, b) / step).rounded(.up)))
            var segments: [[SIMD2<Float>]] = [], current: [SIMD2<Float>] = []
            for i in 0...n {
                if let p = project(a + (b - a) * (Double(i) / Double(n)), pose: pose, eye: eye, calibration: calibration) {
                    current.append(p)
                } else if !current.isEmpty {
                    if current.count >= 2 { segments.append(current) }
                    current = []
                }
            }
            if current.count >= 2 { segments.append(current) }
            return segments
        }
        let end = board.fretX(board.spec.fretCount) + 0.01
        var out: [Line] = [Line(kind: .nut, segments: polyline(board.fretLine(0).0, board.fretLine(0).1))]
        for k in 1...board.spec.fretCount {
            let l = board.fretLine(k)
            out.append(Line(kind: .fret, segments: polyline(l.0, l.1)))
        }
        for s in board.strings { out.append(Line(kind: .string, segments: polyline(s.nut, s.saddle))) }
        for sign in [-1.0, 1.0] {
            out.append(Line(kind: .edge, segments: polyline(SIMD3(0, sign * board.halfWidth(atX: 0), 0),
                                                            SIMD3(end, sign * board.halfWidth(atX: end), 0))))
        }
        return out
    }
}

/// Transparent overlay on an eye pane that draws the projected fretboard, under the hand skeleton. Same geometry
/// rules as HandOverlayNSView: flipped (top-left origin, like the contract) and mapped into the letterboxed image rect.
final class FretboardOverlayNSView: NSView {
    private var layers: [FretboardProjection.Line.Kind: CAShapeLayer] = [:]
    private var tipLayers: [FingertipMarks.State: CAShapeLayer] = [:]
    static let tipRadius: CGFloat = 7
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let styles: [(FretboardProjection.Line.Kind, NSColor, CGFloat)] = [
            (.edge, NSColor.systemGreen.withAlphaComponent(0.9), 2),
            (.fret, NSColor.systemYellow.withAlphaComponent(0.85), 1.5),
            (.string, NSColor.white.withAlphaComponent(0.55), 1),
            (.nut, NSColor.white, 3),
        ]
        for (kind, color, width) in styles {
            let l = CAShapeLayer()
            l.strokeColor = color.cgColor
            l.fillColor = nil
            l.lineWidth = width
            l.lineJoin = .round
            l.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
            l.frame = bounds
            layer?.addSublayer(l)
            layers[kind] = l
        }
        for state in [FingertipMarks.State.hovering, .pressing] {     // drawn above the fretboard lines
            let l = CAShapeLayer()
            let c = FingertipMarks.color(for: state).cgColor
            l.strokeColor = c
            l.fillColor = state == .pressing ? c : nil
            l.lineWidth = 2.5
            l.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
            l.frame = bounds
            layer?.addSublayer(l)
            tipLayers[state] = l
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in layers.values { l.frame = bounds }
        for l in tipLayers.values { l.frame = bounds }
        CATransaction.commit()
    }

    func update(lines: [FretboardProjection.Line], fingertips: [FingertipMarks.Mark] = []) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let rect = AspectFitRect.fit(imageWidth: FrameLayout.uprightWidth, imageHeight: FrameLayout.uprightHeight, in: bounds)
        var paths: [FretboardProjection.Line.Kind: CGMutablePath] = [:]
        for line in lines {
            let path = paths[line.kind] ?? CGMutablePath()
            for seg in line.segments {
                path.addLines(between: seg.map { CGPoint(x: rect.minX + CGFloat($0.x) * rect.width,
                                                         y: rect.minY + CGFloat($0.y) * rect.height) })
            }
            paths[line.kind] = path
        }
        for (kind, l) in layers { l.path = paths[kind] }
        var tips: [FingertipMarks.State: CGMutablePath] = [:]
        let r = Self.tipRadius
        for m in fingertips {
            let c = CGPoint(x: rect.minX + CGFloat(m.point.x) * rect.width, y: rect.minY + CGFloat(m.point.y) * rect.height)
            let path = tips[m.state] ?? CGMutablePath()
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            tips[m.state] = path
        }
        for (state, l) in tipLayers { l.path = tips[state] }
    }
}
