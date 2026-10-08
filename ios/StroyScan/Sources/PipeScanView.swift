import ARKit
import SceneKit
import SwiftUI

/// Скан трубы камерой: наводите крестик на трубу и ставите точки по её ходу (начало, повороты, конец).
/// Лидар видит только открытые трубы — спрятанные в стене не видны, их проводят нажатиями в 3D.
/// Если телефон ещё помнит комнату со скана, труба сразу встаёт на своё место; иначе её привязывают к стене.
final class PipeScanner: NSObject, ObservableObject, ARSessionDelegate {
    let view = ARSCNView(frame: .zero)
    let result: RoomResult
    let shared: Bool
    @Published var kind = PipeKind.all[0]
    @Published var diameter = PipeKind.all[0].diameter
    @Published var points: [SIMD3<Float>] = []
    @Published var aimed = false
    @Published var floorY: Float?
    @Published var live: Double?
    @Published var tracking: String?
    private var timer: Timer?
    private let line = SCNNode()
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    init(result: RoomResult, arSession: ARSession?) {
        self.result = result
        shared = arSession != nil && result.worldFrame != nil
        super.init()
        if let arSession, shared {
            view.session = arSession
            floorY = Float(result.worldFrame?.w ?? 0)
        }
    }

    func run() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }
        view.session.delegate = self
        view.scene.rootNode.addChildNode(line)
        // общий сеанс со скана — без сброса, чтобы координаты остались те же
        view.session.run(config, options: shared ? [] : [.resetTracking, .removeExistingAnchors])
        UIApplication.shared.isIdleTimerDisabled = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.aim() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        line.removeFromParentNode()
        if !shared { view.session.pause() }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func hit() -> SIMD3<Float>? {
        let c = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard view.bounds.width > 0, let q = view.raycastQuery(from: c, allowing: .estimatedPlane, alignment: .any),
              let r = view.session.raycast(q).first else { return nil }
        let t = r.worldTransform.columns.3
        return SIMD3(t.x, t.y, t.z)
    }

    private func aim() {
        let p = hit()
        aimed = p != nil
        redraw(extra: p)
        if let last = points.last, let p { live = Double(simd_distance(last, p)) } else { live = nil }
    }

    private func redraw(extra: SIMD3<Float>?) {
        line.childNodes.forEach { $0.removeFromParentNode() }
        var pts = points
        if let extra, !points.isEmpty { pts.append(extra) }
        let color = kind.color
        for (a, b) in zip(pts, pts.dropFirst()) {
            line.addChildNode(Ruler.rod(a, b, radius: CGFloat(diameter) / 2000, color: color.withAlphaComponent(0.85)))
        }
        for p in points { line.addChildNode(Ruler.dot(p)) }
    }

    /// Пол: если со скана не знаем — по самой низкой найденной горизонтальной плоскости
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { findFloor(anchors) }
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { findFloor(anchors) }

    private func findFloor(_ anchors: [ARAnchor]) {
        guard !shared else { return }
        let ys = anchors.compactMap { a -> Float? in
            guard let p = a as? ARPlaneAnchor, p.alignment == .horizontal else { return nil }
            if ARPlaneAnchor.isClassificationSupported, p.classification != .floor, p.classification != .none(.unknown) { return nil }
            return p.transform.columns.3.y
        }
        guard let low = ys.min() else { return }
        DispatchQueue.main.async {
            if self.floorY == nil || low < self.floorY! { self.floorY = low }
        }
    }

    /// «Это пол»: крестик на полу
    func markFloor() {
        if let p = hit() { floorY = p.y }
    }

    func place() {
        guard let p = hit() else { return }
        haptic.impactOccurred()
        points.append(p)
        redraw(extra: nil)
    }

    func undo() {
        guard !points.isEmpty else { return }
        points.removeLast()
        redraw(extra: nil)
    }

    func setKind(_ k: PipeKind) {
        kind = k
        diameter = k.diameter
    }

    /// Готовая труба: на плане (если координаты общие и труба в комнате) или вдоль стены — для привязки
    func pipe() -> (Engineering.Pipe, Bool)? {
        guard points.count >= 2 else { return nil }
        if shared {
            let plan = points.compactMap { result.toPlan($0) }
            let maxX = (result.plan.map(\.x).max() ?? result.length) + 1.5
            let maxY = (result.plan.map(\.y).max() ?? result.width) + 1.5
            if plan.count == points.count, plan.allSatisfy({ $0.x > -1.5 && $0.y > -1.5 && $0.x < maxX && $0.y < maxY }) {
                return (Engineering.Pipe(kind: kind.id, diameter: diameter, points: plan.map { SIMD3($0.x, $0.y, max(0, $0.z)) }), true)
            }
        }
        // вдоль стены: x — путь по горизонтали от первой точки, z — высота от пола
        let floor = floorY ?? (points.map(\.y).min() ?? 0)
        let first = points[0]
        var dir = SIMD2<Float>(points.last!.x - first.x, points.last!.z - first.z)
        if simd_length(dir) < 0.1 { dir = SIMD2(points[1].x - first.x, points[1].z - first.z) }
        dir = simd_length(dir) > 0.01 ? simd_normalize(dir) : SIMD2(1, 0)
        let local = points.map { p -> SIMD3<Double> in
            let u = simd_dot(SIMD2(p.x - first.x, p.z - first.z), dir)
            return SIMD3(Double(u), 0, Double(max(0, p.y - floor)))
        }
        return (Engineering.Pipe(kind: kind.id, diameter: diameter, points: local), false)
    }

    var length: Double {
        Double(zip(points, points.dropFirst()).reduce(Float(0)) { $0 + simd_distance($1.0, $1.1) })
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let text: String?
        switch camera.trackingState {
        case .normal: text = nil
        case .limited(.relocalizing): text = "Вернитесь туда, где снимали комнату"
        case .limited(.initializing): text = "Поводите телефоном — камера настраивается"
        case .limited(.excessiveMotion): text = "Ведите телефон медленнее"
        case .limited: text = "Мало деталей — включите свет"
        case .notAvailable: text = "Камера не видит комнату"
        }
        DispatchQueue.main.async { self.tracking = text }
    }
}

