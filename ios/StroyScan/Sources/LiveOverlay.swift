import RoomPlan
import SceneKit
import SwiftUI
import UIKit
import simd

/// Линии поверх камеры во время скана: выпрямленные стены — белым, где доснять — жёлтым пунктиром
/// (чуть мерцает). Под каждой линией тёмная подложка — видно и на белой стене. Вдали линии толще,
/// чтобы дальний угол читался через всю комнату. Сетки пересобираются при обновлении скана и когда телефон сдвинулся.
final class LiveOverlay {
    let root = SCNNode()
    private let haloNode = SCNNode()
    private let solidNode = SCNNode()
    private let dashNode = SCNNode()
    private let thinNode = SCNNode()
    private let fillNode = SCNNode()
    private let solidMat = LiveOverlay.material(.white, 1)
    private let dashMat = LiveOverlay.material(UIColor(red: 0.96, green: 0.77, blue: 0.09, alpha: 1), 1)
    private let thinMat = LiveOverlay.material(.white, 0.65)
    private let fillMat: SCNMaterial = {
        let m = LiveOverlay.material(.white, 0.07)
        m.writesToDepthBuffer = false
        return m
    }()
    /// Тёмная подложка (#14202E), рисуется первой и ничего не закрывает
    private let haloMat: SCNMaterial = {
        let m = LiveOverlay.material(UIColor(red: 0.08, green: 0.13, blue: 0.18, alpha: 1), 0.55)
        m.readsFromDepthBuffer = false
        m.writesToDepthBuffer = false
        return m
    }()
    /// Последний скан с подгонкой и откуда смотрела камера, когда собирали сетки
    private var last: (CapturedRoom, Rectify.Result)?
    private var builtAt: SIMD3<Float>?

    /// Толщина линии, метры: не тоньше min, а дальше — k на каждый метр до камеры
    struct Pen {
        let min: Float
        let k: Float
        func width(_ distance: Float) -> Float { max(self.min, k * distance) }
    }
    static let wallPen = Pen(min: 0.010, k: 0.005)
    static let dashPen = Pen(min: 0.014, k: 0.0075)
    static let thinPen = Pen(min: 0.005, k: 0.0025)
    static let framePen = Pen(min: 0.0075, k: 0.00375)
    /// Подложка во столько раз шире линии
    static let halo: Float = 2.2
    /// Пересобрать, когда телефон сдвинулся на столько метров
    static let rebuildMove: Float = 0.3

    init() {
        fillNode.renderingOrder = -2
        haloNode.renderingOrder = -1
        dashNode.renderingOrder = 10
        for node in [fillNode, haloNode, thinNode, solidNode, dashNode] { root.addChildNode(node) }
        let pulse = SCNAction.sequence([.fadeOpacity(to: 0.75, duration: 0.6), .fadeOpacity(to: 1, duration: 0.6)])
        dashNode.runAction(.repeatForever(pulse))
    }

    static func material(_ color: UIColor, _ alpha: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.transparency = alpha
        m.isDoubleSided = true
        return m
    }

    func clear() {
        last = nil
        builtAt = nil
        for node in [fillNode, haloNode, thinNode, solidNode, dashNode] { node.geometry = nil }
    }

    /// Перерисовать по свежему скану и его подгонке. eye — где сейчас камера
    func update(_ room: CapturedRoom, _ rect: Rectify.Result, eye: SIMD3<Float>?) {
        last = (room, rect)
        build(eye)
    }

    /// Телефон заметно сдвинулся — пересобрать, чтобы толщина линий шла за расстоянием
    func follow(_ eye: SIMD3<Float>) {
        guard last != nil else { return }
        if let at = builtAt, simd_distance(at, eye) < LiveOverlay.rebuildMove { return }
        build(eye)
    }

