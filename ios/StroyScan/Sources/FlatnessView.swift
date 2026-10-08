import ARKit
import SceneKit
import SwiftUI

/// Ровность пола, стены или потолка: лидар за секунду снимает тысячи точек, по ним строится идеальная плоскость,
/// и каждый квадрат 4×4 см красится по тому, насколько он выше или ниже неё. Точность — около ±3 мм,
/// поэтому это быстрая карта «где горбы и ямы», а не замена правилу 2 м перед финишной отделкой.
final class FlatnessChecker: NSObject, ObservableObject, ARSessionDelegate {
    struct Cell {
        let u: Double
        let v: Double
        let dev: Double
    }

    struct Result {
        let surface: String
        let cells: [Cell]
        let size: Double
        /// Выпуклость (+) и впадина (−), метры
        let bump: Double
        let dip: Double
        let area: Double
        let origin: SIMD3<Float>
        let e1: SIMD3<Float>
        let e2: SIMD3<Float>
        let n: SIMD3<Float>
        let fit: SIMD3<Double>   // w = a·u + b·v + c

        var range: Double { bump - dip }
        var bumpCell: Cell? { cells.max { $0.dev < $1.dev } }
        var dipCell: Cell? { cells.min { $0.dev < $1.dev } }

        /// Точка плоскости в мире: здесь рисуем квадратик
        func world(_ u: Double, _ v: Double) -> SIMD3<Float> {
            let w = fit.x * u + fit.y * v + fit.z
            return origin + e1 * Float(u) + e2 * Float(v) + n * Float(w)
        }
    }

    let view = ARSCNView(frame: .zero)
    let supported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    @Published var aimed = false
    @Published var surface = ""
    @Published var progress: Double?
    @Published var result: Result?
    @Published var image: UIImage?
    @Published var failure: String?
    @Published var tracking: String?

    static let frames = 12
    static let cell = 0.04
    private var timer: Timer?
    private var points: [SIMD3<Float>] = []
    private var collected = 0
    private var reference: (o: SIMD3<Float>, n: SIMD3<Float>)?
    private let haptic = UINotificationFeedbackGenerator()

