import ARKit
import SceneKit
import SwiftUI

/// Рулетка: наведите крестик на начало, нажмите «+», наведите на конец, нажмите «+» — готов размер.
/// Точка находится лидаром, поэтому меряет и на гладких стенах. Без скана всей комнаты.
final class Ruler: NSObject, ObservableObject, ARSessionDelegate {
    struct Measure: Identifiable {
        let id = UUID()
        let meters: Double
        let nodes: [SCNNode]
    }

    let view = ARSCNView(frame: .zero)
    @Published var live: Double?
    @Published var aimed = false
    @Published var started = false
    @Published var list: [Measure] = []
    @Published var torch = false
    @Published var tracking: String?
    let hasTorch = Torch.available

    private var start: SIMD3<Float>?
    private var startNode: SCNNode?
    private let liveLine = SCNNode()
    private var timer: Timer?
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    static let yellow = UIColor(red: 0.96, green: 0.77, blue: 0.09, alpha: 1)

    func run() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) { config.sceneReconstruction = .mesh }
        view.session.delegate = self
        view.automaticallyUpdatesLighting = true
        view.scene.rootNode.addChildNode(liveLine)
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        UIApplication.shared.isIdleTimerDisabled = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.aim() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        setTorch(false)
        view.session.pause()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func setTorch(_ on: Bool) {
        guard hasTorch else { return }
        torch = Torch.set(on)
    }

    /// Точка под крестиком (середина экрана)
    private func hit() -> SIMD3<Float>? {
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard view.bounds.width > 0,
              let q = view.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .any),
              let r = view.session.raycast(q).first else { return nil }
        let t = r.worldTransform.columns.3
        return SIMD3(t.x, t.y, t.z)
    }

    private func aim() {
        let p = hit()
        aimed = p != nil
        if let a = start, let p {
            live = Double(simd_distance(a, p))
            liveLine.childNodes.forEach { $0.removeFromParentNode() }
            liveLine.addChildNode(Ruler.rod(a, p, radius: 0.0025, color: Ruler.yellow.withAlphaComponent(0.8)))
        } else {
            live = nil
        }
    }

    /// «+»: первая точка — начало, вторая — конец и готовый размер
    func place() {
        guard let p = hit() else { return }
        haptic.impactOccurred()
        if let a = start {
            liveLine.childNodes.forEach { $0.removeFromParentNode() }
            let meters = Double(simd_distance(a, p))
            let line = Ruler.rod(a, p, radius: 0.003, color: Ruler.yellow)
            let end = Ruler.dot(p)
            let label = Ruler.label(Ruler.text(meters), at: (a + p) / 2 + SIMD3(0, 0.03, 0))
            [line, end, label].forEach { view.scene.rootNode.addChildNode($0) }
            list.insert(Measure(meters: meters, nodes: [startNode, line, end, label].compactMap { $0 }), at: 0)
            start = nil
            startNode = nil
            started = false
            live = nil
        } else {
            start = p
            let n = Ruler.dot(p)
            view.scene.rootNode.addChildNode(n)
            startNode = n
            started = true
        }
    }

    /// Отменить: незаконченный замер или последний размер
    func undo() {
        if started {
            startNode?.removeFromParentNode()
            liveLine.childNodes.forEach { $0.removeFromParentNode() }
            start = nil
            startNode = nil
            started = false
            live = nil
        } else if let last = list.first {
            last.nodes.forEach { $0.removeFromParentNode() }
            list.removeFirst()
        }
    }

    func clear() {
        if started { undo() }
        for m in list { m.nodes.forEach { $0.removeFromParentNode() } }
        list.removeAll()
    }

    static func text(_ m: Double) -> String {
        m < 1 ? "\(Int((m * 100).rounded())) см" : "\(fmt((m * 100).rounded() / 100)) м"
    }

    // MARK: - Подсказки

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let text: String?
        switch camera.trackingState {
        case .normal: text = nil
        case .notAvailable: text = "Камера не видит комнату"
        case .limited(let reason):
            switch reason {
            case .initializing: text = "Поводите телефоном — камера настраивается"
            case .excessiveMotion: text = "Ведите телефон медленнее"
            case .insufficientFeatures: text = "Мало деталей — включите свет или фонарик"
            default: text = nil
            }
        }
        DispatchQueue.main.async { self.tracking = text }
    }

    // MARK: - 3D

    static func dot(_ p: SIMD3<Float>) -> SCNNode {
        let s = SCNSphere(radius: 0.008)
        s.firstMaterial?.diffuse.contents = UIColor.white
        s.firstMaterial?.emission.contents = yellow
        let n = SCNNode(geometry: s)
        n.simdPosition = p
        return n
    }

    static func rod(_ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: CGFloat, color: UIColor) -> SCNNode {
        let len = simd_distance(a, b)
        let c = SCNCylinder(radius: radius, height: CGFloat(max(len, 0.0001)))
        c.firstMaterial?.diffuse.contents = color
        c.firstMaterial?.emission.contents = color
        c.firstMaterial?.lightingModel = .constant
        let n = SCNNode(geometry: c)
        n.simdPosition = (a + b) / 2
        // цилиндр стоит по оси Y — поворачиваем вдоль отрезка
        let dir = len > 0 ? (b - a) / len : SIMD3<Float>(0, 1, 0)
        n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: dir)
        return n
    }

    /// Табличка с размером, всегда повёрнута к камере
    static func label(_ s: String, at p: SIMD3<Float>) -> SCNNode {
        let font = UIFont.systemFont(ofSize: 44, weight: .heavy)
        let size = (s as NSString).size(withAttributes: [.font: font])
        let pad: CGFloat = 18
        let img = UIGraphicsImageRenderer(size: CGSize(width: size.width + pad * 2, height: size.height + pad)).image { ctx in
            let r = CGRect(origin: .zero, size: ctx.format.bounds.size)
            yellow.setFill()
            UIBezierPath(roundedRect: r, cornerRadius: r.height / 2).fill()
            (s as NSString).draw(at: CGPoint(x: pad, y: pad / 2),
                                 withAttributes: [.font: font, .foregroundColor: UIColor(red: 0.08, green: 0.13, blue: 0.18, alpha: 1)])
        }
        let h: CGFloat = 0.045
        let plane = SCNPlane(width: h * img.size.width / img.size.height, height: h)
        plane.firstMaterial?.diffuse.contents = img
        plane.firstMaterial?.lightingModel = .constant
        plane.firstMaterial?.isDoubleSided = true
        let n = SCNNode(geometry: plane)
        n.simdPosition = p
        n.constraints = [SCNBillboardConstraint()]
        n.renderingOrder = 10
        plane.firstMaterial?.readsFromDepthBuffer = false
        return n
    }
}

