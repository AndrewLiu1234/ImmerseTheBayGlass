import AppKit
import QuartzCore
import SceneKit
import XRealVision

/// SceneKit scene for the live 3-D hands: the glasses at the origin (two camera markers, 13.6 cm apart), a 10 cm
/// reference grid below eye level, and per hand 21 joint spheres + 21 bone cylinders, 1€-smoothed. Main thread only.
@MainActor
final class Hands3DScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private var rigs: [Hand3D.Side: HandRig] = [:]
    /// The fretboard, drawn in the guitar frame; its transform follows the tracked guitar pose.
    let guitarNode = SCNNode()
    private var guitarBoardName: String?

    static let jointRadius: CGFloat = 0.006
    static let boneRadius: CGFloat = 0.0035

    init(calibration: StereoCalibration = .active) {
        scene.background.contents = NSColor.black
        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = 10
        camera.fieldOfView = 55
        cameraNode.camera = camera
        // Default view: behind and above the glasses, looking at where hands are (≈25 cm ahead, 20 cm down).
        cameraNode.simdPosition = SIMD3(0.07, 0.25, 0.35)
        cameraNode.simdLook(at: SIMD3(0.07, -0.15, -0.25))
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 400
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.simdEulerAngles = SIMD3(-0.8, 0.4, 0)
        scene.rootNode.addChildNode(key)

        addGlasses(calibration)
        addGrid()
        guitarNode.isHidden = true
        scene.rootNode.addChildNode(guitarNode)
        for side in [Hand3D.Side.left, .right] {
            let rig = HandRig(color: Self.color(for: side))
            rigs[side] = rig
            scene.rootNode.addChildNode(rig.root)
        }
    }

    static func color(for side: Hand3D.Side) -> NSColor { side == .left ? .systemCyan : .systemOrange }

    /// Current colour of a fingertip sphere (for tests and debugging).
    func tipColor(side: Hand3D.Side, finger: FingerOnFretboard.Finger) -> NSColor? { rigs[side]?.tipColor(finger) }

    /// Camera frame (x right, y down, z forward) → scene frame (x right, y up, the glasses look down -z).
    nonisolated static func scenePoint(_ p: SIMD3<Double>) -> SIMD3<Float> { SIMD3(Float(p.x), Float(-p.y), Float(-p.z)) }

    struct Bone: Equatable { var position: SIMD3<Float>; var orientation: simd_quatf; var length: Float }

    /// Placement for an SCNCylinder (local +y axis) spanning a → b.
    nonisolated static func bone(from a: SIMD3<Float>, to b: SIMD3<Float>) -> Bone {
        let d = b - a, len = simd_length(d)
        let up = SIMD3<Float>(0, 1, 0)
        guard len > 1e-7 else { return Bone(position: a, orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), length: 0) }
        let dir = d / len
        let q: simd_quatf
        if simd_dot(up, dir) < -0.99999 {
            q = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))   // straight down: simd_quatf(from:to:) is ill-defined
        } else {
            q = simd_quatf(from: up, to: dir)
        }
        return Bone(position: (a + b) / 2, orientation: q, length: len)
    }

    /// Show these hands (at most one per side); sides not present are hidden and their smoothing restarts.
    /// `placements` colour the fingertips over the fretboard (green = pressing, yellow = hovering).
    func update(_ hands: [Hand3D], placements: [FingerPlacement] = [], timestamp: TimeInterval = CACurrentMediaTime()) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        var shown = Set<Hand3D.Side>()
        for h in hands where !shown.contains(h.side) {
            shown.insert(h.side)
            rigs[h.side]?.show(h, timestamp: timestamp)
            var states: [FingerOnFretboard.Finger: FingertipMarks.State] = [:]
            for p in placements where p.side == h.side && p.onNeck { states[p.finger] = p.pressing ? .pressing : .hovering }
            rigs[h.side]?.setTips(states)
        }
        for (side, rig) in rigs where !shown.contains(side) { rig.hide() }
        SCNTransaction.commit()
    }

    /// Show the fretboard at `pose` (nil hides it). Geometry is built once per fretboard spec.
    func update(guitar pose: GuitarPose?, board: Fretboard) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        defer { SCNTransaction.commit() }
        guard let pose else { guitarNode.isHidden = true; return }
        if guitarBoardName != board.spec.name { buildGuitar(board) }
        // Scene = S · camera with S = diag(1, −1, −1) (a proper rotation), so node transform = [S·R | S·t].
        let s = simd_double3x3(diagonal: SIMD3(1, -1, -1))
        let r = s * pose.rotation, t = s * pose.translation
        func f(_ v: SIMD3<Double>) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), 0) }
        guitarNode.simdTransform = simd_float4x4(columns: (f(r.columns.0), f(r.columns.1), f(r.columns.2),
                                                           SIMD4(Float(t.x), Float(t.y), Float(t.z), 1)))
        guitarNode.isHidden = false
    }

    private func buildGuitar(_ board: Fretboard) {
        guitarNode.childNodes.forEach { $0.removeFromParentNode() }
        func lines(_ segs: [(SIMD3<Double>, SIMD3<Double>)], color: NSColor) -> SCNNode {
            let verts = segs.flatMap { [SCNVector3($0.0.x, $0.0.y, $0.0.z), SCNVector3($0.1.x, $0.1.y, $0.1.z)] }
            let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)],
                                  elements: [SCNGeometryElement(indices: (0..<Int32(verts.count)).map { $0 }, primitiveType: .line)])
            let m = SCNMaterial()
            m.diffuse.contents = color
            m.lightingModel = .constant
            geo.materials = [m]
            return SCNNode(geometry: geo)
        }
        let end = board.fretX(board.spec.fretCount) + 0.01
        guitarNode.addChildNode(lines([board.fretLine(0)], color: .white))
        guitarNode.addChildNode(lines((1...board.spec.fretCount).map { board.fretLine($0) }, color: .systemYellow))
        guitarNode.addChildNode(lines(board.strings.map { ($0.nut, $0.saddle) }, color: NSColor(white: 0.85, alpha: 1)))
        guitarNode.addChildNode(lines([-1.0, 1.0].map { (SIMD3(0, $0 * board.halfWidth(atX: 0), 0),
                                                         SIMD3(end, $0 * board.halfWidth(atX: end), 0)) }, color: .systemGreen))
        guitarBoardName = board.spec.name
    }

    private func addGlasses(_ cal: StereoCalibration) {
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor.white
        mat.emission.contents = NSColor(white: 0.4, alpha: 1)
        let rightC = Self.scenePoint(cal.rightCenterInLeft)
        for c in [SIMD3<Float>(0, 0, 0), rightC] {
            let cam = SCNNode(geometry: SCNBox(width: 0.02, height: 0.012, length: 0.012, chamferRadius: 0.002))
            cam.geometry?.materials = [mat]
            cam.simdPosition = c
            scene.rootNode.addChildNode(cam)
        }
        let barBone = Self.bone(from: .zero, to: rightC)
        let bar = SCNNode(geometry: SCNCylinder(radius: 0.002, height: CGFloat(barBone.length)))
        bar.geometry?.materials = [mat]
        bar.simdPosition = barBone.position
        bar.simdOrientation = barBone.orientation
        scene.rootNode.addChildNode(bar)
    }

    /// 1 m × 1 m grid of 10 cm squares, 35 cm below the glasses, centred ahead of them.
    private func addGrid() {
        var verts: [SCNVector3] = [], idx: [Int32] = []
        let y: CGFloat = -0.35, step: CGFloat = 0.1
        for k in 0...10 {
            let o = CGFloat(k) * step
            verts += [SCNVector3(-0.43 + o, y, 0.1), SCNVector3(-0.43 + o, y, -0.9),
                      SCNVector3(-0.43, y, 0.1 - o), SCNVector3(0.57, y, 0.1 - o)]
        }
        idx = (0..<Int32(verts.count)).map { $0 }
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)],
                              elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(white: 0.35, alpha: 1)
        mat.lightingModel = .constant
        geo.materials = [mat]
        scene.rootNode.addChildNode(SCNNode(geometry: geo))
    }
}

