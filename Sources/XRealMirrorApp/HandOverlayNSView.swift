import AppKit
import QuartzCore
import XRealVision

/// Transparent overlay pinned to an eye pane. Draws each tracked hand as 21 dots + 21 connection lines, one color per
/// hand, 1€-smoothed per joint, mapped through the pane's aspect-fit image rect. No hands → draws nothing, so the
/// stage-1 mirror shows through unchanged. Main thread only (called from EyeView.updateNSView).
final class HandOverlayNSView: NSView {
    static let dotRadius: CGFloat = 3
    static let lineWidth: CGFloat = 2
    static let maxHands = 2

    /// One dots + lines layer pair per hand slot (two hands may share a chirality, so slots aren't keyed by it).
    private var slots: [(dots: CAShapeLayer, lines: CAShapeLayer)] = []
    /// Smoothing banks (21 filters each). Hands are unordered frame to frame, so banks are keyed by chirality plus
    /// its occurrence count ("left#0", "left#1", …); when the key set changes the banks restart.
    private var banks: [String: [OneEuroFilter]] = [:]
    /// Last input drawn. SwiftUI calls update at the 60 fps mirror rate but results change at 30 fps; re-feeding the
    /// same result would double-step the filters, so identical input is skipped.
    private var lastInput: [(HandChirality, [SIMD2<Float>])]?

    /// Contract landmarks are top-left origin; a flipped view keeps that orientation in the layers (pinned by
    /// HandOverlayRenderTests: a point at the top of the image renders at the top of the pane).
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        for _ in 0..<Self.maxHands {
            let lines = CAShapeLayer()
            lines.fillColor = nil
            lines.lineWidth = Self.lineWidth
            lines.lineCap = .round
            let dots = CAShapeLayer()
            for l in [lines, dots] {
                l.frame = bounds
                l.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]  // no implicit animation lag
                layer?.addSublayer(l)
            }
            slots.append((dots: dots, lines: lines))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // never steal clicks from the pane

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for s in slots { s.dots.frame = bounds; s.lines.frame = bounds }
        CATransaction.commit()
    }

    func update(hands: EyeHands?, timestamp: TimeInterval = CACurrentMediaTime()) {
        let present = Array((hands?.hands ?? []).filter { $0.landmarks.count == 21 }.prefix(Self.maxHands))
        let input = present.map { ($0.chirality, $0.landmarks) }
        if let last = lastInput, last.count == input.count,
           zip(last, input).allSatisfy({ $0.0 == $1.0 && $0.1 == $1.1 }) { return }
        lastInput = input
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard !present.isEmpty else {
            for s in slots { s.dots.path = nil; s.lines.path = nil }
            banks.removeAll()
            return
        }

        var seen: [HandChirality: Int] = [:]
        let keys = present.map { h -> String in
            let n = seen[h.chirality, default: 0]
            seen[h.chirality] = n + 1
            return "\(h.chirality)#\(n)"
        }
        if Set(keys) != Set(banks.keys) {
            banks = Dictionary(uniqueKeysWithValues: keys.map { ($0, [OneEuroFilter](repeating: OneEuroFilter(), count: 21)) })
        }

        let rect = AspectFitRect.fit(imageWidth: FrameLayout.uprightWidth, imageHeight: FrameLayout.uprightHeight, in: bounds)
        for (i, s) in slots.enumerated() {
            guard i < present.count else { s.dots.path = nil; s.lines.path = nil; continue }
            var hand = present[i]
            var bank = banks[keys[i]]!
            for j in 0..<21 { hand.landmarks[j] = bank[j].filter(hand.landmarks[j], timestamp: timestamp) }
            banks[keys[i]] = bank

            let geo = SkeletonPathBuilder.geometry(hand: hand, in: rect)
            let dots = CGMutablePath()
            let r = Self.dotRadius
            for p in geo.dots { dots.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
            let lines = CGMutablePath()
            for (a, b) in geo.lines { lines.move(to: a); lines.addLine(to: b) }

            let color = Self.color(for: hand.chirality).cgColor
            s.dots.fillColor = color
            s.lines.strokeColor = color
            s.dots.path = dots
            s.lines.path = lines
        }
    }

    static func color(for chirality: HandChirality) -> NSColor {
        switch chirality {
        case .left: return .systemCyan
        case .right: return .systemOrange
        case .unknown: return .systemYellow
        }
    }
}
