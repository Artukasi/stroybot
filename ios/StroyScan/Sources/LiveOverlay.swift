import RoomPlan
import SceneKit
import SwiftUI
import UIKit
import simd

/// Линии поверх камеры во время скана: выпрямленные стены — белым, где доснять — жёлтым пунктиром
/// (он мигает). Всё собирается в четыре сетки и пересобирается при каждом обновлении скана.
final class LiveOverlay {
    let root = SCNNode()
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

    /// Толщина линий, метры
    static let wallWidth: Float = 0.012
    static let dashWidth: Float = 0.016
    static let thinWidth: Float = 0.006

    init() {
        fillNode.renderingOrder = -1
        dashNode.renderingOrder = 10
        for node in [fillNode, thinNode, solidNode, dashNode] { root.addChildNode(node) }
        let pulse = SCNAction.sequence([.fadeOpacity(to: 0.4, duration: 0.6), .fadeOpacity(to: 1, duration: 0.6)])
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
        for node in [fillNode, thinNode, solidNode, dashNode] { node.geometry = nil }
    }

    /// Перерисовать по свежему скану и его подгонке
    func update(_ room: CapturedRoom, _ rect: Rectify.Result) {
        let walls = rect.walls
        guard !walls.isEmpty else { clear(); return }
        var solid = LineMesh(), dash = LineMesh(), thin = LineMesh(), fill = LineMesh()
        let floorY = LiveOverlay.median(walls.map(\.bottom))
        let topY = floorY + LiveOverlay.median(walls.map(\.height))
        let p3 = { (p: SIMD2<Double>, y: Double) in SIMD3<Float>(Float(p.x), Float(y), Float(p.y)) }

        for w in walls {
            let y0 = w.bottom, y1 = w.bottom + w.height
            let len = w.length
            guard len > 0.02 else { continue }
            let dir = (w.b - w.a) / len
            let at = { (t: Double) in w.a + dir * t }
            // углы: сомкнутый — белая линия, открытый — жёлтый пунктир
            for (p, isOpen) in [(w.a, w.openA), (w.b, w.openB)] {
                if isOpen { dash.dashed(p3(p, y0), p3(p, y1), LiveOverlay.dashWidth) } else { solid.line(p3(p, y0), p3(p, y1), LiveOverlay.wallWidth) }
            }
            // низ и верх стены: что снято уверенно — белым, остальное пунктиром
            for run in LiveOverlay.runs(w) {
                let p = at(run.t0), q = at(run.t1)
                if run.bottom { solid.line(p3(p, y0), p3(q, y0), LiveOverlay.wallWidth) } else { dash.dashed(p3(p, y0), p3(q, y0), LiveOverlay.dashWidth) }
                if run.top { solid.line(p3(p, y1), p3(q, y1), LiveOverlay.wallWidth) } else { dash.dashed(p3(p, y1), p3(q, y1), LiveOverlay.dashWidth) }
            }
            // лёгкая заливка стены, чуть меньше её краёв
            if len > 0.1 && w.height > 0.1 {
                let p = at(0.02), q = at(len - 0.02)
                fill.quad(p3(p, y0 + 0.02), p3(q, y0 + 0.02), p3(q, y1 - 0.02), p3(p, y1 - 0.02))
            }
        }

        // несомкнутые углы и пропущенные стены: пунктир по полу и по потолку, в самом углу — вертикальный
        for g in rect.gaps where g.kind != .hole {
            for (p, q) in zip(g.path, g.path.dropFirst()) {
                dash.dashed(p3(p, floorY), p3(q, floorY), LiveOverlay.dashWidth)
                dash.dashed(p3(p, topY), p3(q, topY), LiveOverlay.dashWidth)
            }
            for p in g.path.dropFirst().dropLast() {
                dash.dashed(p3(p, floorY), p3(p, topY), LiveOverlay.dashWidth)
            }
        }

        // двери, окна, проёмы — рамкой прямо на выпрямленной стене
        var surfaces: [CapturedRoom.Surface] = []
        surfaces += room.doors
        surfaces += room.windows
        surfaces += room.openings
        for s in surfaces {
            guard let i = RoomResult.wallIndex(for: s, in: room.walls, rect: rect), i < walls.count else { continue }
            let w = walls[i]
            let len = w.length
            guard len > 0.05 else { continue }
            let dir = (w.b - w.a) / len
            let c = SIMD2(Double(s.transform.columns.3.x), Double(s.transform.columns.3.z))
            let t = simd_dot(c - w.a, dir)
            let half = Double(s.dimensions.x) / 2
            let p = w.a + dir * (t - half), q = w.a + dir * (t + half)
            let cy = Double(s.transform.columns.3.y), hh = Double(s.dimensions.y) / 2
            let corners = [p3(p, cy - hh), p3(q, cy - hh), p3(q, cy + hh), p3(p, cy + hh)]
            for k in 0..<4 {
                let a = corners[k], b = corners[(k + 1) % 4]
                if s.confidence == .low { dash.dashed(a, b, LiveOverlay.dashWidth) } else { thin.line(a, b, LiveOverlay.thinWidth * 1.5) }
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
                if o.confidence == .low { dash.dashed(c[a], c[b], LiveOverlay.thinWidth * 1.5) } else { thin.line(c[a], c[b], LiveOverlay.thinWidth) }
            }
        }

        solidNode.geometry = solid.geometry(solidMat)
        dashNode.geometry = dash.geometry(dashMat)
        thinNode.geometry = thin.geometry(thinMat)
        fillNode.geometry = fill.geometry(fillMat)
    }

