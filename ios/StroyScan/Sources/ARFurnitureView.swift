import ARKit
import SceneKit
import SwiftUI

/// Вещь из ремонта в 3D, которую ставим в настоящую комнату
struct ARPiece: Identifiable {
    let id = UUID()
    let title: String
    let kind: String
    let variant: String
    let color: String
    let width: Double
    let depth: Double
    let height: Double
    let palette: Palette3D
}

/// Мебель в настоящей комнате через камеру: в натуральную величину, двигать пальцем, крутить двумя.
/// Включается только по кнопке — во время скана поверх камеры ничего не рисуем.
final class ARPlacer: NSObject, ObservableObject, ARSCNViewDelegate {
    let view = ARSCNView(frame: .zero)
    let piece: ARPiece
    @Published var placed = false
    @Published var floorFound = false
    private var node: SCNNode?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    init(_ piece: ARPiece) {
        self.piece = piece
        super.init()
        view.delegate = self
        view.automaticallyUpdatesLighting = true
        view.autoenablesDefaultLighting = true
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
        view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        view.addGestureRecognizer(UIRotationGestureRecognizer(target: self, action: #selector(rotate(_:))))
    }

    func run() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        view.session.pause()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Точка на полу под пальцем
    private func floor(at p: CGPoint) -> SIMD3<Float>? {
        guard let q = view.raycastQuery(from: p, allowing: .existingPlaneInfinite, alignment: .horizontal)
                ?? view.raycastQuery(from: p, allowing: .estimatedPlane, alignment: .horizontal),
              let r = view.session.raycast(q).first else { return nil }
        let t = r.worldTransform.columns.3
        return SIMD3(t.x, t.y, t.z)
    }

    @objc private func tap(_ g: UITapGestureRecognizer) {
        guard let p = floor(at: g.location(in: view)) else { return }
        if node == nil {
            let n = Furniture3D.build(kind: piece.kind, variant: piece.variant, width: Float(piece.width), depth: Float(piece.depth),
                                      height: Float(piece.height), color: piece.color, palette: piece.palette,
                                      againstWall: LookOptions.againstWall(piece.kind, piece.variant))
            // лицом к человеку
            if let cam = view.session.currentFrame?.camera.transform {
                let f = SIMD2(cam.columns.3.x - p.x, cam.columns.3.z - p.z)
                n.simdEulerAngles.y = atan2(f.x, f.y)
            }
            n.simdPosition = p
            n.scale = SCNVector3(0.001, 0.001, 0.001)
            view.scene.rootNode.addChildNode(n)
            let grow = SCNAction.scale(to: 1, duration: 0.35)
            grow.timingMode = .easeOut
            n.runAction(grow)
            node = n
            placed = true
            haptic.impactOccurred()
        } else {
            node?.runAction(.move(to: SCNVector3(p.x, p.y, p.z), duration: 0.2))
        }
    }

    @objc private func pan(_ g: UIPanGestureRecognizer) {
        guard let node, let p = floor(at: g.location(in: view)) else { return }
        node.simdPosition = p
    }

    @objc private func rotate(_ g: UIRotationGestureRecognizer) {
        guard let node else { return }
        node.simdEulerAngles.y -= Float(g.rotation)
        g.rotation = 0
    }

    func turn() {
        node?.runAction(.rotateBy(x: 0, y: .pi / 2, z: 0, duration: 0.25))
    }

    func remove() {
        node?.removeFromParentNode()
        node = nil
        placed = false
    }

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard anchor is ARPlaneAnchor else { return }
        DispatchQueue.main.async { self.floorFound = true }
    }
}

struct PlacerScene: UIViewRepresentable {
    let placer: ARPlacer
    func makeUIView(context: Context) -> ARSCNView { placer.view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct ARFurnitureView: View {
    @StateObject private var placer: ARPlacer
    @Environment(\.dismiss) private var dismiss

    init(piece: ARPiece) {
        _placer = StateObject(wrappedValue: ARPlacer(piece))
    }

    var body: some View {
        ZStack {
            PlacerScene(placer: placer).ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    Button("Готово") { dismiss() }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                Spacer()
                Text(hint).font(.subheadline.bold()).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(12).background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
                if placer.placed {
                    HStack(spacing: 14) {
                        Button { placer.turn() } label: {
                            Label("Повернуть", systemImage: "rotate.right").font(.headline)
                                .padding(.horizontal, 18).padding(.vertical, 12)
                                .background(Palette.signal, in: Capsule()).foregroundStyle(Palette.ink)
                        }
                        Button { placer.remove() } label: {
                            Label("Убрать", systemImage: "trash").font(.headline)
                                .padding(.horizontal, 18).padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .foregroundStyle(.white)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Text(sizeLine).font(.caption.bold()).foregroundStyle(.white.opacity(0.85))
            }
            .padding()
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: placer.placed)
        }
        .onAppear { placer.run() }
        .onDisappear { placer.stop() }
    }

    private var hint: String {
        if placer.placed { return "Двигайте пальцем по полу, крутите двумя пальцами. Нажмите на пол — переставить." }
        if placer.floorFound { return "Нажмите на пол, где поставить: \(placer.piece.title.lowercased())" }
        return "Медленно поводите камерой по полу, чтобы телефон его нашёл"
    }

    private var sizeLine: String {
        let cm = { (v: Double) in Int((v * 100).rounded()) }
        let p = placer.piece
        return "\(p.title): \(cm(p.width)) × \(cm(p.depth)) × \(cm(p.height)) см — в натуральную величину"
    }
}