/// One hand's nodes + per-joint smoothing.
@MainActor
private final class HandRig {
    let root = SCNNode()
    private var joints: [SCNNode] = []
    private var bones: [(node: SCNNode, cylinder: SCNCylinder, from: Int, to: Int)] = []
    private var filters: [OneEuroFilter3]?
    private let color: NSColor
    /// Fingertips get their own material so they can show the fretboard state.
    private var tipMaterials: [FingerOnFretboard.Finger: SCNMaterial] = [:]

    init(color: NSColor) {
        self.color = color
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.emission.contents = color.withAlphaComponent(0.35)
        let tipJoints = Dictionary(uniqueKeysWithValues: FingerOnFretboard.Finger.allCases.map { ($0.tipJoint, $0) })
        for i in 0..<21 {
            let n = SCNNode(geometry: SCNSphere(radius: Hands3DScene.jointRadius))
            if let finger = tipJoints[i] {
                let m = SCNMaterial()
                m.diffuse.contents = color
                m.emission.contents = color.withAlphaComponent(0.35)
                n.geometry?.materials = [m]
                tipMaterials[finger] = m
            } else {
                n.geometry?.materials = [mat]
            }
            root.addChildNode(n)
            joints.append(n)
        }
        let boneMat = SCNMaterial()
        boneMat.diffuse.contents = color.withAlphaComponent(0.8)
        for c in HandSkeleton.connections {
            let cyl = SCNCylinder(radius: Hands3DScene.boneRadius, height: 0.01)
            cyl.materials = [boneMat]
            let n = SCNNode(geometry: cyl)
            root.addChildNode(n)
            bones.append((n, cyl, c.from, c.to))
        }
        root.isHidden = true
    }

    func setTips(_ states: [FingerOnFretboard.Finger: FingertipMarks.State]) {
        for (finger, m) in tipMaterials {
            let c = states[finger].map(FingertipMarks.color(for:)) ?? color
            m.diffuse.contents = c
            m.emission.contents = c.withAlphaComponent(states[finger] == nil ? 0.35 : 0.8)
        }
    }

    func tipColor(_ finger: FingerOnFretboard.Finger) -> NSColor? { tipMaterials[finger]?.diffuse.contents as? NSColor }

    func show(_ hand: Hand3D, timestamp: TimeInterval) {
        if filters == nil { filters = [OneEuroFilter3](repeating: OneEuroFilter3(), count: 21) }
        var pts = [SIMD3<Float>](repeating: .zero, count: 21)
        for i in 0..<21 {
            let smoothed = filters![i].filter(hand.joints[i], timestamp: timestamp)
            pts[i] = Hands3DScene.scenePoint(smoothed)
            joints[i].simdPosition = pts[i]
        }
        for b in bones {
            let placement = Hands3DScene.bone(from: pts[b.from], to: pts[b.to])
            b.cylinder.height = CGFloat(placement.length)
            b.node.simdPosition = placement.position
            b.node.simdOrientation = placement.orientation
        }
        root.isHidden = false
    }

    func hide() {
        root.isHidden = true
        filters = nil
    }
}
