import SceneKit
import SwiftUI
import simd

/// Экран итога: комната «собирается» из скана — стены вырастают одна за другой, проёмы загораются,
/// мебель падает на место, камера медленно облетает комнату. Нажатие — собрать ещё раз.
struct AssembleView: View {
    let result: RoomResult
    @State private var run = 0
    @State private var area: Double = 0

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AssembleScene(result: result, run: run)
            VStack(alignment: .leading, spacing: 2) {
                Text("Комната собрана по скану").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    CountUp(value: area, digits: 1).font(.system(size: 34, weight: .heavy, design: .rounded))
                    Text("м² пола").font(.subheadline.bold())
                }
                .foregroundStyle(Palette.signal)
            }
            .padding(16)
            .allowsHitTesting(false)
            Image(systemName: "arrow.counterclockwise")
                .font(.footnote.bold())
                .foregroundStyle(.white.opacity(0.6))
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
        }
        .frame(height: 240)
        .background(Palette.ink)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .contentShape(Rectangle())
        .onTapGesture { replay() }
        .onAppear { count() }
        .accessibilityLabel("3D-модель комнаты, пол \(fmt(result.floorArea)) квадратных метров")
    }

    private func count() {
        area = 0
        withAnimation(.easeOut(duration: 1.6).delay(0.4)) { area = result.floorArea }
    }

    private func replay() {
        run += 1
        count()
    }
}

/// Число, которое «набегает» от старого значения к новому
struct CountUp: View, Animatable {
    var value: Double
    var digits = 2
    /// Рубли: «12 400 ₽»
    var money = false
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        let k = pow(10, Double(digits))
        Text(money ? Estimate.money(value) : fmt((value * k).rounded() / k)).monospacedDigit()
    }
}

/// Сцена SceneKit, которая собирает комнату
struct AssembleScene: UIViewRepresentable {
    let result: RoomResult
    let run: Int