struct PipeScanScene: UIViewRepresentable {
    let scanner: PipeScanner
    func makeUIView(context: Context) -> ARSCNView { scanner.view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct PipeScanView: View {
    @StateObject private var scanner: PipeScanner
    @Environment(\.dismiss) private var dismiss
    let onDone: (Engineering.Pipe, Bool) -> Void

    init(result: RoomResult, arSession: ARSession?, onDone: @escaping (Engineering.Pipe, Bool) -> Void) {
        _scanner = StateObject(wrappedValue: PipeScanner(result: result, arSession: arSession))
        self.onDone = onDone
    }

    var body: some View {
        ZStack {
            PipeScanScene(scanner: scanner).ignoresSafeArea()
            ZStack {
                Circle().stroke(scanner.aimed ? Palette.signal : Color.white.opacity(0.6), lineWidth: 2).frame(width: 34, height: 34)
                Circle().fill(scanner.aimed ? Palette.signal : Color.white.opacity(0.6)).frame(width: 6, height: 6)
            }
            .allowsHitTesting(false)
            VStack(spacing: 10) {
                HStack {
                    Button("Отмена") { dismiss() }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    Button {
                        if let (pipe, anchored) = scanner.pipe() { onDone(pipe, anchored) }
                        dismiss()
                    } label: {
                        Text("Готово").bold()
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Palette.signal, in: Capsule())
                            .foregroundStyle(Palette.ink)
                    }
                    .disabled(scanner.points.count < 2)
                }
                kinds
                Text(hint).font(.subheadline.bold()).foregroundStyle(.white).multilineTextAlignment(.center)
                    .padding(10).background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                Spacer()
                if let live = scanner.live {
                    Text(Ruler.text(live)).font(.title.bold()).monospacedDigit()
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(Palette.signal, in: Capsule()).foregroundStyle(Palette.ink)
                }
                HStack(spacing: 28) {
                    Button { scanner.undo() } label: {
                        Image(systemName: "arrow.uturn.backward").font(.title2.bold())
                            .frame(width: 54, height: 54).background(.ultraThinMaterial, in: Circle())
                    }
                    .disabled(scanner.points.isEmpty)
                    Button { scanner.place() } label: {
                        Image(systemName: "plus").font(.system(size: 34, weight: .bold))
                            .frame(width: 78, height: 78).background(Palette.signal, in: Circle())
                            .foregroundStyle(Palette.ink)
                    }
                    .buttonStyle(PressStyle())
                    .disabled(!scanner.aimed)
                    Button { scanner.markFloor() } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "square.bottomhalf.filled").font(.title3.bold())
                            Text("Пол").font(.caption2.bold())
                        }
                        .frame(width: 54, height: 54).background(.ultraThinMaterial, in: Circle())
                    }
                    .opacity(scanner.shared ? 0 : 1)
                    .disabled(scanner.shared || !scanner.aimed)
                }
                .foregroundStyle(.white)
                Text("Точек: \(scanner.points.count) · длина \(fmt((scanner.length * 100).rounded() / 100)) м")
                    .font(.caption.bold()).foregroundStyle(.white.opacity(0.85))
            }
            .padding()
        }
        .onAppear { scanner.run() }
        .onDisappear { scanner.stop() }
    }

    private var hint: String {
        if let t = scanner.tracking { return t }
        if scanner.floorY == nil { return "Поводите камерой по полу или наведите крестик на пол и нажмите «Пол» — от него считается высота" }
        if scanner.points.isEmpty { return "Наведите крестик на начало трубы и нажмите +" }
        return "Ставьте точки на поворотах и в конце трубы. Видно только открытые трубы"
    }

    private var kinds: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PipeKind.all) { k in
                        Button { scanner.setKind(k) } label: {
                            Text(k.title).font(.caption.bold())
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(scanner.kind.id == k.id ? Color(k.color) : Color.black.opacity(0.45), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(scanner.kind.diameters, id: \.self) { d in
                    Button { scanner.diameter = d } label: {
                        Text("Ø\(d)").font(.caption.bold())
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(scanner.diameter == d ? Palette.signal : Color.black.opacity(0.45), in: Capsule())
                            .foregroundStyle(scanner.diameter == d ? Palette.ink : .white)
                    }
                }
                Spacer()
            }
        }
    }
}
