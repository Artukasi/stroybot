import SceneKit
import SwiftUI
import simd

/// Электрика и сантехника комнаты: точки на стенах и потолке (розетки, выключатели, выводы воды и канализации)
/// и трубы. Координаты — как у плана скана (x, y в метрах), высота — от пола.
struct Engineering: Equatable {
    struct Point: Equatable, Identifiable {
        var id = UUID()
        var kind: String
        /// Стена скана (как в wallLines) и отступ от её начала; у точек на потолке — nil
        var wall: Int?
        var offset: Double = 0
        /// Где на плане и на какой высоте от пола
        var x: Double
        var y: Double
        var height: Double
    }

    struct Pipe: Equatable, Identifiable {
        var id = UUID()
        var kind: String
        /// Диаметр, мм
        var diameter: Int
        /// Точки трассы: x, y плана и высота от пола
        var points: [SIMD3<Double>]

        var length: Double {
            zip(points, points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
        }
    }

    var points: [Point] = []
    var pipes: [Pipe] = []

    var isEmpty: Bool { points.isEmpty && pipes.isEmpty }

    static let maxPoints = 120
    static let maxPipes = 40

    // MARK: JSON

    var json: [String: Any] {
        let r = { (v: Double) in (v * 1000).rounded() / 1000 }
        let pts: [[String: Any]] = points.map { p in
            var d: [String: Any] = ["kind": p.kind, "x": r(p.x), "y": r(p.y), "height": r(p.height), "offset": r(p.offset)]
            if let w = p.wall { d["wall"] = w }
            return d
        }
        let pipesJSON: [[String: Any]] = pipes.map { p in
            ["kind": p.kind, "diameter": p.diameter, "points": p.points.map { [r($0.x), r($0.y), r($0.z)] }]
        }
        return ["points": pts, "pipes": pipesJSON]
    }

    init() {}

    init(json: [String: Any]) {
        let num = { (v: Any?) -> Double? in (v as? NSNumber)?.doubleValue }
        points = (json["points"] as? [[String: Any]] ?? []).prefix(Engineering.maxPoints).compactMap { d in
            guard let kind = d["kind"] as? String, EngKind.find(kind) != nil,
                  let x = num(d["x"]), let y = num(d["y"]), let h = num(d["height"]) else { return nil }
            return Point(kind: kind, wall: (d["wall"] as? NSNumber)?.intValue, offset: num(d["offset"]) ?? 0, x: x, y: y, height: h)
        }
        pipes = (json["pipes"] as? [[String: Any]] ?? []).prefix(Engineering.maxPipes).compactMap { d in
            guard let kind = d["kind"] as? String, PipeKind.find(kind) != nil else { return nil }
            let pts = (d["points"] as? [[Any]] ?? []).compactMap { a -> SIMD3<Double>? in
                let v = a.compactMap(num)
                return v.count == 3 ? SIMD3(v[0], v[1], v[2]) : nil
            }
            guard pts.count >= 2 else { return nil }
            return Pipe(kind: kind, diameter: (d["diameter"] as? NSNumber)?.intValue ?? PipeKind.find(kind)?.diameter ?? 20, points: pts)
        }
    }

    // MARK: Подсчёты

    /// Кабель: от каждой точки вверх в штробу под потолком (15 см), по стене до крайней точки на ней,
    /// от стены до распаечной коробки — 1 м, на подключение — 30 см на точку. Свет на потолке — 1,5 м.
    func cableMeters(ceiling: Double, wallLines: [SIMD4<Double>]) -> Double {
        let top = max(ceiling - 0.15, 1.8)
        var total = 0.0
        var byWall: [Int: [Double]] = [:]
        for p in points {
            guard let k = EngKind.find(p.kind), k.group == .electric else { continue }
            if let w = p.wall {
                total += max(0, top - p.height) + 0.3
                byWall[w, default: []].append(p.offset)
            } else {
                total += 1.5 + 0.3
            }
        }
        for (_, offs) in byWall {
            total += (offs.max() ?? 0) - (offs.min() ?? 0) + 1.0
        }
        return total
    }