struct RulerScene: UIViewRepresentable {
    let ruler: Ruler
    func makeUIView(context: Context) -> ARSCNView { ruler.view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct MeasureView: View {
    @StateObject private var ruler = Ruler()
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        ZStack {
            RulerScene(ruler: ruler).ignoresSafeArea()
            crosshair
            VStack(spacing: 12) {
                top
                if let t = ruler.tracking {
                    Text(t).font(.subheadline.bold()).foregroundStyle(.white)
                        .padding(10).background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                }
                Spacer()
                if let live = ruler.live {
                    Text(Ruler.text(live))
                        .font(.system(size: 40, weight: .heavy, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(Palette.signal, in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text(ruler.started ? "Наведите крестик на конец" : (ruler.aimed ? "Наведите крестик на начало и нажмите +" : "Наведите камеру на стену или пол"))
                        .font(.subheadline.bold()).foregroundStyle(.white)
                        .padding(10).background(Color.black.opacity(0.55), in: Capsule())
                }
                controls
                if !ruler.list.isEmpty { results }
            }
            .padding()
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: ruler.live != nil)
        }
        .onAppear { ruler.run() }
        .onDisappear { ruler.stop() }
    }

    private var crosshair: some View {
        ZStack {
            Circle().stroke(ruler.aimed ? Palette.signal : Color.white.opacity(0.6), lineWidth: 2).frame(width: 34, height: 34)
            Circle().fill(ruler.aimed ? Palette.signal : Color.white.opacity(0.6)).frame(width: 6, height: 6)
        }
        .scaleEffect(ruler.aimed ? 1 : 0.85)
        .animation(.easeOut(duration: 0.2), value: ruler.aimed)
        .allowsHitTesting(false)
    }

    private var top: some View {
        HStack {
            Button("Закрыть") { dismiss() }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
            Spacer()
            if ruler.hasTorch {
                Button { ruler.setTorch(!ruler.torch) } label: {
                    Image(systemName: ruler.torch ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.title3).frame(width: 44, height: 44)
                        .background(ruler.torch ? Palette.signal : Color.clear, in: Circle())
                        .background(.ultraThinMaterial, in: Circle())
                        .foregroundStyle(ruler.torch ? Palette.ink : Color.primary)
                }
                .accessibilityLabel(ruler.torch ? "Выключить фонарик" : "Включить фонарик")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Button { ruler.undo() } label: {
                Image(systemName: "arrow.uturn.backward").font(.title2.bold())
                    .frame(width: 54, height: 54).background(.ultraThinMaterial, in: Circle())
            }
            .disabled(!ruler.started && ruler.list.isEmpty)
            .accessibilityLabel("Отменить")
            Button { ruler.place() } label: {
                Image(systemName: "plus").font(.system(size: 34, weight: .bold))
                    .frame(width: 78, height: 78)
                    .background(Palette.signal, in: Circle())
                    .foregroundStyle(Palette.ink)
            }
            .buttonStyle(PressStyle())
            .disabled(!ruler.aimed)
            .accessibilityLabel(ruler.started ? "Поставить конец" : "Поставить начало")
            Button { ruler.clear() } label: {
                Image(systemName: "trash").font(.title2.bold())
                    .frame(width: 54, height: 54).background(.ultraThinMaterial, in: Circle())
            }
            .disabled(ruler.list.isEmpty)
            .accessibilityLabel("Очистить всё")
        }
        .foregroundStyle(.white)
    }

    private var results: some View {
        HStack {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(ruler.list.enumerated()), id: \.element.id) { i, m in
                        Text("\(ruler.list.count - i). \(Ruler.text(m.meters))")
                            .font(.subheadline.bold()).monospacedDigit()
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
            Button {
                UIPasteboard.general.string = ruler.list.reversed().enumerated()
                    .map { "\($0.offset + 1). \(Ruler.text($0.element.meters))" }.joined(separator: "\n")
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.headline)
                    .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Скопировать размеры")
        }
        .onChange(of: ruler.list.count) { _ in copied = false }
    }
}