    private func build(_ eye: SIMD3<Float>?) {
        guard let (room, rect) = last else { return }
        builtAt = eye
        let walls = rect.walls
        guard !walls.isEmpty else {
            for node in [fillNode, haloNode, thinNode, solidNode, dashNode] { node.geometry = nil }
            return
        }
        var s = Sketch(eye: eye)
        let floorY = LiveOverlay.median(walls.map(\.bottom))
        let topY = floorY + LiveOverlay.median(walls.map(\.height))
        let p3 = { (p: SIMD2<Double>, y: Double) in SIMD3<Float>(Float(p.x), Float(y), Float(p.y)) }
        let wallPen = LiveOverlay.wallPen, dashPen = LiveOverlay.dashPen

        // копию стены («двоится») рисуем не стеной, а пунктиром её места — ниже, вместе с другими местами
        let copies = rect.copies
        for (i, w) in walls.enumerated() where copies[i] == nil {
            let y0 = w.bottom, y1 = w.bottom + w.height
            let len = w.length
            guard len > 0.02 else { continue }
            let dir = (w.b - w.a) / len
            let at = { (t: Double) in w.a + dir * t }
            // углы: сомкнутый — белая линия, открытый — жёлтый пунктир
            for (p, isOpen) in [(w.a, w.openA), (w.b, w.openB)] {
                if isOpen { s.dashed(p3(p, y0), p3(p, y1), dashPen) } else { s.line(p3(p, y0), p3(p, y1), wallPen) }
            }
            // низ и верх стены: что снято — белым, что доснять — пунктиром
            for run in LiveOverlay.runs(rect, i) {
                let p = at(run.t0), q = at(run.t1)
                for y in [y0, y1] {
                    if run.seen { s.line(p3(p, y), p3(q, y), wallPen) } else { s.dashed(p3(p, y), p3(q, y), dashPen) }
                }
            }
            // лёгкая заливка стены, чуть меньше её краёв
            if len > 0.1 && w.height > 0.1 {
                let p = at(0.02), q = at(len - 0.02)
                s.fill.quad(p3(p, y0 + 0.02), p3(q, y0 + 0.02), p3(q, y1 - 0.02), p3(p, y1 - 0.02))
            }
        }

        // несомкнутые углы, пропущенные стены, копии: пунктир по полу и по потолку, на изломах — вертикальный
        for g in rect.gaps where g.kind != .hole {
            for (p, q) in zip(g.path, g.path.dropFirst()) {
                s.dashed(p3(p, floorY), p3(q, floorY), dashPen)
                s.dashed(p3(p, topY), p3(q, topY), dashPen)
            }
            let corners = g.kind == .double ? g.path : Array(g.path.dropFirst().dropLast())
            for p in corners { s.dashed(p3(p, floorY), p3(p, topY), dashPen) }
        }

        // двери, окна, проёмы — рамкой прямо на выпрямленной стене
        var surfaces: [CapturedRoom.Surface] = []
        surfaces += room.doors
        surfaces += room.windows
        surfaces += room.openings
        for o in surfaces {
            guard let i = RoomResult.wallIndex(for: o, in: room.walls, rect: rect), i < walls.count else { continue }
            let w = walls[i]
            let len = w.length
            guard len > 0.05 else { continue }
            let dir = (w.b - w.a) / len
            let c = SIMD2(Double(o.transform.columns.3.x), Double(o.transform.columns.3.z))
            let t = simd_dot(c - w.a, dir)
            let half = Double(o.dimensions.x) / 2
            let p = w.a + dir * (t - half), q = w.a + dir * (t + half)
            let cy = Double(o.transform.columns.3.y), hh = Double(o.dimensions.y) / 2
            let corners = [p3(p, cy - hh), p3(q, cy - hh), p3(q, cy + hh), p3(p, cy + hh)]
            for k in 0..<4 {
                let a = corners[k], b = corners[(k + 1) % 4]
                if o.confidence == .low { s.dashed(a, b, dashPen) } else { s.line(a, b, LiveOverlay.framePen, thin: true) }
            }
        }

        // мебель — коробки по рёбрам
        for o in room.objects {
            let d = o.dimensions / 2
            var c: [SIMD3<Float>] = []
            for sx in [-1, 1] as [Float] {
                for sy in [-1, 1] as [Float] {
                    for sz in [-1, 1] as [Float] {
                        let v = o.transform * SIMD4<Float>(sx * d.x, sy * d.y, sz * d.z, 1)
                        c.append(SIMD3(v.x, v.y, v.z))
                    }
                }
            }
            // вершины: индекс = 4*sx + 2*sy + sz (0 — минус, 1 — плюс)
            let edges = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
            for (a, b) in edges {
                if o.confidence == .low { s.dashed(c[a], c[b], LiveOverlay.framePen) } else { s.line(c[a], c[b], LiveOverlay.thinPen, thin: true) }
            }
        }

        haloNode.geometry = s.halo.geometry(haloMat)
        solidNode.geometry = s.solid.geometry(solidMat)
        dashNode.geometry = s.dash.geometry(dashMat)
        thinNode.geometry = s.thin.geometry(thinMat)
        fillNode.geometry = s.fill.geometry(fillMat)
    }

    /// Участок стены от t0 до t1 (метры от начала): снят или его надо доснять
    struct Run {
        var t0: Double
        var t1: Double
        var seen: Bool
    }