    /// Сводка для карточки, PDF и сметы: «Розетка — 4 шт», «Кабель ≈ 38 м», «Холодная вода Ø20 — 3,2 м»
    func summary(ceiling: Double, wallLines: [SIMD4<Double>]) -> [(group: EngKind.Group, title: String, value: String)] {
        var out: [(group: EngKind.Group, title: String, value: String)] = []
        for k in EngKind.all {
            let n = points.filter { $0.kind == k.id }.count
            if n > 0 { out.append((k.group, k.title, "\(n) шт")) }
        }
        if count(.electric) > 0 {
            let cable = cableMeters(ceiling: ceiling, wallLines: wallLines)
            out.append((.electric, "Кабель (примерно)", "\(Int(cable.rounded(.up))) м"))
        }
        for k in PipeKind.all {
            let ds = Set(pipes.filter { $0.kind == k.id }.map(\.diameter)).sorted()
            for d in ds {
                let m = pipes.filter { $0.kind == k.id && $0.diameter == d }.reduce(0) { $0 + $1.length } * 1.1
                out.append((.plumbing, "\(k.title) Ø\(d)", "\(fmt((m * 10).rounded(.up) / 10)) м"))
            }
        }
        return out
    }

    func count(_ group: EngKind.Group) -> Int {
        points.filter { EngKind.find($0.kind)?.group == group }.count
    }

    /// Длина труб по видам, метры (с запасом на подключение 10%)
    var pipeMeters: [(PipeKind, Double)] {
        PipeKind.all.compactMap { k in
            let m = pipes.filter { $0.kind == k.id }.reduce(0) { $0 + $1.length }
            return m > 0 ? (k, m * 1.1) : nil
        }
    }
}

/// Что можно поставить: электрика и сантехника
struct EngKind: Identifiable {
    enum Group { case electric, plumbing }
    enum Place { case wall, ceiling }

    let id: String
    let title: String
    let short: String
    let group: Group
    let place: Place
    /// Высота по умолчанию, м (как обычно ставят)
    let height: Double
    let icon: String
    let color: UIColor

    static let electricColor = UIColor(red: 0.96, green: 0.62, blue: 0.09, alpha: 1)
    static let coldColor = UIColor(red: 0.20, green: 0.50, blue: 0.95, alpha: 1)
    static let hotColor = UIColor(red: 0.90, green: 0.25, blue: 0.20, alpha: 1)
    static let sewerColor = UIColor(red: 0.45, green: 0.47, blue: 0.50, alpha: 1)
    static let heatColor = UIColor(red: 0.85, green: 0.45, blue: 0.15, alpha: 1)

    static let all: [EngKind] = [
        EngKind(id: "socket", title: "Розетка", short: "Р", group: .electric, place: .wall, height: 0.3,
                icon: "poweroutlet.type.f", color: electricColor),
        EngKind(id: "socket2", title: "Двойная розетка", short: "Р2", group: .electric, place: .wall, height: 0.3,
                icon: "poweroutlet.type.f.square", color: electricColor),
        EngKind(id: "socket_desk", title: "Розетка над столешницей", short: "Рс", group: .electric, place: .wall, height: 1.1,
                icon: "poweroutlet.type.f", color: electricColor),
        EngKind(id: "socket_power", title: "Силовая (плита, духовка)", short: "С", group: .electric, place: .wall, height: 0.15,
                icon: "bolt.fill", color: electricColor),
        EngKind(id: "switch", title: "Выключатель", short: "В", group: .electric, place: .wall, height: 0.9,
                icon: "lightswitch.on", color: electricColor),
        EngKind(id: "sconce", title: "Бра", short: "Б", group: .electric, place: .wall, height: 1.6,
                icon: "lamp.table", color: electricColor),
        EngKind(id: "ceiling_light", title: "Свет на потолке", short: "Л", group: .electric, place: .ceiling, height: 0,
                icon: "lightbulb", color: electricColor),
        EngKind(id: "lan", title: "ТВ / интернет", short: "ТВ", group: .electric, place: .wall, height: 0.3,
                icon: "network", color: electricColor),
        EngKind(id: "panel", title: "Щиток", short: "Щ", group: .electric, place: .wall, height: 1.7,
                icon: "square.grid.3x3.square", color: electricColor),
        EngKind(id: "cold", title: "Вывод холодной воды", short: "ХВ", group: .plumbing, place: .wall, height: 0.6,
                icon: "drop", color: coldColor),
        EngKind(id: "hot", title: "Вывод горячей воды", short: "ГВ", group: .plumbing, place: .wall, height: 0.6,
                icon: "drop.fill", color: hotColor),
        EngKind(id: "sewer50", title: "Канализация Ø50", short: "К50", group: .plumbing, place: .wall, height: 0.4,
                icon: "arrow.down.circle", color: sewerColor),
        EngKind(id: "sewer110", title: "Канализация Ø110 (унитаз)", short: "К110", group: .plumbing, place: .wall, height: 0.2,
                icon: "arrow.down.circle.fill", color: sewerColor),
        EngKind(id: "washer", title: "Под стиральную машину", short: "СМ", group: .plumbing, place: .wall, height: 0.6,
                icon: "washer", color: coldColor),
        EngKind(id: "towel", title: "Полотенцесушитель", short: "ПС", group: .plumbing, place: .wall, height: 1.0,
                icon: "heater.vertical", color: hotColor),
        EngKind(id: "radiator", title: "Радиатор отопления", short: "Рд", group: .plumbing, place: .wall, height: 0.15,
                icon: "heater.vertical.fill", color: heatColor),
    ]