    func run() {
        guard supported else { return }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.frameSemantics.insert(.sceneDepth)
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) { config.frameSemantics.insert(.smoothedSceneDepth) }
        view.session.delegate = self
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        UIApplication.shared.isIdleTimerDisabled = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10, repeats: true) { [weak self] _ in self?.aim() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        view.session.pause()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func centerHit() -> (o: SIMD3<Float>, n: SIMD3<Float>)? {
        let c = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard view.bounds.width > 0, let q = view.raycastQuery(from: c, allowing: .estimatedPlane, alignment: .any),
              let r = view.session.raycast(q).first else { return nil }
        let t = r.worldTransform
        let o = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        var n = simd_normalize(SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z))
        // нормаль — к телефону
        if let cam = view.session.currentFrame?.camera.transform.columns.3 {
            if simd_dot(n, SIMD3(cam.x, cam.y, cam.z) - o) < 0 { n = -n }
        }
        return (o, n)
    }

    private static func surfaceName(_ n: SIMD3<Float>) -> String {
        if n.y > 0.8 { return "Пол" }
        if n.y < -0.8 { return "Потолок" }
        return "Стена"
    }

    private func aim() {
        guard progress == nil, result == nil else { return }
        let h = centerHit()
        aimed = h != nil
        surface = h.map { Self.surfaceName($0.n) } ?? ""
    }

    /// «Проверить»: копим точки 12 кадров (около 0,2–0,4 с), телефон держат неподвижно
    func start() {
        guard let ref = centerHit() else { return }
        reference = ref
        points.removeAll(keepingCapacity: true)
        collected = 0
        failure = nil
        progress = 0
    }

    func reset() {
        result = nil
        image = nil
        progress = nil
        failure = nil
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard progress != nil, let ref = reference else { return }
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        grab(depth: depth, camera: frame.camera, ref: ref)
        collected += 1
        progress = Double(collected) / Double(Self.frames)
        if collected >= Self.frames {
            progress = 1
            let pts = points, surface = Self.surfaceName(ref.n)
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Self.analyze(pts, ref: ref, surface: surface)
                DispatchQueue.main.async { self.finish(r) }
            }
            reference = nil
        }
    }

    /// Пиксели карты глубины (середина кадра, уверенные) → точки мира у выбранной поверхности
    private func grab(depth: ARDepthData, camera: ARCamera, ref: (o: SIMD3<Float>, n: SIMD3<Float>)) {
        let map = depth.depthMap
        let conf = depth.confidenceMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        if let conf { CVPixelBufferLockBaseAddress(conf, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(map, .readOnly)
            if let conf { CVPixelBufferUnlockBaseAddress(conf, .readOnly) }
        }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        guard let base = CVPixelBufferGetBaseAddress(map) else { return }
        let row = CVPixelBufferGetBytesPerRow(map)
        let confBase = conf.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confRow = conf.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let res = camera.imageResolution
        let sx = Float(w) / Float(res.width), sy = Float(h) / Float(res.height)
        let k = camera.intrinsics
        let fx = k[0][0] * sx, fy = k[1][1] * sy, cx = k[2][0] * sx, cy = k[2][1] * sy
        let t = camera.transform
        for y in stride(from: h / 8, to: h * 7 / 8, by: 2) {
            let line = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
            for x in stride(from: w / 8, to: w * 7 / 8, by: 2) {
                if let confBase {
                    let c = confBase.advanced(by: y * confRow + x).assumingMemoryBound(to: UInt8.self).pointee
                    if c < UInt8(ARConfidenceLevel.high.rawValue) { continue }
                }
                let d = line[x]
                guard d > 0.15, d < 3 else { continue }
                let pc = SIMD4<Float>((Float(x) - cx) * d / fx, -(Float(y) - cy) * d / fy, -d, 1)
                let pw = t * pc
                let p = SIMD3(pw.x, pw.y, pw.z)
                if abs(simd_dot(p - ref.o, ref.n)) < 0.05 { points.append(p) }
            }
        }
    }

    /// Плоскость методом наименьших квадратов, выбросы (вещи у стены) отбрасываем, потом сетка 4×4 см
    static func analyze(_ pts: [SIMD3<Float>], ref: (o: SIMD3<Float>, n: SIMD3<Float>), surface: String) -> Result? {
        guard pts.count > 400 else { return nil }
        let n = ref.n
        let up: SIMD3<Float> = abs(n.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let e1 = simd_normalize(simd_cross(up, n))
        let e2 = simd_cross(n, e1)
        let uvw = pts.map { p -> SIMD3<Double> in
            let d = p - ref.o
            return SIMD3(Double(simd_dot(d, e1)), Double(simd_dot(d, e2)), Double(simd_dot(d, n)))
        }
        func fit(_ list: [SIMD3<Double>]) -> SIMD3<Double>? {
            var m = simd_double3x3(0)
            var b = SIMD3<Double>(0, 0, 0)
            for q in list {
                let a = SIMD3(q.x, q.y, 1)
                m += simd_double3x3(columns: (a * a.x, a * a.y, a * a.z))
                b += a * q.z
            }
            guard abs(m.determinant) > 1e-12 else { return nil }
            return m.inverse * b
        }
        guard var f = fit(uvw) else { return nil }
        let res = { (q: SIMD3<Double>) in q.z - (f.x * q.x + f.y * q.y + f.z) }
        let inliers = uvw.filter { abs(res($0)) < 0.025 }
        guard inliers.count > 300, let f2 = fit(inliers) else { return nil }
        f = f2
        var sum: [SIMD2<Int>: (Double, Int)] = [:]
        for q in inliers {
            let r = q.z - (f.x * q.x + f.y * q.y + f.z)
            let key = SIMD2(Int((q.x / cell).rounded(.down)), Int((q.y / cell).rounded(.down)))
            let s = sum[key] ?? (0, 0)
            sum[key] = (s.0 + r, s.1 + 1)
        }
        let cells = sum.compactMap { key, s -> Cell? in
            guard s.1 >= 6 else { return nil }
            return Cell(u: Double(key.x) * cell, v: Double(key.y) * cell, dev: s.0 / Double(s.1))
        }
        guard cells.count >= 20 else { return nil }
        let devs = cells.map(\.dev)
        return Result(surface: surface, cells: cells, size: cell, bump: max(0, devs.max() ?? 0), dip: min(0, devs.min() ?? 0),
                      area: Double(cells.count) * cell * cell, origin: ref.o, e1: e1, e2: e2, n: n, fit: f)
    }

    private func finish(_ r: Result?) {
        progress = nil
        guard let r else {
            failure = "Не хватило точек. Подойдите на 0,5–1,5 м, наведите на ровный открытый участок без вещей и держите телефон неподвижно."
            haptic.notificationOccurred(.warning)
            return
        }
        result = r
        image = render(r)
        haptic.notificationOccurred(.success)
    }

    /// Снимок камеры, поверх — цветные квадраты и метки самого высокого и самого низкого места
    private func render(_ r: Result) -> UIImage {
        let shot = view.snapshot()
        let scale = shot.size.width / max(view.bounds.width, 1)
        let project = { (p: SIMD3<Float>) -> CGPoint? in
            let v = self.view.projectPoint(SCNVector3(p.x, p.y, p.z))
            guard v.z > 0, v.z < 1 else { return nil }
            return CGPoint(x: CGFloat(v.x) * scale, y: CGFloat(v.y) * scale)
        }
        return UIGraphicsImageRenderer(size: shot.size).image { ctx in
            shot.draw(at: .zero)
            for c in r.cells {
                let s = r.size
                let corners = [(c.u, c.v), (c.u + s, c.v), (c.u + s, c.v + s), (c.u, c.v + s)].compactMap { project(r.world($0.0, $0.1)) }
                guard corners.count == 4 else { continue }
                let path = UIBezierPath()
                path.move(to: corners[0])
                corners.dropFirst().forEach { path.addLine(to: $0) }
                path.close()
                Self.color(c.dev).setFill()
                path.fill()
            }
            for (cell, sign) in [(r.bumpCell, 1.0), (r.dipCell, -1.0)] {
                guard let cell, abs(cell.dev) >= 0.002,
                      let p = project(r.world(cell.u + r.size / 2, cell.v + r.size / 2)) else { continue }
                let text = (sign > 0 ? "+" : "−") + "\(Int((abs(cell.dev) * 1000).rounded())) мм"
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 15 * scale, weight: .heavy),
                                                            .foregroundColor: UIColor.white]
                let size = (text as NSString).size(withAttributes: attrs)
                let box = CGRect(x: p.x - size.width / 2 - 8 * scale, y: p.y - size.height - 18 * scale,
                                 width: size.width + 16 * scale, height: size.height + 6 * scale)
                (sign > 0 ? UIColor.systemRed : UIColor.systemBlue).setFill()
                UIBezierPath(roundedRect: box, cornerRadius: box.height / 2).fill()
                (text as NSString).draw(at: CGPoint(x: box.minX + 8 * scale, y: box.minY + 3 * scale), withAttributes: attrs)
                UIColor.white.setFill()
                UIBezierPath(ovalIn: CGRect(x: p.x - 5 * scale, y: p.y - 5 * scale, width: 10 * scale, height: 10 * scale)).fill()
                ctx.cgContext.setStrokeColor(UIColor.black.withAlphaComponent(0.5).cgColor)
            }
        }
    }

    /// Ровно (±2 мм) — зелёный; выше — к жёлтому и красному; ниже — к голубому и синему (насыщеннее к 10 мм)
    static func color(_ dev: Double) -> UIColor {
        let mm = dev * 1000
        let t = CGFloat(min(abs(mm) / 10, 1))
        if abs(mm) <= 2 { return UIColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 0.45) }
        if mm > 0 { return UIColor(red: 1, green: 0.85 * (1 - t), blue: 0.1, alpha: 0.45 + 0.2 * t) }
        return UIColor(red: 0.1, green: 0.6 * (1 - t) + 0.25, blue: 1, alpha: 0.45 + 0.2 * t)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let text: String?
        switch camera.trackingState {
        case .normal: text = nil
        case .limited(.initializing): text = "Поводите телефоном — камера настраивается"
        case .limited(.excessiveMotion): text = "Ведите телефон медленнее"
        case .limited: text = "Мало деталей — включите свет"
        case .notAvailable: text = "Камера не видит комнату"
        }
        DispatchQueue.main.async { self.tracking = text }
    }
}