    /// Делит стену i на участки. Неуверенная или дорисованная стена — вся пунктиром; у остальных пунктиром
    /// неуверенные куски и неснятые промежутки. Продление до угла, дверь в разрыве, щель до 25 см — как снятые
    static func runs(_ rect: Rectify.Result, _ i: Int) -> [Run] {
        guard i >= 0, i < rect.walls.count else { return [] }
        let w = rect.walls[i]
        let len = w.length
        guard len > 0 else { return [] }
        if w.made || w.conf == 0 { return [Run(t0: 0, t1: len, seen: false)] }
        let bad = (rect.unsure(i) + rect.holes(i)).sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var out: [Run] = []
        var t = 0.0
        for (a0, b) in bad {
            let a = max(a0, t)
            guard b > a else { continue }
            if a - t > 0.005 { out.append(Run(t0: t, t1: a, seen: true)) }
            if let lastRun = out.last, !lastRun.seen, abs(lastRun.t1 - a) < 1e-9 {
                out[out.count - 1].t1 = b
            } else {
                out.append(Run(t0: a, t1: b, seen: false))
            }
            t = b
        }
        if len - t > 0.005 { out.append(Run(t0: t, t1: len, seen: true)) }
        return out
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// Все сетки одного кадра: каждая линия ложится вместе со своей тёмной подложкой,
/// толщина — по расстоянию до камеры
private struct Sketch {
    var solid = LineMesh()
    var dash = LineMesh()
    var thin = LineMesh()
    var halo = LineMesh()
    var fill = LineMesh()
    let eye: SIMD3<Float>?

    init(eye: SIMD3<Float>?) { self.eye = eye }

    private func width(_ pen: LiveOverlay.Pen, _ p: SIMD3<Float>) -> Float {
        pen.width(eye.map { simd_distance($0, p) } ?? 2)
    }

    /// Сплошная линия кусками по 0,5 м: у каждого куска своя толщина
    mutating func line(_ p: SIMD3<Float>, _ q: SIMD3<Float>, _ pen: LiveOverlay.Pen, thin isThin: Bool = false) {
        let len = simd_distance(p, q)
        guard len > 0.001, len.isFinite, len < 50 else { return }
        let dir = (q - p) / len
        let n = max(1, Int((len / 0.5).rounded(.up)))
        for k in 0..<n {
            let a = p + (q - p) * (Float(k) / Float(n)), b = p + (q - p) * (Float(k + 1) / Float(n))
            let w = width(pen, (a + b) / 2)
            if isThin { thin.line(a, b, w) } else { solid.line(a, b, w) }
            // подложка выступает только на самых концах линии
            let pad = w * (LiveOverlay.halo - 1) / 2
            halo.line(k == 0 ? a - dir * pad : a, k == n - 1 ? b + dir * pad : b, w * LiveOverlay.halo)
        }
    }

    mutating func dashed(_ p: SIMD3<Float>, _ q: SIMD3<Float>, _ pen: LiveOverlay.Pen, dash: Float = 0.12, gap: Float = 0.08) {
        let len = simd_distance(p, q)
        guard len > 0.001, len.isFinite, len < 50 else { return }
        let dir = (q - p) / len
        var s: Float = 0
        while s < len {
            let a = p + dir * s, b = p + dir * min(s + dash, len)
            let w = width(pen, (a + b) / 2)
            self.dash.line(a, b, w)
            let pad = w * (LiveOverlay.halo - 1) / 2
            halo.line(a - dir * pad, b + dir * pad, w * LiveOverlay.halo)
            s += dash + gap
        }
    }
}

/// Сетка из толстых линий (четырёхгранные «палочки») и четырёхугольников
struct LineMesh {
    private(set) var vertices: [SCNVector3] = []
    private(set) var indices: [UInt32] = []
    /// Предел, чтобы странный скан не повесил телефон
    static let maxVertices = 120_000

    mutating func line(_ p: SIMD3<Float>, _ q: SIMD3<Float>, _ width: Float) {
        let d = q - p
        let len = simd_length(d)
        guard len > 0.001, len.isFinite, vertices.count < LineMesh.maxVertices else { return }
        let dir = d / len
        var side = simd_cross(dir, SIMD3<Float>(0, 1, 0))
        if simd_length(side) < 0.1 { side = simd_cross(dir, SIMD3<Float>(1, 0, 0)) }
        let e1 = simd_normalize(side) * (width / 2)
        let e2 = simd_normalize(simd_cross(dir, e1)) * (width / 2)
        let base = UInt32(vertices.count)
        for c in [p, q] {
            for o in [e1 + e2, e1 - e2, -e1 - e2, -e1 + e2] {
                let v = c + o
                vertices.append(SCNVector3(v.x, v.y, v.z))
            }
        }
        for k in 0..<4 {
            let k1 = (k + 1) % 4
            let a = base + UInt32(k), b = base + UInt32(k1), c = base + 4 + UInt32(k1), e = base + 4 + UInt32(k)
            indices += [a, b, c, a, c, e]
        }
    }

    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
        guard vertices.count < LineMesh.maxVertices else { return }
        let base = UInt32(vertices.count)
        for v in [a, b, c, d] { vertices.append(SCNVector3(v.x, v.y, v.z)) }
        indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    }

    func geometry(_ material: SCNMaterial) -> SCNGeometry? {
        guard !indices.isEmpty else { return nil }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        g.materials = [material]
        return g
    }
}

/// Мини-план во время скана (вид сверху, по сетке комнаты)
struct LivePlan {
    var solid: [SIMD4<Double>] = []
    var dashed: [SIMD4<Double>] = []
    var angle = 0.0
    var isEmpty: Bool { solid.isEmpty && dashed.isEmpty }