    static func find(_ id: String) -> EngKind? { all.first { $0.id == id } }
    static func list(_ g: Group) -> [EngKind] { all.filter { $0.group == g } }
}

/// Трубы: холодная, горячая, канализация, отопление
struct PipeKind: Identifiable {
    let id: String
    let title: String
    let diameter: Int
    let diameters: [Int]
    let color: UIColor

    static let all: [PipeKind] = [
        PipeKind(id: "cold", title: "Холодная вода", diameter: 20, diameters: [16, 20, 25, 32], color: EngKind.coldColor),
        PipeKind(id: "hot", title: "Горячая вода", diameter: 20, diameters: [16, 20, 25, 32], color: EngKind.hotColor),
        PipeKind(id: "sewer", title: "Канализация", diameter: 50, diameters: [32, 40, 50, 110], color: EngKind.sewerColor),
        PipeKind(id: "heating", title: "Отопление", diameter: 20, diameters: [16, 20, 25, 32], color: EngKind.heatColor),
    ]

    static func find(_ id: String) -> PipeKind? { all.first { $0.id == id } }
}

// MARK: - 3D

enum Eng3D {
    private static func mat(_ c: UIColor, rough: CGFloat = 0.4, metal: CGFloat = 0, glow: UIColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c
        m.roughness.contents = rough
        m.metalness.contents = metal
        if let glow { m.emission.contents = glow }
        return m
    }

    private static func box(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, _ m: SCNMaterial, z: Float = 0, y: Float = 0, x: Float = 0,
                            r: CGFloat = 0.004) -> SCNNode {
        let g = SCNBox(width: w, height: h, length: d, chamferRadius: min(r, w / 2, h / 2, d / 2))
        g.firstMaterial = m
        let n = SCNNode(geometry: g)
        n.simdPosition = SIMD3(x, y, z)
        return n
    }

    /// Цилиндр вдоль локальной оси z (смотрит из стены в комнату)
    private static func stub(_ radius: CGFloat, _ length: CGFloat, _ m: SCNMaterial, z: Float, y: Float = 0, x: Float = 0) -> SCNNode {
        let g = SCNCylinder(radius: radius, height: length)
        g.firstMaterial = m
        let n = SCNNode(geometry: g)
        n.eulerAngles.x = .pi / 2
        n.simdPosition = SIMD3(x, y, z)
        return n
    }