struct FlatnessScene: UIViewRepresentable {
    let checker: FlatnessChecker
    func makeUIView(context: Context) -> ARSCNView { checker.view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct FlatnessView: View {
    @StateObject private var checker = FlatnessChecker()
    @Environment(\.dismiss) private var dismiss
    @State private var photo: SnapPhoto?
    @State private var reveal = false

    var body: some View {
        ZStack {
            if checker.supported {
                FlatnessScene(checker: checker).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                Text("Проверка ровности работает на iPhone с лидаром (модели Pro).")
                    .foregroundStyle(.white).multilineTextAlignment(.center).padding()
            }
            if let img = checker.image {
                Color.black.ignoresSafeArea()
                Image(uiImage: img).resizable().scaledToFill().ignoresSafeArea()
                    .opacity(reveal ? 1 : 0)
                    .scaleEffect(reveal ? 1 : 1.04)
                    .onAppear { withAnimation(.easeOut(duration: 0.6)) { reveal = true } }
            } else if checker.supported {
                aimRing
            }
            VStack(spacing: 12) {
                HStack {
                    Button("Закрыть") { dismiss() }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    if !checker.surface.isEmpty, checker.result == nil {
                        Text(checker.surface).font(.subheadline.bold())
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                if let t = checker.tracking ?? checker.failure {
                    Text(t).font(.subheadline.bold()).foregroundStyle(.white).multilineTextAlignment(.center)
                        .padding(10).background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                }
                Spacer()
                if let r = checker.result { resultCard(r) } else if checker.supported { controls }
            }
            .padding()
        }
        .sheet(item: $photo) { SnapPhotoView(photo: $0) }
        .onAppear { checker.run() }
        .onDisappear { checker.stop() }
    }

    private var aimRing: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .stroke(checker.aimed ? Palette.signal : Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                .frame(width: 230, height: 230)
            if let p = checker.progress {
                Circle().trim(from: 0, to: p)
                    .stroke(Palette.signal, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 70, height: 70)
                    .animation(.linear(duration: 0.1), value: p)
            } else {
                Circle().fill(checker.aimed ? Palette.signal : Color.white.opacity(0.6)).frame(width: 8, height: 8)
            }
        }
        .allowsHitTesting(false)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Text(checker.progress != nil ? "Держите телефон неподвижно…" :
                 "Наведите рамку на пол или стену с расстояния 0,5–1,5 м и нажмите «Проверить»")
                .font(.subheadline.bold()).foregroundStyle(.white).multilineTextAlignment(.center)
                .padding(10).background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            Button { checker.start() } label: {
                Label("Проверить", systemImage: "square.grid.3x3.middle.filled")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Palette.signal, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(Palette.ink)
            }
            .buttonStyle(PressStyle())
            .disabled(!checker.aimed || checker.progress != nil)
        }
    }

    private func resultCard(_ r: FlatnessChecker.Result) -> some View {
        let range = Int((r.range * 1000).rounded())
        let verdict: (String, Color) = range <= 6
            ? ("Ровно: перепад в пределах точности лидара", .green)
            : range <= 12 ? ("Небольшие перепады — под плитку и ламинат проверьте правилом 2 м", .orange)
            : ("Заметные перепады — нужно выравнивание", .red)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(r.surface).font(.headline)
                Spacer()
                Text("проверено \(fmt((r.area * 100).rounded() / 100)) м²").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                number("Выпуклость", "+\(Int((r.bump * 1000).rounded()))", .red)
                number("Впадина", "−\(Int((abs(r.dip) * 1000).rounded()))", .blue)
                number("Перепад", "\(range)", verdict.1)
            }
            Label(verdict.0, systemImage: range <= 6 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.subheadline.bold()).foregroundStyle(verdict.1)
            legend
            Text("Точность лидара около ±3 мм. Для финишной отделки норма — 2–3 мм на 2 м, её проверяют правилом.")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    reveal = false
                    checker.reset()
                } label: {
                    Label("Ещё раз", systemImage: "arrow.counterclockwise")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
                }
                Button {
                    if let img = checker.image {
                        photo = SnapPhoto(image: SnapPhoto.compose(img, sizes: [
                            "\(r.surface): перепад \(range) мм",
                            "выпуклость +\(Int((r.bump * 1000).rounded())) мм",
                            "впадина −\(Int((abs(r.dip) * 1000).rounded())) мм",
                        ]))
                    }
                } label: {
                    Label("Фото", systemImage: "square.and.arrow.up")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Palette.signal, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Palette.ink)
                }
            }
            .buttonStyle(PressStyle())
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func number(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title2.bold()).monospacedDigit().foregroundStyle(color)
                Text("мм").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var legend: some View {
        HStack(spacing: 0) {
            ForEach([-10.0, -6, -3, 0, 3, 6, 10], id: \.self) { mm in
                Rectangle().fill(Color(FlatnessChecker.color(mm / 1000).withAlphaComponent(1)))
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .overlay(alignment: .bottom) {
            HStack {
                Text("ниже на 10 мм")
                Spacer()
                Text("ровно")
                Spacer()
                Text("выше на 10 мм")
            }
            .font(.caption2).foregroundStyle(.secondary)
            .offset(y: 16)
        }
        .padding(.bottom, 16)
    }
}