    final class Coordinator {
        var run = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = UIColor(Palette.ink)
        view.antialiasingMode = .multisampling4X
        view.isUserInteractionEnabled = false
        view.rendersContinuously = false
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard context.coordinator.run != run else { return }
        context.coordinator.run = run
        let scene = AssembleScene.build(result)
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "cam", recursively: true)
        view.isPlaying = true
    }

    static func build(_ r: RoomResult) -> SCNScene {
        let scene = SCNScene()
        let root = scene.rootNode
        let lines = r.wallLines
        let pts = r.plan
        guard !pts.isEmpty || !lines.isEmpty else { return scene }
        let all = pts + lines.flatMap { [SIMD2($0.x, $0.y), SIMD2($0.z, $0.w)] }
        let minX = all.map(\.x).min() ?? 0, maxX = all.map(\.x).max() ?? 1
        let minY = all.map(\.y).min() ?? 0, maxY = all.map(\.y).max() ?? 1
        let c = SIMD2((minX + maxX) / 2, (minY + maxY) / 2)
        let span = Float(max(maxX - minX, maxY - minY, 2))
        let h = Float(r.height > 1.5 ? r.height : 2.6)
        // план (x, y) → сцена (x, z), центр комнаты — в нуле
        func p3(_ x: Double, _ y: Double, _ up: Float = 0) -> SCNVector3 {
            SCNVector3(Float(x - c.x), up, Float(y - c.y))
        }

        // пол
        if pts.count > 2 {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: pts[0].x - c.x, y: -(pts[0].y - c.y)))
            for p in pts.dropFirst() { path.addLine(to: CGPoint(x: p.x - c.x, y: -(p.y - c.y))) }
            path.close()
            let shape = SCNShape(path: path, extrusionDepth: 0.02)
            shape.firstMaterial = mat(UIColor(Palette.draft).withAlphaComponent(0.55), emission: UIColor(Palette.draft).withAlphaComponent(0.25))
            let floor = SCNNode(geometry: shape)
            floor.eulerAngles.x = -.pi / 2
            floor.opacity = 0
            floor.runAction(.fadeIn(duration: 0.5))
            root.addChildNode(floor)
        }

        // стены вырастают по очереди
        let wallMat = mat(UIColor(white: 0.93, alpha: 1))
        let edgeMat = mat(UIColor(Palette.signal), emission: UIColor(Palette.signal))
        let step = min(0.18, 1.6 / Double(max(lines.count, 1)))
        for (i, l) in lines.enumerated() {
            let dx = l.z - l.x, dy = l.w - l.y
            let len = Float(hypot(dx, dy))
            guard len > 0.02 else { continue }
            let wall = SCNNode()
            wall.position = p3((l.x + l.z) / 2, (l.y + l.w) / 2)
            wall.eulerAngles.y = Float(atan2(-dy, dx))
            let body = SCNNode(geometry: SCNBox(width: CGFloat(len), height: CGFloat(h), length: 0.06, chamferRadius: 0))
            body.geometry?.firstMaterial = wallMat
            body.position.y = h / 2
            let edge = SCNNode(geometry: SCNBox(width: CGFloat(len), height: 0.025, length: 0.07, chamferRadius: 0))
            edge.geometry?.firstMaterial = edgeMat
            edge.position.y = h
            wall.addChildNode(body)
            wall.addChildNode(edge)
            wall.scale = SCNVector3(1, 0.001, 1)
            wall.runAction(.sequence([.wait(duration: 0.3 + Double(i) * step), grow(0.55)]))
            root.addChildNode(wall)
        }
        let wallsDone = 0.3 + Double(lines.count) * step + 0.5

        // окна и двери загораются
        for (k, o) in r.openings.enumerated() {
            guard let wi = o.wall, wi < lines.count, let off = o.offset else { continue }
            let l = lines[wi]
            let a = SIMD2(l.x, l.y), b = SIMD2(l.z, l.w)
            let len = simd_distance(a, b)
            guard len > 0 else { continue }
            let p = a + (b - a) / len * off
            let node = SCNNode(geometry: SCNBox(width: CGFloat(o.width), height: CGFloat(o.height), length: 0.09, chamferRadius: 0))
            let color: UIColor = o.kind == "window" ? UIColor(red: 0.45, green: 0.8, blue: 1, alpha: 0.85) : UIColor(Palette.signal).withAlphaComponent(0.8)
            node.geometry?.firstMaterial = mat(color, emission: color.withAlphaComponent(0.6))
            node.position = p3(p.x, p.y, Float((o.bottom ?? 0) + o.height / 2))
            node.eulerAngles.y = Float(atan2(-(b.y - a.y), b.x - a.x))
            node.opacity = 0
            node.runAction(.sequence([.wait(duration: wallsDone + Double(k) * 0.08), .fadeIn(duration: 0.35)]))
            root.addChildNode(node)
        }

        // мебель падает на место
        let furnitureStart = wallsDone + Double(r.openings.count) * 0.08 + 0.2
        for (k, it) in r.items.enumerated() {
            let box = SCNBox(width: CGFloat(max(it.width, 0.05)), height: CGFloat(max(it.height, 0.05)),
                             length: CGFloat(max(it.depth, 0.05)), chamferRadius: 0.02)
            box.firstMaterial = mat(UIColor(furnitureColor(it.kind)))
            let node = SCNNode(geometry: box)
            let y = Float(it.bottom + it.height / 2)
            node.position = p3(it.x, it.y, y + 2.2)
            node.eulerAngles.y = Float(-it.angle)
            node.opacity = 0
            let drop = SCNAction.move(to: p3(it.x, it.y, y), duration: 0.5)
            drop.timingMode = .easeIn
            let bounce = SCNAction.sequence([.moveBy(x: 0, y: 0.06, z: 0, duration: 0.09), .moveBy(x: 0, y: -0.06, z: 0, duration: 0.09)])
            node.runAction(.sequence([.wait(duration: furnitureStart + Double(k) * 0.1),
                                      .group([.fadeIn(duration: 0.2), drop]), bounce]))
            root.addChildNode(node)
        }

        // свет
        let amb = SCNNode()
        amb.light = SCNLight()
        amb.light?.type = .ambient
        amb.light?.intensity = 450
        root.addChildNode(amb)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 900
        sun.eulerAngles = SCNVector3(-0.9, 0.6, 0)
        root.addChildNode(sun)

        // камера облетает комнату
        let orbit = SCNNode()
        let cam = SCNNode()
        cam.name = "cam"
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 40
        cam.camera?.zFar = 200
        let dist = span * 1.55 + 1.2
        cam.position = SCNVector3(0, dist * 0.8, dist)
        cam.look(at: SCNVector3(0, h * 0.25, 0))
        orbit.addChildNode(cam)
        orbit.eulerAngles.y = 0.6
        orbit.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 40)))
        root.addChildNode(orbit)
        scene.background.contents = UIColor(Palette.ink)
        return scene
    }

    private static func mat(_ color: UIColor, emission: UIColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .lambert
        if let emission { m.emission.contents = emission }
        m.isDoubleSided = true
        return m
    }

    /// Стена вырастает от пола с лёгким перелётом
    private static func grow(_ duration: TimeInterval) -> SCNAction {
        let a = SCNAction.customAction(duration: duration) { node, t in
            let x = Float(t / CGFloat(duration))
            // ease-out-back: чуть выше и обратно
            let s: Float = 1.70158
            let k = x - 1
            let v = 1 + (s + 1) * k * k * k + s * k * k
            node.scale = SCNVector3(1, max(0.001, v), 1)
        }
        return a
    }
}