    /// Точка на стене: локальная +z — в комнату, центр — точка на поверхности стены
    static func point(_ kind: EngKind) -> SCNNode {
        let n = SCNNode()
        let white = mat(UIColor(white: 0.96, alpha: 1), rough: 0.35)
        let dark = mat(UIColor(white: 0.12, alpha: 1), rough: 0.6)
        switch kind.id {
        case "socket", "socket_desk", "lan":
            n.addChildNode(box(0.082, 0.082, 0.012, white, z: 0.006))
            n.addChildNode(stub(0.024, 0.006, mat(UIColor(white: 0.9, alpha: 1)), z: 0.014))
            if kind.id == "lan" {
                n.addChildNode(box(0.016, 0.012, 0.004, dark, z: 0.018))
            } else {
                n.addChildNode(stub(0.0035, 0.004, dark, z: 0.018, x: -0.01))
                n.addChildNode(stub(0.0035, 0.004, dark, z: 0.018, x: 0.01))
            }
        case "socket2":
            n.addChildNode(box(0.156, 0.082, 0.012, white, z: 0.006))
            for dx: Float in [-0.037, 0.037] {
                n.addChildNode(stub(0.024, 0.006, mat(UIColor(white: 0.9, alpha: 1)), z: 0.014, x: dx))
                n.addChildNode(stub(0.0035, 0.004, dark, z: 0.018, x: dx - 0.01))
                n.addChildNode(stub(0.0035, 0.004, dark, z: 0.018, x: dx + 0.01))
            }
        case "socket_power":
            n.addChildNode(box(0.09, 0.09, 0.014, white, z: 0.007))
            n.addChildNode(stub(0.028, 0.01, mat(kind.color), z: 0.016))
        case "switch":
            n.addChildNode(box(0.082, 0.082, 0.012, white, z: 0.006))
            let key = box(0.05, 0.05, 0.008, mat(UIColor(white: 0.92, alpha: 1)), z: 0.015)
            key.eulerAngles.x = 0.08
            n.addChildNode(key)
        case "sconce":
            n.addChildNode(stub(0.035, 0.02, mat(UIColor(white: 0.25, alpha: 1), rough: 0.3, metal: 0.7), z: 0.01))
            let shade = SCNCone(topRadius: 0.05, bottomRadius: 0.09, height: 0.14)
            shade.firstMaterial = mat(UIColor(red: 1, green: 0.95, blue: 0.85, alpha: 1), glow: UIColor(red: 1, green: 0.85, blue: 0.6, alpha: 1))
            let s = SCNNode(geometry: shade)
            s.simdPosition = SIMD3(0, 0.03, 0.11)
            n.addChildNode(s)
        case "panel":
            n.addChildNode(box(0.3, 0.42, 0.04, mat(UIColor(white: 0.85, alpha: 1), rough: 0.3, metal: 0.2), z: 0.02))
            n.addChildNode(box(0.26, 0.04, 0.004, dark, z: 0.042, y: 0.12))
        case "cold", "hot", "washer":
            let c = kind.id == "hot" ? EngKind.hotColor : EngKind.coldColor
            n.addChildNode(stub(0.014, 0.06, mat(c, rough: 0.3), z: 0.03))
            n.addChildNode(stub(0.018, 0.016, mat(UIColor(white: 0.75, alpha: 1), rough: 0.2, metal: 0.9), z: 0.066))
            if kind.id == "washer" {
                n.addChildNode(stub(0.025, 0.05, mat(EngKind.sewerColor), z: 0.025, y: -0.2))
            }
        case "sewer50", "sewer110":
            let r: CGFloat = kind.id == "sewer110" ? 0.055 : 0.025
            n.addChildNode(stub(r, 0.08, mat(EngKind.sewerColor, rough: 0.5), z: 0.04))
            n.addChildNode(stub(r + 0.006, 0.02, mat(UIColor(white: 0.6, alpha: 1)), z: 0.08))
        case "towel":
            let chrome = mat(UIColor(white: 0.85, alpha: 1), rough: 0.12, metal: 1)
            for x: Float in [-0.22, 0.22] {
                let g = SCNCylinder(radius: 0.013, height: 0.7)
                g.firstMaterial = chrome
                let rail = SCNNode(geometry: g)
                rail.simdPosition = SIMD3(x, 0.15, 0.06)
                n.addChildNode(rail)
            }
            for y: Float in [-0.15, 0.0, 0.15, 0.3, 0.45] {
                let g = SCNCylinder(radius: 0.009, height: 0.44)
                g.firstMaterial = chrome
                let bar = SCNNode(geometry: g)
                bar.eulerAngles.z = .pi / 2
                bar.simdPosition = SIMD3(0, y, 0.06)
                n.addChildNode(bar)
            }
        case "radiator":
            let w = mat(UIColor(white: 0.97, alpha: 1), rough: 0.3)
            for i in 0..<10 {
                n.addChildNode(box(0.07, 0.55, 0.08, w, z: 0.07, y: 0.275, x: Float(i) * 0.08 - 0.36, r: 0.02))
            }
        default:
            n.addChildNode(box(0.08, 0.08, 0.012, mat(kind.color), z: 0.006))
        }
        return n
    }

    /// Свет на потолке (диск вниз)
    static func ceilingLight() -> SCNNode {
        let g = SCNCylinder(radius: 0.07, height: 0.02)
        g.firstMaterial = mat(UIColor(white: 1, alpha: 1), glow: UIColor(red: 1, green: 0.92, blue: 0.75, alpha: 1))
        let n = SCNNode(geometry: g)
        n.simdPosition = SIMD3(0, -0.01, 0)
        let holder = SCNNode()
        holder.addChildNode(n)
        return holder
    }