    init() {}

    /// Те же правила, что в камере: снятое — белым, доснять — пунктиром (LiveOverlay.runs и места из подгонки)
    init(_ rect: Rectify.Result) {
        angle = rect.angle
        func seg(_ p: SIMD2<Double>, _ q: SIMD2<Double>) -> SIMD4<Double> {
            let a = Rectify.rot(p, -rect.angle), b = Rectify.rot(q, -rect.angle)
            return SIMD4(a.x, a.y, b.x, b.y)
        }
        let copies = rect.copies
        for (i, w) in rect.walls.enumerated() where copies[i] == nil {
            let len = w.length
            guard len > 0 else { continue }
            let dir = (w.b - w.a) / len
            for run in LiveOverlay.runs(rect, i) {
                let s = seg(w.a + dir * run.t0, w.a + dir * run.t1)
                if run.seen { solid.append(s) } else { dashed.append(s) }
            }
        }
        for g in rect.gaps where g.kind != .hole {
            for (p, q) in zip(g.path, g.path.dropFirst()) { dashed.append(seg(p, q)) }
        }
    }

    /// Точка мира (x, z) → на мини-план
    func local(_ p: SIMD2<Double>) -> SIMD2<Double> { Rectify.rot(p, -angle) }
}

/// Мини-план: белое — снято, жёлтый пунктир — доснять, жёлтая точка — вы
struct MiniPlanView: View {
    let plan: LivePlan
    /// x, z и куда смотрит телефон (угол по полу)
    let me: SIMD3<Double>?

    var body: some View {
        Canvas { ctx, size in
            var pts = (plan.solid + plan.dashed).flatMap { [SIMD2($0.x, $0.y), SIMD2($0.z, $0.w)] }
            var mePos: SIMD2<Double>?
            var meDir = SIMD2<Double>(1, 0)
            if let me {
                let p = plan.local(SIMD2(me.x, me.y))
                mePos = p
                meDir = plan.local(SIMD2(cos(me.z), sin(me.z)))
                pts.append(p)
            }
            guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
                  let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return }
            let center = SIMD2((minX + maxX) / 2, (minY + maxY) / 2)
            // не меньше 3 × 3 м, чтобы в начале скана план не был огромным
            let half = SIMD2(max((maxX - minX) / 2, 1.5), max((maxY - minY) / 2, 1.5))
            let pad: CGFloat = 12
            let k = min((size.width - 2 * pad) / CGFloat(2 * half.x), (size.height - 2 * pad) / CGFloat(2 * half.y))
            func pt(_ v: SIMD2<Double>) -> CGPoint {
                CGPoint(x: size.width / 2 + CGFloat(v.x - center.x) * k, y: size.height / 2 + CGFloat(v.y - center.y) * k)
            }
            func path(_ segs: [SIMD4<Double>]) -> Path {
                var p = Path()
                for s in segs {
                    p.move(to: pt(SIMD2(s.x, s.y)))
                    p.addLine(to: pt(SIMD2(s.z, s.w)))
                }
                return p
            }
            ctx.stroke(path(plan.solid), with: .color(.white), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            ctx.stroke(path(plan.dashed), with: .color(Palette.signal), style: StrokeStyle(lineWidth: 2.5, lineCap: .butt, dash: [4, 3]))
            if let mePos {
                let c = pt(mePos)
                let d = simd_length(meDir) > 0 ? meDir / simd_length(meDir) : SIMD2(1, 0)
                var cone = Path()
                cone.move(to: c)
                for a in [-0.45, 0.45] {
                    let v = Rectify.rot(d, a)
                    cone.addLine(to: CGPoint(x: c.x + CGFloat(v.x) * 22, y: c.y + CGFloat(v.y) * 22))
                }
                cone.closeSubpath()
                ctx.fill(cone, with: .color(Palette.signal.opacity(0.35)))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(Palette.signal))
            }
        }
        .frame(width: 132, height: 132)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel("План комнаты: жёлтый пунктир — где доснять")
    }
}