    /// Участок стены от t0 до t1 (метры от начала): снят ли уверенно низ и верх
    struct Run {
        var t0: Double
        var t1: Double
        var bottom: Bool
        var top: Bool
    }

    /// Делит стену на участки по кускам скана. Продление до угла и щели меньше 25 см — как снятые.
    static func runs(_ w: Rectify.OutWall) -> [Run] {
        let len = w.length
        guard len > 0 else { return [] }
        let dir = (w.b - w.a) / len
        let spans: [(Double, Double, Rectify.OutPiece)] = w.pieces.map { p in
            let s = simd_dot(p.a - w.a, dir), e = simd_dot(p.b - w.a, dir)
            return (max(0, min(s, e)), min(len, max(s, e)), p)
        }
        guard let lo = spans.map({ $0.0 }).min(), let hi = spans.map({ $0.1 }).max(), hi > lo else {
            return [Run(t0: 0, t1: len, bottom: w.conf > 0, top: w.conf > 0)]
        }
        var cuts = Set([0, lo, hi, len])
        for s in spans { cuts.formUnion([s.0, s.1]) }
        let points = cuts.sorted()
        var out: [Run] = []
        for (t0, t1) in zip(points, points.dropFirst()) where t1 - t0 > 0.005 {
            let m = (t0 + t1) / 2
            var bottom = true, top = true
            if m > lo && m < hi {
                let cover = spans.filter { $0.0 <= m && m <= $0.1 }
                if cover.isEmpty {
                    // щель между кусками: длинная — не снята
                    let hole = t1 - t0 > Rectify.holeMin
                    bottom = !hole
                    top = !hole
                } else {
                    bottom = cover.contains { $0.2.conf > 0 && $0.2.bot }
                    top = cover.contains { $0.2.conf > 0 && $0.2.top }
                }
            } else if w.conf == 0 {
                bottom = false
                top = false
            }
            if var last = out.last, last.bottom == bottom, last.top == top, abs(last.t1 - t0) < 1e-9 {
                last.t1 = t1
                out[out.count - 1] = last
            } else {
                out.append(Run(t0: t0, t1: t1, bottom: bottom, top: top))
            }
        }
        return out
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
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

    mutating func dashed(_ p: SIMD3<Float>, _ q: SIMD3<Float>, _ width: Float, dash: Float = 0.10, gap: Float = 0.07) {
        let len = simd_distance(p, q)
        guard len > 0.001, len.isFinite, len < 50 else { return }
        let dir = (q - p) / len
        var s: Float = 0
        while s < len {
            line(p + dir * s, p + dir * min(s + dash, len), width)
            s += dash + gap
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

    init(_ rect: Rectify.Result) {
        angle = rect.angle
        func seg(_ p: SIMD2<Double>, _ q: SIMD2<Double>) -> SIMD4<Double> {
            let a = Rectify.rot(p, -rect.angle), b = Rectify.rot(q, -rect.angle)
            return SIMD4(a.x, a.y, b.x, b.y)
        }
        for w in rect.walls {
            if w.conf == 0 {
                dashed.append(seg(w.a, w.b))
                continue
            }
            solid.append(seg(w.a, w.b))
            for p in w.pieces where p.conf == 0 { dashed.append(seg(p.a, p.b)) }
        }
        for g in rect.gaps {
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