    /// Труба по трассе: прямые куски и колена
    static func pipe(_ p: Engineering.Pipe, inset: (SIMD3<Double>) -> SIMD3<Float>) -> SCNNode {
        let n = SCNNode()
        let color = PipeKind.find(p.kind)?.color ?? .gray
        let m = mat(color, rough: 0.35)
        let r = CGFloat(max(p.diameter, 12)) / 2000
        let pts = p.points.map(inset)
        for (a, b) in zip(pts, pts.dropFirst()) {
            let len = simd_distance(a, b)
            guard len > 0.001 else { continue }
            let g = SCNCylinder(radius: r, height: CGFloat(len))
            g.firstMaterial = m
            let seg = SCNNode(geometry: g)
            seg.simdPosition = (a + b) / 2
            seg.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: (b - a) / len)
            n.addChildNode(seg)
        }
        for q in pts {
            let s = SCNSphere(radius: r * 1.25)
            s.firstMaterial = m
            let j = SCNNode(geometry: s)
            j.simdPosition = q
            n.addChildNode(j)
        }
        return n
    }

    /// Кабель: тонкая оранжевая линия (только в режиме электрики)
    static func cable(_ pts: [SIMD3<Float>]) -> SCNNode {
        let n = SCNNode()
        let m = mat(EngKind.electricColor, rough: 0.6, glow: EngKind.electricColor.withAlphaComponent(0.4))
        for (a, b) in zip(pts, pts.dropFirst()) {
            let len = simd_distance(a, b)
            guard len > 0.001 else { continue }
            let g = SCNCylinder(radius: 0.004, height: CGFloat(len))
            g.firstMaterial = m
            let seg = SCNNode(geometry: g)
            seg.simdPosition = (a + b) / 2
            seg.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: (b - a) / len)
            n.addChildNode(seg)
        }
        return n
    }
}

// MARK: - На плане (2D)

/// Точки и трубы поверх плана комнаты; frame переводит метры плана в точки экрана
struct PlanEngineering: View {
    let eng: Engineering
    let points: [SIMD2<Double>]

    var body: some View {
        Canvas { ctx, size in
            guard let f = planFrame(points, in: CGRect(origin: .zero, size: size)) else { return }
            let map = { (x: Double, y: Double) in CGPoint(x: f.ox + CGFloat(x) * f.k, y: f.oy + CGFloat(y) * f.k) }
            for p in eng.pipes {
                guard let first = p.points.first else { continue }
                var path = Path()
                path.move(to: map(first.x, first.y))
                for q in p.points.dropFirst() { path.addLine(to: map(q.x, q.y)) }
                ctx.stroke(path, with: .color(Color(PipeKind.find(p.kind)?.color ?? .gray)),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            for p in eng.points {
                guard let k = EngKind.find(p.kind) else { continue }
                let c = map(p.x, p.y)
                let r: CGFloat = 7
                let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(circle, with: .color(Color(k.color)))
                ctx.stroke(circle, with: .color(.white), lineWidth: 1.2)
                ctx.draw(Text(k.short).font(.system(size: 6.5, weight: .heavy)).foregroundColor(.white), at: c)
            }
        }
        .allowsHitTesting(false)
    }
}

extension RoomResult {
    /// Точка на стене скана: где на плане
    func wallPoint(_ wall: Int, offset: Double) -> SIMD2<Double>? {
        guard wall >= 0, wall < wallLines.count else { return nil }
        let l = wallLines[wall]
        let a = SIMD2(l.x, l.y), b = SIMD2(l.z, l.w)
        let len = simd_distance(a, b)
        guard len > 0 else { return nil }
        return a + (b - a) / len * min(max(offset, 0), len)
    }

    /// Ближайшая стена к точке плана: номер и отступ от начала
    func nearestWall(_ p: SIMD2<Double>) -> (wall: Int, offset: Double, distance: Double)? {
        var best: (Int, Double, Double)?
        for (i, l) in wallLines.enumerated() {
            let a = SIMD2(l.x, l.y), b = SIMD2(l.z, l.w)
            let len = simd_distance(a, b)
            guard len > 0.05 else { continue }
            let u = (b - a) / len
            let s = min(max(simd_dot(p - a, u), 0), len)
            let d = simd_distance(p, a + u * s)
            if best == nil || d < best!.2 { best = (i, s, d) }
        }
        return best.map { (wall: $0.0, offset: $0.1, distance: $0.2) }
    }
}
