import SceneKit
import UIKit
import simd

// MARK: - Комната в метрах для 3D

/// Стена в сцене. Концы по полу, комната — слева по ходу от a к b (локальная +z смотрит внутрь).
struct WallGeo {
    /// Номер стены в скане (как в wallLines)
    let index: Int
    let a: SIMD2<Float>
    let b: SIMD2<Float>
    let length: Float
    /// Концы переставлены относительно wallLines: отступы проёмов считаем с другого конца
    let flipped: Bool

    var dir: SIMD2<Float> { length > 0 ? (b - a) / length : SIMD2(1, 0) }
    /// Нормаль внутрь комнаты
    var normal: SIMD2<Float> { SIMD2(-dir.y, dir.x) }
    var mid: SIMD2<Float> { (a + b) / 2 }
    func point(_ s: Float) -> SIMD2<Float> { a + dir * s }
}

/// Окно, дверь или проём на стене: середина от начала стены, размеры, высота низа
struct OpeningGeo {
    /// Номер в result.openings
    let index: Int
    let kind: String
    let center: Float
    let width: Float
    let height: Float
    let bottom: Float

    var left: Float { center - width / 2 }
    var right: Float { center + width / 2 }
    var top: Float { bottom + height }
}

/// План комнаты для сцены: контур пола, стены с внутренней стороной, проёмы по местам
struct Room3D {
    /// Контур пола против часовой стрелки (x, y плана)
    let polygon: [SIMD2<Float>]
    let walls: [WallGeo]
    /// Проёмы по стенам (тот же порядок, что у walls)
    let openings: [[OpeningGeo]]
    let height: Float
    let lo: SIMD2<Float>
    let hi: SIMD2<Float>
    /// Точка внутри комнаты, куда смотрит камера
    let centroid: SIMD2<Float>

    init(_ r: RoomResult) {
        var pts: [SIMD2<Float>] = []
        for p in r.plan {
            let q = SIMD2(Float(p.x), Float(p.y))
            if let last = pts.last, simd_distance(last, q) < 0.02 { continue }
            pts.append(q)
        }
        if pts.count > 1, let first = pts.first, let last = pts.last, simd_distance(first, last) < 0.02 { pts.removeLast() }
        if pts.count < 3 {
            let ends = r.wallLines.flatMap { [SIMD2($0.x, $0.y), SIMD2($0.z, $0.w)] }
            pts = RoomResult.convexHull(ends).map { SIMD2(Float($0.x), Float($0.y)) }
        }
        if Room3D.area(pts) < 0 { pts.reverse() }
        polygon = pts

        let h = Float(r.height)
        height = h >= 1.9 && h <= 5 ? h : 2.6

        var all = pts
        for l in r.wallLines {
            all.append(SIMD2(Float(l.x), Float(l.y)))
            all.append(SIMD2(Float(l.z), Float(l.w)))
        }
        if let first = all.first {
            lo = all.reduce(first) { pointwiseMin($0, $1) }
            hi = all.reduce(first) { pointwiseMax($0, $1) }
        } else {
            lo = SIMD2(0, 0)
            hi = SIMD2(3, 3)
        }

        var c = Room3D.centroid(pts)
        if !Room3D.contains(pts, c) {
            let box = (lo + hi) / 2
            c = Room3D.contains(pts, box) || pts.count < 3 ? box : (pts[0] + pts[1] + pts[2]) / 3
        }
        centroid = c

        // стены: внутренняя сторона — та, где пол
        var ws: [WallGeo] = []
        for (i, l) in r.wallLines.enumerated() {
            var a = SIMD2(Float(l.x), Float(l.y)), b = SIMD2(Float(l.z), Float(l.w))
            let len = simd_distance(a, b)
            guard len > 0.05 else { continue }
            let d = (b - a) / len, n = SIMD2(-d.y, d.x), m = (a + b) / 2
            let plus = Room3D.contains(pts, m + n * 0.25), minus = Room3D.contains(pts, m - n * 0.25)
            let flip = plus != minus ? minus : simd_dot(c - m, n) < 0
            if flip { swap(&a, &b) }
            ws.append(WallGeo(index: i, a: a, b: b, length: len, flipped: flip))
        }
        walls = ws

        // проёмы: место на стене, ширина и высота в пределах стены
        var ops = Array(repeating: [OpeningGeo](), count: ws.count)
        let top = height
        for (k, o) in r.openings.enumerated() {
            guard let wi = o.wall, let pos = ws.firstIndex(where: { $0.index == wi }) else { continue }
            let len = ws[pos].length
            let w = min(Float(o.width), len - 0.1)
            guard w > 0.2 else { continue }
            var s = Float(o.offset ?? Double(len / 2))
            if ws[pos].flipped { s = len - s }
            s = min(max(s, w / 2), len - w / 2)
            let window = o.kind == "window"
            var bottom = Float(o.bottom ?? (window ? 0.85 : 0))
            if !window && bottom < 0.12 { bottom = 0 }
            bottom = min(max(bottom, 0), top - 0.4)
            let oh = min(Float(o.height), top - 0.03 - bottom)
            guard oh > 0.3 else { continue }
            ops[pos].append(OpeningGeo(index: k, kind: o.kind, center: s, width: w, height: oh, bottom: bottom))
        }
        openings = ops.map { list in list.sorted { $0.center < $1.center } }
    }

    func inside(_ q: SIMD2<Float>) -> Bool { Room3D.contains(polygon, q) }

    /// Площадь со знаком: > 0 — обход против часовой стрелки
    static func area(_ p: [SIMD2<Float>]) -> Float {
        guard p.count > 2 else { return 0 }
        var s: Float = 0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    static func centroid(_ p: [SIMD2<Float>]) -> SIMD2<Float> {
        guard !p.isEmpty else { return SIMD2(1.5, 1.5) }
        var a: Float = 0
        var c = SIMD2<Float>(0, 0)
        for i in p.indices {
            let q = p[i], r = p[(i + 1) % p.count]
            let k = q.x * r.y - r.x * q.y
            a += k
            c += (q + r) * k
        }
        if abs(a) < 1e-6 { return p.reduce(SIMD2<Float>(0, 0), +) / Float(p.count) }
        return c / (3 * a)
    }

    /// Точка внутри многоугольника (луч вправо)
    static func contains(_ p: [SIMD2<Float>], _ q: SIMD2<Float>) -> Bool {
        guard p.count > 2 else { return false }
        var inside = false
        var j = p.count - 1
        for i in p.indices {
            let a = p[i], b = p[j]
            if (a.y > q.y) != (b.y > q.y) {
                let x = (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x
                if q.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Разбивка многоугольника на треугольники (отсечение «ушей»), обход против часовой
    static func triangulate(_ p: [SIMD2<Float>]) -> [(Int, Int, Int)] {
        var idx = Array(p.indices)
        var tris: [(Int, Int, Int)] = []
        func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { u.x * v.y - u.y * v.x }
        func inTri(_ q: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
            cross(b - a, q - a) >= 0 && cross(c - b, q - b) >= 0 && cross(a - c, q - c) >= 0
        }
        var guardCount = 0
        while idx.count > 3 && guardCount < 5000 {
            guardCount += 1
            var clipped = false
            for i in idx.indices {
                let i0 = idx[(i + idx.count - 1) % idx.count], i1 = idx[i], i2 = idx[(i + 1) % idx.count]
                let a = p[i0], b = p[i1], c = p[i2]
                if cross(b - a, c - b) <= 1e-7 { continue }
                var ear = true
                for j in idx where j != i0 && j != i1 && j != i2 {
                    if inTri(p[j], a, b, c) { ear = false; break }
                }
                if ear {
                    tris.append((i0, i1, i2))
                    idx.remove(at: i)
                    clipped = true
                    break
                }
            }
            if !clipped { break }
        }
        if idx.count == 3 {
            tris.append((idx[0], idx[1], idx[2]))
        } else if idx.count > 3 {
            // контур с самопересечением — веером, лучше чем дыра в полу
            for k in 1..<(idx.count - 1) { tris.append((idx[0], idx[k], idx[k + 1])) }
        }
        return tris
    }

    /// Расстояние от точки до стены
    static func distance(_ q: SIMD2<Float>, _ w: WallGeo) -> Float {
        let t = max(0, min(w.length, simd_dot(q - w.a, w.dir)))
        return simd_distance(q, w.point(t))
    }
}

// MARK: - Сетки

enum Mesh {
    static func make(_ v: [SIMD3<Float>], _ n: [SIMD3<Float>], _ uv: [SIMD2<Float>], _ idx: [UInt32],
                     _ m: SCNMaterial) -> SCNGeometry {
        let sources = [
            SCNGeometrySource(vertices: v.map { SCNVector3($0.x, $0.y, $0.z) }),
            SCNGeometrySource(normals: n.map { SCNVector3($0.x, $0.y, $0.z) }),
            SCNGeometrySource(textureCoordinates: uv.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }),
        ]
        let g = SCNGeometry(sources: sources, elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        g.materials = [m]
        return g
    }

    /// Прямоугольник в плоскости z = 0, смотрит в +z. Текстура в метрах: рисунок одного размера на всех стенах.
    static func quad(_ x0: Float, _ x1: Float, _ y0: Float, _ y1: Float, top: Float, _ m: SCNMaterial) -> SCNGeometry {
        let v = [SIMD3(x0, y0, 0), SIMD3(x1, y0, 0), SIMD3(x1, y1, 0), SIMD3(x0, y1, 0)]
        let n = Array(repeating: SIMD3<Float>(0, 0, 1), count: 4)
        let uv = v.map { SIMD2($0.x, top - $0.y) }
        return make(v, n, uv, [0, 1, 2, 0, 2, 3], m)
    }

    /// Плоский многоугольник на высоте y: пол (нормаль вверх) или потолок (вниз)
    static func polygon(_ p: [SIMD2<Float>], y: Float, up: Bool, _ m: SCNMaterial) -> SCNGeometry {
        let v = p.map { SIMD3($0.x, y, $0.y) }
        let n = Array(repeating: SIMD3<Float>(0, up ? 1 : -1, 0), count: p.count)
        var idx: [UInt32] = []
        for t in Room3D.triangulate(p) {
            let e = simd_cross(v[t.1] - v[t.0], v[t.2] - v[t.0])
            if (e.y > 0) == up {
                idx += [UInt32(t.0), UInt32(t.1), UInt32(t.2)]
            } else {
                idx += [UInt32(t.0), UInt32(t.2), UInt32(t.1)]
            }
        }
        return make(v, n, p, idx, m)
    }

    /// Ткань в складках: волна по ширине. Начало — левый нижний угол.
    static func drape(width: Float, height: Float, fold: Float, depth: Float, _ m: SCNMaterial) -> SCNGeometry {
        let count = max(8, Int(width / 0.03))
        let k = 2 * Float.pi / max(fold, 0.02)
        var v: [SIMD3<Float>] = [], nr: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], idx: [UInt32] = []
        for i in 0...count {
            let x = width * Float(i) / Float(count)
            let z = depth / 2 * sin(k * x)
            let slope = depth / 2 * k * cos(k * x)
            let normal = simd_normalize(SIMD3<Float>(-slope, 0, 1))
            for y in [Float(0), height] {
                v.append(SIMD3(x, y, z))
                nr.append(normal)
                uv.append(SIMD2(x, height - y))
            }
            if i < count {
                let b = UInt32(i * 2)
                idx += [b, b + 2, b + 3, b, b + 3, b + 1]
            }
        }
        return make(v, nr, uv, idx, m)
    }
}

/// След предмета на полу: центр, оси, половины размеров
private struct Foot {
    let c: SIMD2<Float>
    let ux: SIMD2<Float>
    let uz: SIMD2<Float>
    let hw: Float
    let hd: Float

    init(_ c: SIMD2<Float>, angle: Float, w: Float, d: Float) {
        self.c = c
        ux = SIMD2(cos(angle), sin(angle))
        uz = SIMD2(-sin(angle), cos(angle))
        hw = w / 2
        hd = d / 2
    }

    var corners: [SIMD2<Float>] {
        [c + ux * hw + uz * hd, c - ux * hw + uz * hd, c - ux * hw - uz * hd, c + ux * hw - uz * hd]
    }

    /// Пересекаются ли два повёрнутых прямоугольника (разделяющие оси)
    func overlaps(_ o: Foot) -> Bool {
        let mine = corners, theirs = o.corners
        for axis in [ux, uz, o.ux, o.uz] {
            let p1 = mine.map { simd_dot($0, axis) }, p2 = theirs.map { simd_dot($0, axis) }
            if (p1.max() ?? 0) < (p2.min() ?? 0) || (p2.max() ?? 0) < (p1.min() ?? 0) { return false }
        }
        return true
    }
}

// MARK: - Редактор ремонта

/// 3D-ремонт по скану: строит комнату точно по размерам, выделяет то, что нажали, и меняет только это.
final class RenoEditor: NSObject, ObservableObject {
    enum Pick: Equatable {
        case wall(Int), floor, ceiling, window(Int), door(Int), object(Int), added(Int), custom(Int)

        init?(name: String) {
            let parts = name.split(separator: ":")
            let n = parts.count > 1 ? Int(parts[1]) : nil
            switch String(parts.first ?? "") {
            case "wall": guard let n else { return nil }; self = .wall(n)
            case "win": guard let n else { return nil }; self = .window(n)
            case "door": guard let n else { return nil }; self = .door(n)
            case "obj": guard let n else { return nil }; self = .object(n)
            case "add": guard let n else { return nil }; self = .added(n)
            case "cust": guard let n else { return nil }; self = .custom(n)
            case "floor": self = .floor
            case "ceiling", "lamps": self = .ceiling
            default: return nil
            }
        }
    }

    /// Что выбрал человек (экран показывает это сразу)
    @Published private(set) var look: Look
    @Published private(set) var pick: Pick?
    /// Камера в комнате на уровне глаз (иначе — сверху)
    @Published private(set) var inside = false
    @Published private(set) var ready = false
    /// Электрика и сантехника (см. EngineeringEditor.swift)
    @Published var eng: Engineering
    @Published var engMode: EngMode = .off
    /// Комната как есть после скана: голые серые стены, бетонный пол, мебель — простые коробки.
    /// Ремонт (look) при этом не меняется — вернулись в «Ремонт», и он на месте
    @Published private(set) var bare = false
    /// Яркость картинки: −1 темнее … +1 светлее (экспозиция камеры)
    @Published private(set) var brightness: Float = 0
    /// Мебель убрана с модели (чтобы видеть стены и вести провода и трубы)
    @Published private(set) var furnitureHidden = false
    /// Вид сверху строго вниз — как план
    @Published private(set) var topView = false
    /// Откуда смотрим на комнату снаружи: угол вокруг середины комнаты
    private var orbitYaw: Float = atan2(0.5, 0.8)
    /// Что ставим по нажатию: вид точки или вид трубы
    @Published var engTool: EngTool?
    @Published var engSelected: UUID?
    /// Труба, которую сейчас проводят нажатиями
    @Published var route: [SIMD3<Double>] = []
    /// Труба из скана камерой, которую надо привязать к стене
    @Published var pendingPipe: Engineering.Pipe?
    @Published var engHint: String?
    let engHolder = SCNNode()
    let defectHolder = SCNNode()
    /// Плитка (Tiles.swift): где лежит, плитки из библиотеки, какую кладём и какая зона выбрана
    @Published var tiling: Tiling
    var tileItems: [UUID: TileItem] = [:]
    @Published var tileTool: UUID?
    @Published var tileSelected: UUID?
    let tileHolder = SCNNode()
    var tileMats: [String: SCNMaterial] = [:]
    /// Своя мебель по ссылке или фото (Pieces.swift); она лежит в tiling.pieces
    let customHolder = SCNNode()
    var customNodes: [SCNNode] = []
    private var dragCustom: Int?
    var engWallOf: [UUID: Int] = [:]

    let result: RoomResult
    let room: Room3D
    let view: SCNView

    /// Что сейчас построено (look может уйти вперёд, пока в фоне рисуются текстуры)
    private var shown: Look
    private let scene = SCNScene()
    private let floorHolder = SCNNode()
    private let ceilingHolder = SCNNode()
    private let lampHolder = SCNNode()
    private let wallHolder = SCNNode()
    private let itemHolder = SCNNode()
    private let addedHolder = SCNNode()
    private let lightHolder = SCNNode()
    private(set) var wallNodes: [SCNNode] = []
    /// Вид за окнами и коридоры за проёмами — только для вида из комнаты
    private var outsideNodes: [[SCNNode]] = []
    private var itemNodes: [Int: SCNNode] = [:]
    private var addedNodes: [SCNNode] = []
    /// Где проём на стене: позиция стены в room.walls, лево, право, низ, верх
    private var openingRects: [Int: (wall: Int, l: Float, r: Float, b: Float, t: Float)] = [:]
    private var curtainMats: [String: SCNMaterial] = [:]
    private let orbitCamera = SCNNode()
    private let roomCamera = SCNNode()
    private var viewpoints: [(SIMD2<Float>, SIMD2<Float>)] = []
    private var viewpointIndex = 0
    private var yaw: Float = 0
    private var pitch: Float = -0.12
    /// Направление виртуального стика: x — вбок, y — вперёд/назад.
    private var walkInput = SIMD2<Float>(0, 0)
    private var previousWalkTick = CACurrentMediaTime()
    private var lookStart: (Float, Float) = (0, 0)
    private var fovStart: CGFloat = 75
    private var selectionNode: SCNNode?
    private var timer: Timer?
    private var dragIndex: Int?
    private var dragOffset = SIMD2<Float>(0, 0)
    private var preparing = false
    private let warmQueue = DispatchQueue(label: "stroyscan.warm", qos: .userInitiated)
    private let tap = UITapGestureRecognizer()
    private let pan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()

    init(result: RoomResult, look: Look) {
        self.result = result
        self.room = Room3D(result)
        self.look = look
        self.shown = look
        self.eng = result.engineering
        self.tiling = result.tiling
        self.view = SCNView(frame: .zero)
        super.init()
        setupScene()
        setupGestures()
        viewpoints = makeViewpoints()
    }

    deinit {
        timer?.invalidate()
        // текстуры нужны только этому экрану: отпускаем память
        Tex.purge()
        Mat.purge()
    }

    // MARK: Для экрана

    var firstWall: Int { room.walls.first?.index ?? 0 }
    var firstWindow: Int? {
        result.openings.indices.first { result.openings[$0].kind == "window" && openingRects[$0] != nil }
    }
    var hasHidden: Bool { look.objects.values.contains { $0.hidden } }

    func variant(ofItem i: Int) -> String {
        look.objects[String(i)]?.variant ?? LookOptions.defaultVariant(result.items[i])
    }

    func color(ofItem i: Int) -> String {
        look.objects[String(i)]?.color
            ?? LookOptions.defaultColor(kind: result.items[i].kind, variant: variant(ofItem: i), palette: look.palette)
    }

    func wallFinish(_ i: Int) -> Look.Finish {
        if let a = look.accent, a.wall == i { return Look.Finish(finish: a.finish, color: a.color, pattern: a.pattern) }
        return look.wall
    }

    /// Экран открылся: в фоне рисуем текстуры, потом собираем сцену
    func start() {
        if !ready && !preparing {
            preparing = true
            let first = look
            warmQueue.async { [weak self] in
                self?.warm(first)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.shown = self.look
                    self.buildAll()
                    self.setInside(self.inside)
                    self.preparing = false
                    self.ready = true
                }
            }
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                self?.advanceWalk()
                self?.updateCutaway()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func select(_ p: Pick?) {
        pick = p
        highlight()
    }

    // MARK: Правки

    /// Любая правка: экран обновляется сразу, сцена — когда готовы текстуры
    func edit(_ change: (inout Look) -> Void) {
        var l = look
        change(&l)
        guard l != look else { return }
        look = l
        warmQueue.async { [weak self] in
            self?.warm(l)
            DispatchQueue.main.async { self?.show(l) }
        }
    }

    /// Ремонт целиком (например, с сервера)
    func replace(_ l: Look) { edit { $0 = l } }

    func setStyle(_ s: RenoStyle) { edit { $0 = $0.withStyle(s) } }

    /// Акцентная стена: nil — все стены одинаковые
    func setAccent(_ wall: Int?) {
        edit { l in
            guard let wall else { l.accent = nil; return }
            guard l.accent?.wall != wall else { return }
            let base = l.wall
            let color = UIColor(hex: base.color).luma > 0.6 ? "#7c8b7a" : "#e9e4da"
            l.accent = Look.Accent(wall: wall, finish: base.finish, color: color, pattern: base.pattern)
        }
    }

    /// Отделка стены: акцентной — только её, иначе всех
    func editWall(_ wall: Int, finish: String? = nil, color: String? = nil, pattern: String? = nil) {
        edit { l in
            if var a = l.accent, a.wall == wall {
                if let finish { a.finish = finish }
                if let color { a.color = color }
                if let pattern { a.pattern = pattern }
                l.accent = a
            } else {
                if let finish { l.wall.finish = finish }
                if let color { l.wall.color = color }
                if let pattern { l.wall.pattern = pattern }
            }
        }
    }

    func setFloor(finish: String? = nil, color: String? = nil) {
        edit { l in
            if let finish { l.floor.finish = finish }
            if let color { l.floor.color = color }
        }
    }

    func setCeiling(light: String? = nil, color: String? = nil) {
        edit { l in
            if let light { l.ceiling.light = light }
            if let color { l.ceiling.color = color }
        }
    }

    func setCurtains(_ v: String) { edit { $0.curtains = v } }

    func setObject(_ i: Int, variant: String? = nil, color: String? = nil) {
        let kind = result.items[i].kind
        edit { l in
            var o = l.objects[String(i)] ?? Look.Item()
            if let variant {
                o.variant = variant
                if let c = o.color, !LookOptions.colors(kind: kind, variant: variant).contains(c) { o.color = nil }
            }
            if let color { o.color = color }
            l.objects[String(i)] = o
        }
    }

    func hideObject(_ i: Int) {
        select(nil)
        edit { l in
            var o = l.objects[String(i)] ?? Look.Item()
            o.hidden = true
            l.objects[String(i)] = o
        }
    }

    func restoreHidden() {
        edit { l in
            for (key, var o) in l.objects where o.hidden {
                o.hidden = false
                l.objects[key] = o
            }
        }
    }

    /// Вариант или цвет добавленной вещи. false — вещь такого размера в комнату не помещается.
    @discardableResult
    func setAdded(_ j: Int, variant: String? = nil, color: String? = nil) -> Bool {
        guard look.added.indices.contains(j) else { return false }
        var a = look.added[j]
        if let variant, variant != a.variant {
            a.variant = variant
            let s = LookOptions.size(kind: a.kind, variant: variant)
            a.width = s.x
            a.depth = s.y
            a.height = s.z
            if !LookOptions.colors(kind: a.kind, variant: variant).contains(a.color) {
                a.color = LookOptions.defaultColor(kind: a.kind, variant: variant, palette: look.palette)
            }
            // стала больше и упёрлась в стену — двигаем на ближайшее место, где встаёт целиком
            guard let c = nearestFit(a) else { return false }
            a.x = Double(c.x)
            a.y = Double(c.y)
        }
        if let color { a.color = color }
        edit { l in
            guard l.added.indices.contains(j) else { return }
            l.added[j] = a
        }
        return true
    }

    /// Поворот на 90°. Не встаёт на месте — ближайшее место, где встаёт; false — повёрнутой не помещается.
    @discardableResult
    func rotateAdded(_ j: Int) -> Bool {
        guard look.added.indices.contains(j) else { return false }
        var a = look.added[j]
        a.angle = (a.angle + .pi / 2).truncatingRemainder(dividingBy: 2 * .pi)
        guard let c = nearestFit(a) else { return false }
        a.x = Double(c.x)
        a.y = Double(c.y)
        edit { l in
            guard l.added.indices.contains(j) else { return }
            l.added[j] = a
        }
        return true
    }

    func removeAdded(_ j: Int) {
        select(nil)
        edit { l in
            guard l.added.indices.contains(j) else { return }
            l.added.remove(at: j)
        }
    }

    enum AddResult { case added, tooMany, noRoom }

    /// Новая мебель на свободное место: к стене или ближе к середине комнаты
    @discardableResult
    func add(kind: String, variant: String) -> AddResult {
        guard look.added.count < Look.maxAdded else { return .tooMany }
        let s = LookOptions.size(kind: kind, variant: variant)
        let w = Float(s.x), d = Float(s.y)
        var found = freeSpot(kind: kind, variant: variant, w: w, d: d, h: Float(s.z))
        if found == nil {
            // свободного места нет — ставим ближе к середине, но целиком в комнате (можно поверх мебели)
            for angle in [Float(0), .pi / 2] {
                if let c = nearestFit(room.centroid, angle: angle, w: w, d: d) { found = (c, angle); break }
            }
        }
        guard let spot = found else { return .noRoom }
        let item = Look.Added(kind: kind, variant: variant,
                              color: LookOptions.defaultColor(kind: kind, variant: variant, palette: look.palette),
                              width: s.x, depth: s.y, height: s.z,
                              x: Double(spot.0.x), y: Double(spot.0.y), angle: Double(spot.1))
        let j = look.added.count
        edit { $0.added.append(item) }
        select(.added(j))
        return .added
    }

    // MARK: Камера

    func setInside(_ on: Bool) {
        inside = on
        walkInput = .zero
        previousWalkTick = CACurrentMediaTime()
        if on {
            view.allowsCameraControl = false
            view.pointOfView = roomCamera
            goToViewpoint()
        } else {
            view.pointOfView = orbitCamera
            resetOrbit()
            view.allowsCameraControl = true
            let control = view.defaultCameraController
            control.interactionMode = .orbitTurntable
            control.inertiaEnabled = true
            control.target = SCNVector3(room.centroid.x, 0.6, room.centroid.y)
            // не уходим под пол и не переворачиваемся через верх
            control.minimumVerticalAngle = 5
            control.maximumVerticalAngle = 89.5
            chainGestures()
        }
        applyVisibility()
    }

    /// Стик задаёт скорость прогулки; пустой стик останавливает камеру.
    func setWalkInput(x: Float, y: Float) {
        let input = SIMD2(x, y)
        let length = simd_length(input)
        walkInput = length > 1 ? input / length : input
    }

    /// Плавно двигает камеру на уровне глаз и не выпускает её за контур комнаты.
    private func advanceWalk() {
        let now = CACurrentMediaTime()
        let deltaTime = Float(min(now - previousWalkTick, 0.1))
        previousWalkTick = now
        guard inside, deltaTime > 0, simd_length_squared(walkInput) > 0.002 else { return }

        let cameraPosition = roomCamera.simdPosition
        let current = SIMD2(cameraPosition.x, cameraPosition.z)
        let forward = SIMD2(-sin(yaw), -cos(yaw))
        let right = SIMD2(cos(yaw), -sin(yaw))
        let step = (right * walkInput.x + forward * walkInput.y) * (1.1 * deltaTime)
        let destination = current + step

        if room.inside(destination) {
            roomCamera.simdPosition.x = destination.x
            roomCamera.simdPosition.z = destination.y
            return
        }

        // У стены скользим вдоль неё, чтобы прогулка не замирала от диагонального движения.
        let slideX = SIMD2(destination.x, current.y)
        let slideZ = SIMD2(current.x, destination.y)
        if room.inside(slideX) {
            roomCamera.simdPosition.x = slideX.x
        } else if room.inside(slideZ) {
            roomCamera.simdPosition.z = slideZ.y
        }
    }

    func setFurnitureHidden(_ on: Bool) {
        furnitureHidden = on
        if pick != nil { select(nil) }
        itemHolder.isHidden = on
        addedHolder.isHidden = on || bare
        customHolder.isHidden = on || bare
    }

    /// Повернуть комнату на четверть оборота (кнопками — без возни пальцами)
    func turnOrbit(_ quarters: Int) {
        if inside { setInside(false) }
        if let p = view.pointOfView?.simdWorldPosition {
            // продолжаем от того места, куда человек уже повернул пальцем
            let c = room.centroid
            let v = SIMD2(p.x - c.x, p.z - c.y)
            if simd_length(v) > 0.3 && !topView { orbitYaw = atan2(v.x, v.y) }
        }
        orbitYaw += Float(quarters) * .pi / 2
        topView = false
        placeOrbit(animated: true)
    }

    func setTopView(_ on: Bool) {
        if inside { setInside(false) }
        topView = on
        placeOrbit(animated: true)
    }

    /// Вся комната целиком, вид по умолчанию
    func resetView() {
        if inside { setInside(false) }
        topView = false
        orbitYaw = atan2(0.5, 0.8)
        placeOrbit(animated: true)
    }

    func setBare(_ on: Bool) {
        guard on != bare else { return }
        select(nil)
        bare = on
        if ready { buildAll() }
    }

    func setBrightness(_ v: Float) {
        brightness = max(-1, min(1, v))
        for cam in [orbitCamera.camera, roomCamera.camera] {
            cam?.exposureOffset = CGFloat(RenoEditor.baseExposure + brightness * 0.8)
        }
    }

    func nextViewpoint() {
        guard !viewpoints.isEmpty else { return }
        viewpointIndex = (viewpointIndex + 1) % viewpoints.count
        goToViewpoint()
    }

    /// Кадр с экрана — для фото «как в жизни»
    func snapshot() -> UIImage { view.snapshot() }

    /// 3D-модель с ремонтом файлом USDZ
    func exportUSDZ() -> URL? {
        let saved = pick
        select(nil)
        defer { select(saved) }
        let name = result.room.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Ремонт-\(name).usdz")
        try? FileManager.default.removeItem(at: url)
        let dimensions = result.addDimensionAnnotations(to: scene) { x, z, elevation in
            SCNVector3(Float(x), Float(elevation), Float(z))
        }
        defer { dimensions?.removeFromParentNode() }
        return scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) ? url : nil
    }

    // MARK: - Сцена

    private func setupScene() {
        let backdrop = rgb(0.86, 0.88, 0.90)
        scene.background.contents = backdrop
        // свет окружения: мягкие блики и тени без чёрных провалов
        scene.lightingEnvironment.contents = Tex.environment()
        scene.lightingEnvironment.intensity = 0.6
        floorHolder.name = "floor"
        ceilingHolder.name = "ceiling"
        lampHolder.name = "lamps"
        engHolder.name = "eng"
        for n in [floorHolder, ceilingHolder, lampHolder, wallHolder, itemHolder, addedHolder, lightHolder, engHolder, defectHolder,
                  tileHolder, customHolder] {
            scene.rootNode.addChildNode(n)
        }
        orbitCamera.camera = RenoEditor.camera(room: false)
        roomCamera.camera = RenoEditor.camera(room: true)
        scene.rootNode.addChildNode(orbitCamera)
        scene.rootNode.addChildNode(roomCamera)
        view.scene = scene
        view.backgroundColor = backdrop
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 60
        view.pointOfView = orbitCamera
        resetOrbit()
    }

    /// Сдвиг экспозиции по умолчанию: чуть темнее нейтрали — светлые стены не пересвечены
    static let baseExposure: Float = -0.35

    /// Камера как у фотографа интерьеров: HDR, автоэкспозиция, мягкое затенение углов
    private static func camera(room: Bool) -> SCNCamera {
        let c = SCNCamera()
        c.zNear = 0.03
        c.zFar = 150
        c.projectionDirection = .horizontal
        c.fieldOfView = room ? 75 : 55
        c.wantsHDR = true
        // автоэкспозиция только затемняет: светлую комнату она «вытягивала» до белого пятна
        c.wantsExposureAdaptation = room
        c.exposureAdaptationBrighteningSpeedFactor = 0.6
        c.exposureAdaptationDarkeningSpeedFactor = 0.8
        c.minimumExposure = -2
        c.maximumExposure = 0.2
        c.exposureOffset = CGFloat(baseExposure)
        // мягкий «плечевой» тон: светлые стены остаются с фактурой, а не уходят в белое
        c.whitePoint = 1.8
        c.bloomThreshold = 1.6
        c.bloomIntensity = 0.12
        c.bloomBlurRadius = 8
        c.screenSpaceAmbientOcclusionIntensity = room ? 1.0 : 0.8
        c.screenSpaceAmbientOcclusionRadius = 0.3
        c.screenSpaceAmbientOcclusionBias = 0.03
        c.screenSpaceAmbientOcclusionDepthThreshold = 0.2
        c.screenSpaceAmbientOcclusionNormalThreshold = 0.3
        c.vignettingIntensity = room ? 0.3 : 0.15
        c.vignettingPower = 0.8
        c.saturation = 1.04
        c.contrast = 0.06
        return c
    }

    private func resetOrbit() {
        placeOrbit(animated: false)
    }

    /// Камера снаружи: под углом orbitYaw или строго сверху; комната целиком в кадре
    private func placeOrbit(animated: Bool) {
        let c = room.centroid
        let span = max(room.hi.x - room.lo.x, room.hi.y - room.lo.y, 2.5)
        let d = span * 1.1 + 1.5
        let target = SIMD3(c.x, topView ? 0 : 0.6, c.y)
        let pos: SIMD3<Float>
        if topView {
            pos = SIMD3(c.x, room.height + span * 1.25 + 1, c.y + 0.001)
        } else {
            let r = d * 0.94
            pos = SIMD3(c.x + sin(orbitYaw) * r, d * 0.95 + room.height * 0.3, c.y + cos(orbitYaw) * r)
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.6 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        orbitCamera.simdPosition = pos
        orbitCamera.simdLook(at: target, up: topView ? SIMD3(0, 0, -1) : SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        SCNTransaction.commit()
        if view.pointOfView === orbitCamera {
            view.defaultCameraController.target = SCNVector3(target.x, target.y, target.z)
        }
    }

    private func goToViewpoint() {
        guard !viewpoints.isEmpty else { return }
        let (p, target) = viewpoints[viewpointIndex % viewpoints.count]
        roomCamera.simdPosition = SIMD3(p.x, 1.45, p.y)
        let d = target - p
        yaw = atan2(-d.x, -d.y)
        pitch = -0.12
        roomCamera.camera?.fieldOfView = 75
        applyRoomCamera()
    }

    private func applyRoomCamera() {
        roomCamera.simdOrientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
    }

    /// Точки съёмки: из дальних углов и из дверей, взгляд на середину комнаты
    private func makeViewpoints() -> [(SIMD2<Float>, SIMD2<Float>)] {
        let c = room.centroid
        var corners: [(SIMD2<Float>, Float)] = []
        for v in room.polygon {
            let d = c - v
            let len = simd_length(d)
            guard len > 1 else { continue }
            let p = v + d / len * 0.55
            if room.inside(p) { corners.append((p, len)) }
        }
        corners.sort { $0.1 > $1.1 }
        var doors: [SIMD2<Float>] = []
        for (pos, list) in room.openings.enumerated() {
            for o in list where o.kind != "window" {
                let g = room.walls[pos]
                let p = g.point(o.center) + g.normal * 0.45
                if room.inside(p) { doors.append(p) }
            }
        }
        var out: [(SIMD2<Float>, SIMD2<Float>)] = []
        if let best = corners.first { out.append((best.0, c)) }
        out += doors.map { ($0, c) }
        out += corners.dropFirst().prefix(3).map { ($0.0, c) }
        if out.isEmpty { out.append((c + SIMD2(0, 0.01), c + SIMD2(0, -1))) }
        return out
    }

    /// Прячем стены между камерой и комнатой, потолок и вид за окнами — когда смотрим сверху
    private func applyVisibility() {
        let orbit = !inside
        ceilingHolder.isHidden = orbit
        for list in outsideNodes {
            for n in list { n.isHidden = orbit }
        }
        if !orbit { wallNodes.forEach { $0.isHidden = false } }
        updateCutaway()
        syncEngVisibility()
    }

    private func updateCutaway() {
        guard !inside, let cam = view.pointOfView?.presentation.simdWorldPosition else { return }
        let c = SIMD2(cam.x, cam.z)
        for (pos, g) in room.walls.enumerated() where pos < wallNodes.count {
            let hide = simd_dot(c - g.mid, g.normal) < -0.05
            if wallNodes[pos].isHidden != hide { wallNodes[pos].isHidden = hide }
        }
        syncEngVisibility()
    }

    private func buildAll() {
        buildFloor()
        buildCeiling()
        buildWalls()
        buildItems()
        buildAdded()
        buildLamps()
        buildLights()
        buildEngineering()
        buildDefects()
        buildTiles()
        buildCustom()
        highlight()
        applyVisibility()
    }

    /// Показывает готовую правку: перестраивает только то, что поменялось
    private func show(_ l: Look) {
        guard ready, l == look else { return }
        let old = shown
        shown = l
        refresh(from: old, to: l)
    }

    private func refresh(from old: Look, to new: Look) {
        if old.style != new.style {
            buildAll()
            return
        }
        var walls = Set<Int>()
        if old.wall != new.wall || old.curtains != new.curtains {
            walls = Set(room.walls.indices)
        } else if old.accent != new.accent {
            for i in [old.accent?.wall, new.accent?.wall].compactMap({ $0 }) {
                if let pos = room.walls.firstIndex(where: { $0.index == i }) { walls.insert(pos) }
            }
        }
        for pos in walls.sorted() { rebuildWall(pos) }
        if old.floor != new.floor { buildFloor() }
        if old.ceiling.color != new.ceiling.color { buildCeiling() }

        var tables = false
        for i in result.items.indices where old.objects[String(i)] != new.objects[String(i)] {
            rebuildItem(i)
            if result.items[i].kind == "table" { tables = true }
        }
        let sameList = old.added.count == new.added.count
            && !zip(old.added, new.added).contains { pair in pair.0.id != pair.1.id }
        if !sameList || addedNodes.count != new.added.count {
            buildAdded()
            tables = true
        } else {
            for j in new.added.indices where old.added[j] != new.added[j] {
                let a = old.added[j], b = new.added[j]
                if a.kind == b.kind && a.variant == b.variant && a.color == b.color
                    && a.width == b.width && a.depth == b.depth && a.height == b.height {
                    place(addedNodes[j], b)
                } else {
                    replaceAdded(j)
                }
                if b.kind == "table" { tables = true }
            }
        }
        if old.ceiling.light != new.ceiling.light || (tables && new.ceiling.light == "pendant") { buildLamps() }
        highlight()
        applyVisibility()
    }

    // MARK: Пол, потолок, свет

    /// Контур чуть шире стен: пол и потолок заходят под стены без щелей
    private func expanded(_ p: [SIMD2<Float>], by d: Float) -> [SIMD2<Float>] {
        p.map { q in
            let v = q - room.centroid
            let len = simd_length(v)
            return len > 0.01 ? q + v / len * d : q
        }
    }

    private func buildFloor() {
        floorHolder.childNodes.forEach { $0.removeFromParentNode() }
        guard room.polygon.count > 2 else { return }
        let m = bare ? RenoEditor.bareFloor : Mat.floor(shown.floor.finish, shown.floor.color)
        floorHolder.addChildNode(SCNNode(geometry: Mesh.polygon(expanded(room.polygon, by: 0.06), y: 0, up: true, m)))
    }

    private func buildCeiling() {
        ceilingHolder.childNodes.forEach { $0.removeFromParentNode() }
        guard room.polygon.count > 2 else { return }
        let m = bare ? RenoEditor.bareCeiling : Mat.wall("paint", shown.ceiling.color, "plain")
        ceilingHolder.addChildNode(SCNNode(geometry: Mesh.polygon(expanded(room.polygon, by: 0.06), y: room.height, up: false, m)))
    }

    private func buildLamps() {
        lampHolder.childNodes.forEach { $0.removeFromParentNode() }
        // голая комната — светильников ещё нет
        guard !bare else { return }
        let node = Lamps.build(shown.ceiling.light, center: room.centroid, ceiling: room.height, lo: room.lo, hi: room.hi,
                               table: diningTable(), palette: shown.palette, inside: room.inside)
        lampHolder.addChildNode(node)
    }

    /// Обеденный стол для подвесов: центр, длинная сторона, высота, угол длинной стороны
    private func diningTable() -> (SIMD2<Float>, Float, Float, Float)? {
        for (i, it) in result.items.enumerated() where it.kind == "table" {
            let edit = shown.objects[String(i)]
            if edit?.hidden == true { continue }
            let v = edit?.variant ?? LookOptions.defaultVariant(it)
            guard v == "dining_rect" || v == "dining_round" else { continue }
            let angle = Float(it.angle) + (it.width >= it.depth ? 0 : .pi / 2)
            return (SIMD2(Float(it.x), Float(it.y)), Float(max(it.width, it.depth)), Float(it.height), angle)
        }
        for a in shown.added where a.kind == "table" && (a.variant == "dining_rect" || a.variant == "dining_round") {
            let angle = Float(a.angle) + (a.width >= a.depth ? 0 : .pi / 2)
            return (SIMD2(Float(a.x), Float(a.y)), Float(max(a.width, a.depth)), Float(a.height), angle)
        }
        return nil
    }

    /// Солнце через главное окно (с тенями) и мягкий дневной свет от окон
    private func buildLights() {
        lightHolder.childNodes.forEach { $0.removeFromParentNode() }
        // голая комната — ровный свет без бликов и тёмных углов: всё видно с любой стороны
        for cam in [orbitCamera.camera, roomCamera.camera] {
            cam?.vignettingIntensity = bare ? 0 : (cam === roomCamera.camera ? 0.3 : 0.15)
            cam?.screenSpaceAmbientOcclusionIntensity = bare ? 0.5 : (cam === roomCamera.camera ? 1.0 : 0.8)
            cam?.wantsExposureAdaptation = !bare && cam === roomCamera.camera
        }
        if bare {
            let amb = SCNLight()
            amb.type = .ambient
            amb.intensity = 650
            amb.temperature = 5500
            let a = SCNNode()
            a.light = amb
            lightHolder.addChildNode(a)
            let top = SCNLight()
            top.type = .directional
            top.intensity = 450
            top.castsShadow = false
            let t = SCNNode()
            t.light = top
            t.simdPosition = SIMD3(room.centroid.x, 10, room.centroid.y)
            t.simdLook(at: SIMD3(room.centroid.x + 1.5, 0, room.centroid.y + 2.5))
            lightHolder.addChildNode(t)
            return
        }
        var windows: [(WallGeo, OpeningGeo)] = []
        for (pos, list) in room.openings.enumerated() {
            for o in list where o.kind == "window" { windows.append((room.walls[pos], o)) }
        }
        windows.sort { $0.1.width * $0.1.height > $1.1.width * $1.1.height }
        let c = room.centroid
        var dir = simd_normalize(SIMD3<Float>(0.35, -1, 0.5))
        if let main = windows.first?.0 {
            let n = main.normal, t = main.dir
            dir = simd_normalize(SIMD3(n.x + t.x * 0.35, -0.8, n.y + t.y * 0.35))
        }
        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 850
        sun.temperature = 5600
        sun.castsShadow = true
        sun.shadowMode = .deferred
        sun.shadowSampleCount = 12
        sun.shadowRadius = 2.5
        sun.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.shadowColor = UIColor(white: 0, alpha: 0.8)
        sun.maximumShadowDistance = 30
        let sunNode = SCNNode()
        sunNode.light = sun
        let target = SIMD3(c.x, 0, c.y)
        sunNode.simdPosition = target - dir * 8
        sunNode.simdLook(at: target)
        lightHolder.addChildNode(sunNode)

        for (w, o) in windows.prefix(2) {
            let p = w.point(o.center)
            let l = SCNLight()
            l.type = .spot
            l.intensity = 380
            l.temperature = 6500
            l.spotInnerAngle = 40
            l.spotOuterAngle = 140
            l.attenuationStartDistance = 0.5
            l.attenuationEndDistance = 8
            l.attenuationFalloffExponent = 1.4
            let node = SCNNode()
            node.light = l
            let at = SIMD3(p.x + w.normal.x * 0.05, o.bottom + o.height * 0.6, p.y + w.normal.y * 0.05)
            node.simdPosition = at
            node.simdLook(at: at + SIMD3(w.normal.x, -0.3, w.normal.y))
            lightHolder.addChildNode(node)
        }
    }

    // MARK: Стены, окна, двери

    private func buildWalls() {
        wallHolder.childNodes.forEach { $0.removeFromParentNode() }
        wallNodes = []
        outsideNodes = []
        openingRects = [:]
        for pos in room.walls.indices {
            let (node, outside) = buildWall(pos)
            wallHolder.addChildNode(node)
            wallNodes.append(node)
            outsideNodes.append(outside)
        }
    }

    private func rebuildWall(_ pos: Int) {
        guard pos < wallNodes.count, pos < outsideNodes.count else { return }
        wallNodes[pos].removeFromParentNode()
        let (node, outside) = buildWall(pos)
        wallHolder.addChildNode(node)
        wallNodes[pos] = node
        outsideNodes[pos] = outside
        buildTiles()
    }

    private func surface(forWall i: Int) -> Look.Finish {
        if let a = shown.accent, a.wall == i { return Look.Finish(finish: a.finish, color: a.color, pattern: a.pattern) }
        return shown.wall
    }

    /// Стена: куски вокруг проёмов, толщина, плинтус, окна со шторами, двери
    private func buildWall(_ pos: Int) -> (SCNNode, [SCNNode]) {
        let g = room.walls[pos]
        let len = g.length, top = room.height, thick: Float = 0.12
        let group = SCNNode()
        group.name = "wall:\(g.index)"
        group.simdPosition = SIMD3(g.a.x, 0, g.a.y)
        group.eulerAngles.y = atan2(-g.dir.y, g.dir.x)
        let f = surface(forWall: g.index)
        let wallMat = bare ? RenoEditor.bareWall : Mat.wall(f.finish, f.color, f.pattern)
        let cut = Mat.flat(rgb(0.95, 0.94, 0.92), rough: 0.9)
        let bodyMats = [Mat.invisible, cut, cut, cut, cut, cut]
        let trim = Mat.flat(shown.palette.trim, rough: 0.4)
        let classic = shown.style == "classic"
        let k = Kit(group)
        var outside: [SCNNode] = []

        var rects: [(Float, Float, Float, Float)] = []
        var cursor: Float = 0
        var kept: [(OpeningGeo, Float, Float)] = []
        for o in room.openings[pos] {
            let l = max(o.left, cursor), r = min(o.right, len)
            guard r - l > 0.2 else { continue }
            if l > cursor + 0.001 { rects.append((cursor, l, 0, top)) }
            if o.bottom > 0.001 { rects.append((l, r, 0, o.bottom)) }
            if o.top < top - 0.001 { rects.append((l, r, o.top, top)) }
            cursor = r
            kept.append((o, l, r))
        }
        if cursor < len - 0.001 { rects.append((cursor, len, 0, top)) }

        for (x0, x1, y0, y1) in rects {
            group.addChildNode(SCNNode(geometry: Mesh.quad(x0, x1, y0, y1, top: top, wallMat)))
            // толщина стены: видна на срезе сверху и в откосах окон
            let e0: Float = x0 < 0.001 ? thick : 0, e1: Float = x1 > len - 0.001 ? thick : 0
            let box = SCNBox(width: CGFloat(x1 - x0 + e0 + e1), height: CGFloat(y1 - y0), length: CGFloat(thick), chamferRadius: 0)
            box.materials = bodyMats
            let body = SCNNode(geometry: box)
            body.simdPosition = SIMD3((x0 - e0 + x1 + e1) / 2, (y0 + y1) / 2, -thick / 2)
            group.addChildNode(body)
            if y0 < 0.001 && !bare {
                k.box(x1 - x0, 0.08, 0.014, trim, x: (x0 + x1) / 2, y: 0, z: 0.007)
            }
            if classic && !bare && y1 > top - 0.001 {
                k.box(x1 - x0, 0.09, 0.05, trim, x: (x0 + x1) / 2, y: top - 0.09, z: 0.025, r: 0.012)
            }
        }

        for (o, l, r) in kept {
            openingRects[o.index] = (pos, l, r, o.bottom, o.top)
            let holder = SCNNode()
            group.addChildNode(holder)
            let ok = Kit(holder)
            let cx = (l + r) / 2
            if o.kind == "window" {
                holder.name = "win:\(o.index)"
                window(ok, l: l, r: r, b: o.bottom, t: o.top, thick: thick)
                let scenery = backdrop(w: r - l + 4, h: o.height + 3, x: cx, y: o.bottom + o.height / 2, z: -thick - 2.2)
                holder.addChildNode(scenery)
                outside.append(scenery)
            } else {
                holder.name = "door:\(o.index)"
                door(ok, l: l, r: r, t: o.top, thick: thick, leaf: o.kind == "door")
                if o.kind != "door" {
                    let hall = passage(w: r - l, t: o.top, x: cx, thick: thick)
                    holder.addChildNode(hall)
                    outside.append(hall)
                }
            }
        }
        return (group, outside)
    }

    private func window(_ k: Kit, l: Float, r: Float, b: Float, t: Float, thick: Float) {
        let frame = Mat.flat(shown.palette.trim, rough: 0.35)
        let w = r - l, h = t - b, cx = (l + r) / 2
        let zf = -thick * 0.45
        let bar: Float = 0.06
        k.box(w, bar, 0.07, frame, x: cx, y: b, z: zf)
        k.box(w, bar, 0.07, frame, x: cx, y: t - bar, z: zf)
        k.box(bar, h, 0.07, frame, x: l + bar / 2, y: b, z: zf)
        k.box(bar, h, 0.07, frame, x: r - bar / 2, y: b, z: zf)
        let panes = max(1, Int((w / 0.8).rounded()))
        if panes > 1 {
            for i in 1..<panes {
                k.box(0.05, h - 2 * bar, 0.06, frame, x: l + w * Float(i) / Float(panes), y: b + bar, z: zf)
            }
        }
        if h > 1.7 { k.box(w - 2 * bar, 0.05, 0.06, frame, x: cx, y: t - 0.5, z: zf) }
        let glass = k.box(w - 2 * bar, h - 2 * bar, 0.006, Mat.glass, x: cx, y: b + bar, z: zf)
        glass.castsShadow = false
        if b > 0.25 && !bare {
            // подоконник
            let depth = thick * 0.5 + 0.08
            k.box(w + 0.12, 0.035, depth, Mat.flat(rgb(0.95, 0.95, 0.94), rough: 0.25), x: cx, y: b - 0.035, z: 0.08 - depth / 2)
        }
        if !bare { curtains(k, l: l, r: r, b: b, t: t) }
    }

    private func twoSided(_ hex: String) -> SCNMaterial {
        if let m = curtainMats[hex] { return m }
        let m = (Mat.fabric(hex).copy() as? SCNMaterial) ?? Mat.fabric(hex)
        m.isDoubleSided = true
        curtainMats[hex] = m
        return m
    }

    private func curtains(_ k: Kit, l: Float, r: Float, b: Float, t: Float) {
        let pal = shown.palette
        let w = r - l, cx = (l + r) / 2
        switch shown.curtains {
        case "curtains":
            // карниз под потолком, шторы до пола и тюль
            let rodY = min(room.height - 0.06, t + 0.22)
            let span = w + 0.5
            k.rod(SIMD3(cx - span / 2 - 0.06, rodY, 0.14), SIMD3(cx + span / 2 + 0.06, rodY, 0.14), 0.011,
                  Mat.metal(pal.metal, rough: 0.3))
            let drop = rodY - 0.03
            let fabric = twoSided(pal.curtain)
            let pw = max(0.35, min(0.8, w * 0.28 + 0.12))
            for x in [cx - span / 2, cx + span / 2 - pw] {
                let n = SCNNode(geometry: Mesh.drape(width: pw, height: drop, fold: 0.13, depth: 0.07, fabric))
                n.simdPosition = SIMD3(x, 0.015, 0.14)
                k.node.addChildNode(n)
            }
            let tulle = SCNNode(geometry: Mesh.drape(width: span - 0.1, height: drop - 0.02, fold: 0.09, depth: 0.03, Mat.sheer))
            tulle.simdPosition = SIMD3(cx - span / 2 + 0.05, 0.025, 0.085)
            tulle.castsShadow = false
            k.node.addChildNode(tulle)
        case "blinds":
            // жалюзи опущены на две трети
            let slats = Kit()
            let m = Mat.flat(UIColor(hex: pal.curtain), rough: 0.5)
            let low = b + (t - b) * 0.35
            slats.box(w - 0.08, 0.035, 0.05, m, x: cx, y: t - 0.035, z: 0)
            var y = t - 0.08
            while y > low {
                slats.box(w - 0.12, 0.004, 0.05, m, x: cx, y: y, z: 0)
                y -= 0.045
            }
            slats.box(w - 0.12, 0.02, 0.05, m, x: cx, y: low - 0.02, z: 0)
            k.node.addChildNode(slats.node.flattenedClone())
        case "roman":
            let m = Mat.fabric(pal.curtain)
            let drop = (t - b) * 0.42
            k.box(w - 0.1, drop, 0.012, m, x: cx, y: t - drop - 0.01, z: 0.01)
            for i in 0..<3 {
                k.box(w - 0.1, 0.06, 0.045, m, x: cx, y: t - drop - 0.03 + Float(i) * 0.075, z: 0.02, r: 0.022)
            }
        default:
            break
        }
    }

    private func door(_ k: Kit, l: Float, r: Float, t: Float, thick: Float, leaf: Bool) {
        let pal = shown.palette
        let trim = Mat.flat(pal.trim, rough: 0.4)
        let w = r - l, cx = (l + r) / 2
        // голая комната — просто проём
        guard !bare else { return }
        // наличники
        k.box(0.07, t + 0.07, 0.02, trim, x: l - 0.035, y: 0, z: 0.01)
        k.box(0.07, t + 0.07, 0.02, trim, x: r + 0.035, y: 0, z: 0.01)
        k.box(w + 0.14, 0.07, 0.02, trim, x: cx, y: t, z: 0.01)
        guard leaf else { return }
        let m = Mat.wood(pal.door)
        let zl = -thick * 0.35
        k.box(w - 0.01, t - 0.01, 0.04, m, x: cx, y: 0.005, z: zl)
        if shown.style == "classic" || shown.style == "budget" {
            // филёнки
            let ph = (t - 0.45) / 2
            for i in 0..<2 {
                k.box(w - 0.24, ph, 0.01, m, x: cx, y: 0.15 + Float(i) * (ph + 0.15), z: zl + 0.022, r: 0.003)
            }
        }
        let metal = Mat.metal(pal.metal, rough: 0.25)
        let hx = r - 0.09, face = zl + 0.02
        k.box(0.035, 0.12, 0.01, metal, x: hx, y: 0.94, z: face + 0.005, r: 0.004)
        k.rod(SIMD3(hx, 1.0, face + 0.01), SIMD3(hx, 1.0, face + 0.05), 0.008, metal)
        k.rod(SIMD3(hx, 1.0, face + 0.05), SIMD3(hx - 0.12, 1.0, face + 0.05), 0.009, metal)
    }

    /// Вид за окном
    private func backdrop(w: Float, h: Float, x: Float, y: Float, z: Float) -> SCNNode {
        let plane = SCNPlane(width: CGFloat(w), height: CGFloat(h))
        plane.materials = [Mat.outdoor]
        let n = SCNNode(geometry: plane)
        n.simdPosition = SIMD3(x, y, z)
        n.castsShadow = false
        return n
    }

    /// Коридор за проёмом без двери
    private func passage(w: Float, t: Float, x: Float, thick: Float) -> SCNNode {
        let k = Kit()
        let wall = Mat.flat(rgb(0.84, 0.83, 0.81), rough: 0.9)
        let floor = Mat.flat(UIColor(hex: shown.floor.color), rough: 0.6)
        let depth: Float = 1.6, z0 = -thick
        k.box(w + 1.2, t + 0.3, 0.02, wall, x: x, y: 0, z: z0 - depth)
        k.box(w + 1.2, 0.02, depth, floor, x: x, y: -0.02, z: z0 - depth / 2)
        k.box(0.02, t + 0.3, depth, wall, x: x - w / 2 - 0.6, y: 0, z: z0 - depth / 2)
        k.box(0.02, t + 0.3, depth, wall, x: x + w / 2 + 0.6, y: 0, z: z0 - depth / 2)
        return k.node
    }

    // MARK: Мебель

    private func buildItems() {
        itemHolder.childNodes.forEach { $0.removeFromParentNode() }
        itemHolder.isHidden = furnitureHidden
        itemNodes = [:]
        for i in result.items.indices { rebuildItem(i) }
    }

    private func rebuildItem(_ i: Int) {
        itemNodes[i]?.removeFromParentNode()
        itemNodes[i] = nil
        guard let node = makeItem(i) else { return }
        itemHolder.addChildNode(node)
        itemNodes[i] = node
    }

    /// Отсканированный предмет точно в размер скана, в выбранном варианте и цвете
    private func makeItem(_ i: Int) -> SCNNode? {
        let it = result.items[i]
        if bare { return bareItem(i, it) }
        let edit = shown.objects[String(i)]
        if edit?.hidden == true { return nil }
        let variant = edit?.variant ?? LookOptions.defaultVariant(it)
        let color = edit?.color ?? LookOptions.defaultColor(kind: it.kind, variant: variant, palette: shown.palette)
        let body = Furniture3D.build(kind: it.kind, variant: variant, width: Float(it.width), depth: Float(it.depth),
                                     height: Float(it.height), color: color, palette: shown.palette,
                                     againstWall: LookOptions.againstWall(it.kind, variant))
        let node = SCNNode()
        node.name = "obj:\(i)"
        node.addChildNode(body.flattenedClone())
        let p = SIMD2(Float(it.x), Float(it.y))
        node.simdPosition = SIMD3(p.x, Float(it.bottom), p.y)
        node.eulerAngles.y = facing(kind: it.kind, variant: variant, at: p, angle: Float(it.angle), skip: i)
        return node
    }

    /// Предмет как в скане Apple: светлая коробка в размер
    private func bareItem(_ i: Int, _ it: RoomResult.Item) -> SCNNode {
        let box = SCNBox(width: CGFloat(it.width), height: CGFloat(it.height), length: CGFloat(it.depth), chamferRadius: 0.01)
        box.firstMaterial = RenoEditor.bareItemMat
        let body = SCNNode(geometry: box)
        body.simdPosition.y = Float(it.height) / 2
        let node = SCNNode()
        node.name = "obj:\(i)"
        node.addChildNode(body)
        node.simdPosition = SIMD3(Float(it.x), Float(it.bottom), Float(it.y))
        node.eulerAngles.y = -Float(it.angle)
        return node
    }

    static let bareWall = Mat.flat(rgb(0.80, 0.80, 0.78), rough: 0.95)
    static let bareFloor = Mat.flat(rgb(0.58, 0.58, 0.56), rough: 0.98)
    static let bareCeiling = Mat.flat(rgb(0.88, 0.88, 0.87), rough: 0.95)
    static let bareItemMat: SCNMaterial = {
        // своя копия: общий кэш материалов не трогаем
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = rgb(0.96, 0.96, 0.95)
        m.roughness.contents = NSNumber(value: 0.7)
        m.transparency = 0.85
        return m
    }()

    /// Поворот: спинкой к ближней стене, стулья — лицом к столу
    private func facing(kind: String, variant: String, at p: SIMD2<Float>, angle: Float, skip: Int) -> Float {
        let front = SIMD2(-sin(angle), cos(angle))
        var flip = false
        if kind == "chair" && variant != "armchair", let t = nearestTable(to: p, skip: skip), simd_distance(t, p) < 1.5 {
            flip = simd_dot(front, t - p) < 0
        } else if let w = room.walls.min(by: { Room3D.distance(p, $0) < Room3D.distance(p, $1) }) {
            flip = simd_dot(front, w.normal) < 0
        }
        return -(angle + (flip ? .pi : 0))
    }

    private func nearestTable(to p: SIMD2<Float>, skip: Int) -> SIMD2<Float>? {
        var points: [SIMD2<Float>] = []
        for (i, it) in result.items.enumerated() where i != skip && it.kind == "table" && shown.objects[String(i)]?.hidden != true {
            points.append(SIMD2(Float(it.x), Float(it.y)))
        }
        for a in shown.added where a.kind == "table" { points.append(SIMD2(Float(a.x), Float(a.y))) }
        return points.min { simd_distance($0, p) < simd_distance($1, p) }
    }

    private func buildAdded() {
        addedHolder.childNodes.forEach { $0.removeFromParentNode() }
        // добавленная мебель — часть ремонта, в комнате «как есть» её нет
        addedHolder.isHidden = bare || furnitureHidden
        addedNodes = shown.added.indices.map { makeAdded($0) }
        addedNodes.forEach { addedHolder.addChildNode($0) }
    }

    private func replaceAdded(_ j: Int) {
        guard j < addedNodes.count else { return }
        addedNodes[j].removeFromParentNode()
        let node = makeAdded(j)
        addedHolder.addChildNode(node)
        addedNodes[j] = node
    }

    private func makeAdded(_ j: Int) -> SCNNode {
        let a = shown.added[j]
        let body = Furniture3D.build(kind: a.kind, variant: a.variant, width: Float(a.width), depth: Float(a.depth),
                                     height: Float(a.height), color: a.color, palette: shown.palette,
                                     againstWall: LookOptions.againstWall(a.kind, a.variant))
        let node = SCNNode()
        node.name = "add:\(j)"
        node.addChildNode(body.flattenedClone())
        place(node, a)
        return node
    }

    private func place(_ node: SCNNode, _ a: Look.Added) {
        // телевизор вешаем на стену
        node.simdPosition = SIMD3(Float(a.x), a.kind == "television" ? 0.75 : 0, Float(a.y))
        node.eulerAngles.y = -Float(a.angle)
    }

    /// Вещь целиком на полу: все четыре угла внутри комнаты, ничего не торчит в стене или в проёме.
    /// Зазор 2 см — на плинтус.
    func inRoom(_ c: SIMD2<Float>, angle: Float, w: Float, d: Float) -> Bool {
        Foot(c, angle: angle, w: w + 0.04, d: d + 0.04).corners.allSatisfy { room.inside($0) }
    }

    private func inRoom(_ a: Look.Added, at c: SIMD2<Float>) -> Bool {
        inRoom(c, angle: Float(a.angle), w: Float(a.width), d: Float(a.depth))
    }

    /// Ближайшее к c место (шаг 5 см), где вещь встаёт целиком; nil — в комнату не помещается
    func nearestFit(_ c: SIMD2<Float>, angle: Float, w: Float, d: Float) -> SIMD2<Float>? {
        if inRoom(c, angle: angle, w: w, d: d) { return c }
        var best: SIMD2<Float>?
        var bestDist = Float.greatestFiniteMagnitude
        var y = room.lo.y
        while y <= room.hi.y {
            var x = room.lo.x
            while x <= room.hi.x {
                let q = SIMD2(x, y)
                let dist = simd_distance_squared(q, c)
                if dist < bestDist && inRoom(q, angle: angle, w: w, d: d) {
                    bestDist = dist
                    best = q
                }
                x += 0.05
            }
            y += 0.05
        }
        return best
    }

    private func nearestFit(_ a: Look.Added) -> SIMD2<Float>? {
        nearestFit(SIMD2(Float(a.x), Float(a.y)), angle: Float(a.angle), w: Float(a.width), d: Float(a.depth))
    }

    /// Во что упирается своя мебель j на этом месте: другая мебель или проход у двери; nil — стоит свободно
    func customBump(_ j: Int) -> String? {
        guard tiling.pieces.indices.contains(j) else { return nil }
        let p = tiling.pieces[j]
        let me = Foot(SIMD2(Float(p.x), Float(p.y)), angle: Float(p.angle), w: Float(p.width), d: Float(p.depth))
        if !furnitureHidden {
            for (i, it) in result.items.enumerated() where look.objects[String(i)]?.hidden != true {
                if me.overlaps(Foot(SIMD2(Float(it.x), Float(it.y)), angle: Float(it.angle), w: Float(it.width), d: Float(it.depth))) {
                    return it.title.lowercased()
                }
            }
            for a in look.added where me.overlaps(Foot(SIMD2(Float(a.x), Float(a.y)), angle: Float(a.angle),
                                                       w: Float(a.width), d: Float(a.depth))) {
                return RoomResult.itemTitle(a.kind).lowercased()
            }
        }
        for (k, c) in tiling.pieces.enumerated() where k != j {
            if me.overlaps(Foot(SIMD2(Float(c.x), Float(c.y)), angle: Float(c.angle), w: Float(c.width), d: Float(c.depth))) {
                return c.name.isEmpty ? "другую вашу мебель" : c.name
            }
        }
        for (pos, list) in room.openings.enumerated() {
            let g = room.walls[pos]
            let along = atan2(g.dir.y, g.dir.x)
            for o in list where o.kind != "window" {
                // 60 см перед дверью — проход
                if me.overlaps(Foot(g.point(o.center) + g.normal * 0.3, angle: along, w: o.width, d: 0.6)) { return "проход у двери" }
            }
        }
        return nil
    }

    /// Свободное место под новую вещь: не на проходе у дверей, не перед окном, не поверх мебели
    func freeSpot(kind: String, variant: String, w: Float, d: Float, h: Float) -> (SIMD2<Float>, Float)? {
        var blocks: [Foot] = []
        for (i, it) in result.items.enumerated() where look.objects[String(i)]?.hidden != true {
            blocks.append(Foot(SIMD2(Float(it.x), Float(it.y)), angle: Float(it.angle),
                               w: Float(it.width) + 0.3, d: Float(it.depth) + 0.3))
        }
        for a in look.added {
            blocks.append(Foot(SIMD2(Float(a.x), Float(a.y)), angle: Float(a.angle), w: Float(a.width) + 0.3, d: Float(a.depth) + 0.3))
        }
        for c in tiling.pieces {
            blocks.append(Foot(SIMD2(Float(c.x), Float(c.y)), angle: Float(c.angle), w: Float(c.width) + 0.3, d: Float(c.depth) + 0.3))
        }
        for (pos, list) in room.openings.enumerated() {
            let g = room.walls[pos]
            let along = atan2(g.dir.y, g.dir.x)
            for o in list {
                if o.kind != "window" {
                    blocks.append(Foot(g.point(o.center) + g.normal * 0.5, angle: along, w: o.width + 0.3, d: 1.0))
                } else if h > o.bottom {
                    blocks.append(Foot(g.point(o.center) + g.normal * 0.3, angle: along, w: o.width + 0.1, d: 0.6))
                }
            }
        }
        func fits(_ f: Foot) -> Bool {
            f.corners.allSatisfy { room.inside($0) } && !blocks.contains { $0.overlaps(f) }
        }
        if LookOptions.againstWall(kind, variant) {
            for g in room.walls.sorted(by: { $0.length > $1.length }) where g.length > w + 0.1 {
                let angle = atan2(g.dir.y, g.dir.x)
                let steps = Int((g.length - w - 0.1) / 0.1)
                // от середины стены к краям
                let order = (0...max(steps, 0)).sorted { abs(Float($0) - Float(steps) / 2) < abs(Float($1) - Float(steps) / 2) }
                for s in order {
                    let c = g.point(w / 2 + 0.05 + Float(s) * 0.1) + g.normal * (d / 2 + 0.03)
                    if fits(Foot(c, angle: angle, w: w, d: d)) { return (c, angle) }
                }
            }
        }
        var best: (SIMD2<Float>, Float)?
        var bestDist = Float.greatestFiniteMagnitude
        var y = room.lo.y + 0.3
        while y < room.hi.y - 0.3 {
            var x = room.lo.x + 0.3
            while x < room.hi.x - 0.3 {
                let c = SIMD2(x, y)
                if fits(Foot(c, angle: 0, w: w + 0.6, d: d + 0.6)) {
                    let dist = simd_distance(c, room.centroid)
                    if dist < bestDist { bestDist = dist; best = (c, 0) }
                }
                x += 0.15
            }
            y += 0.15
        }
        return best
    }

    // MARK: Текстуры заранее

    /// Рисует текстуры ремонта в фоне, чтобы сцена не подвисала
    private func warm(_ l: Look) {
        Mat.prewarm(l)
        let pal = l.palette
        if let a = l.accent {
            var t = l
            t.wall = Look.Finish(finish: a.finish, color: a.color, pattern: a.pattern)
            Mat.prewarm(t)
        }
        _ = Tex.fabric(pal.curtain)
        _ = Tex.fabric(pal.bedding.hexString)
        _ = Tex.fabric(mix(pal.bedding, UIColor(hex: pal.fabric), 0.12).hexString)
        if pal.leather { _ = Tex.leather(pal.fabric) }
        func one(_ kind: String, _ variant: String, _ color: String) {
            if LookOptions.isSoft(kind, variant) {
                if pal.leather || variant == "chesterfield" { _ = Tex.leather(color) } else { _ = Tex.fabric(color) }
            } else if ["table", "storage", "chair", "stairs"].contains(kind) {
                let luma = UIColor(hex: color).luma
                if luma <= 0.82 && luma >= 0.1 { _ = Tex.wood(color) }
            }
        }
        for (i, it) in result.items.enumerated() {
            let e = l.objects[String(i)]
            let v = e?.variant ?? LookOptions.defaultVariant(it)
            one(it.kind, v, e?.color ?? LookOptions.defaultColor(kind: it.kind, variant: v, palette: pal))
        }
        for a in l.added { one(a.kind, a.variant, a.color) }
    }

    // MARK: Выделение

    func highlight() {
        selectionNode?.removeFromParentNode()
        selectionNode = nil
        guard let pick else { return }
        var lines: [(SIMD3<Float>, SIMD3<Float>)] = []
        var parent: SCNNode?
        func rect(_ l: Float, _ r: Float, _ b: Float, _ t: Float, z: Float) {
            let p = [SIMD3(l, b, z), SIMD3(r, b, z), SIMD3(r, t, z), SIMD3(l, t, z)]
            for i in 0..<4 { lines.append((p[i], p[(i + 1) % 4])) }
        }
        switch pick {
        case .wall(let i):
            guard let pos = room.walls.firstIndex(where: { $0.index == i }), pos < wallNodes.count else { return }
            rect(0.01, room.walls[pos].length - 0.01, 0.01, room.height - 0.01, z: 0.015)
            parent = wallNodes[pos]
        case .floor, .ceiling:
            let y: Float = pick == .floor ? 0.02 : room.height - 0.02
            let p = room.polygon
            for i in p.indices {
                let a = p[i], b = p[(i + 1) % p.count]
                lines.append((SIMD3(a.x, y, a.y), SIMD3(b.x, y, b.y)))
            }
            parent = scene.rootNode
        case .window(let k), .door(let k):
            guard let r = openingRects[k], r.wall < wallNodes.count else { return }
            rect(r.l - 0.03, r.r + 0.03, max(0.01, r.b - 0.03), r.t + 0.03, z: 0.04)
            parent = wallNodes[r.wall]
        case .object(let i):
            guard let n = itemNodes[i] else { return }
            lines = boxEdges(n)
            parent = n
        case .added(let j):
            guard j < addedNodes.count else { return }
            lines = boxEdges(addedNodes[j])
            parent = addedNodes[j]
        case .custom(let j):
            guard j < customNodes.count else { return }
            lines = boxEdges(customNodes[j])
            parent = customNodes[j]
        }
        guard let parent else { return }
        let frame = Kit()
        frame.node.name = "sel"
        for (a, b) in lines {
            let n = frame.rod(a, b, 0.012, Mat.selection)
            n.castsShadow = false
            n.renderingOrder = 50
        }
        parent.addChildNode(frame.node)
        selectionNode = frame.node
    }

    private func boxEdges(_ n: SCNNode) -> [(SIMD3<Float>, SIMD3<Float>)] {
        let (mn, mx) = n.boundingBox
        let lo = SIMD3<Float>(mn.x, mn.y, mn.z) - 0.02, hi = SIMD3<Float>(mx.x, mx.y, mx.z) + 0.02
        func corner(_ i: Int) -> SIMD3<Float> {
            SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
        }
        var out: [(SIMD3<Float>, SIMD3<Float>)] = []
        for i in 0..<8 {
            for bit in [1, 2, 4] where i & bit == 0 { out.append((corner(i), corner(i | bit))) }
        }
        return out
    }

    /// Что под пальцем
    private func hitPick(at p: CGPoint) -> Pick? {
        let hits = view.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true])
        for h in hits {
            var n: SCNNode? = h.node
            while let cur = n {
                if cur.name == "sel" { break }
                if let name = cur.name, let found = Pick(name: name) { return found }
                n = cur.parent
            }
        }
        return nil
    }

    // MARK: Жесты

    private func setupGestures() {
        tap.addTarget(self, action: #selector(onTap(_:)))
        pan.addTarget(self, action: #selector(onPan(_:)))
        pinch.addTarget(self, action: #selector(onPinch(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        pinch.delegate = self
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
    }

    /// Встроенное вращение камеры ждёт, не тащат ли мебель
    private func chainGestures() {
        for g in view.gestureRecognizers ?? [] where g !== tap && g !== pan && g !== pinch {
            if g is UIPanGestureRecognizer { g.require(toFail: pan) }
        }
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        if engMode == .tile {
            tileTap(at: g.location(in: view))
            return
        }
        if engMode != .off {
            engTap(at: g.location(in: view))
            return
        }
        // комната «как есть» — только посмотреть
        if bare { return }
        select(hitPick(at: g.location(in: view)))
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: view)
        switch g.state {
        case .began:
            if let j = dragCustom, j < customNodes.count, let hit = floorPoint(p) {
                let pos = customNodes[j].simdPosition
                dragOffset = SIMD2(pos.x, pos.z) - hit
            } else if let j = dragIndex, j < addedNodes.count, let hit = floorPoint(p) {
                let pos = addedNodes[j].simdPosition
                dragOffset = SIMD2(pos.x, pos.z) - hit
            } else {
                dragIndex = nil
                lookStart = (yaw, pitch)
            }
        case .changed:
            if let j = dragCustom, j < customNodes.count, tiling.pieces.indices.contains(j) {
                guard let hit = floorPoint(p) else { return }
                let c = tiling.pieces[j]
                let q = hit + dragOffset
                let pos = customNodes[j].simdPosition
                let old = SIMD2(pos.x, pos.z)
                let fits = { (x: SIMD2<Float>) in self.inRoom(x, angle: Float(c.angle), w: Float(c.width), d: Float(c.depth)) }
                let stuck = !fits(old)
                if let next = [q, SIMD2(q.x, old.y), SIMD2(old.x, q.y)].first(where: { fits($0) || (stuck && room.inside($0)) }) {
                    customNodes[j].simdPosition.x = next.x
                    customNodes[j].simdPosition.z = next.y
                }
            } else if let j = dragIndex, j < addedNodes.count, look.added.indices.contains(j) {
                guard let hit = floorPoint(p) else { return }
                let a = look.added[j]
                let q = hit + dragOffset
                let pos = addedNodes[j].simdPosition
                let old = SIMD2(pos.x, pos.z)
                // только целиком в комнате; упёрлись в стену — скользим вдоль неё.
                // Вещь из старого ремонта, которая уже торчит в стене, можно вытащить.
                let stuck = !inRoom(a, at: old)
                let next = [q, SIMD2(q.x, old.y), SIMD2(old.x, q.y)].first {
                    inRoom(a, at: $0) || (stuck && room.inside($0))
                }
                if let next {
                    addedNodes[j].simdPosition.x = next.x
                    addedNodes[j].simdPosition.z = next.y
                }
            } else if inside {
                let t = g.translation(in: view)
                yaw = lookStart.0 + Float(t.x) * 0.005
                pitch = max(-1.0, min(0.7, lookStart.1 + Float(t.y) * 0.004))
                applyRoomCamera()
            }
        default:
            if let j = dragCustom, j < customNodes.count, tiling.pieces.indices.contains(j) {
                let pos = customNodes[j].simdPosition
                tiling.pieces[j].x = Double(pos.x)
                tiling.pieces[j].y = Double(pos.z)
            }
            dragCustom = nil
            if let j = dragIndex, j < addedNodes.count, look.added.indices.contains(j) {
                let pos = addedNodes[j].simdPosition
                edit { l in
                    l.added[j].x = Double(pos.x)
                    l.added[j].y = Double(pos.z)
                }
            }
            dragIndex = nil
        }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        guard inside, let cam = roomCamera.camera else { return }
        if g.state == .began { fovStart = cam.fieldOfView }
        cam.fieldOfView = max(35, min(95, fovStart / max(g.scale, 0.1)))
    }

    /// Точка пола под пальцем
    private func floorPoint(_ p: CGPoint) -> SIMD2<Float>? {
        let a = view.unprojectPoint(SCNVector3(Float(p.x), Float(p.y), 0))
        let b = view.unprojectPoint(SCNVector3(Float(p.x), Float(p.y), 1))
        let dy = b.y - a.y
        guard abs(dy) > 1e-5 else { return nil }
        let t = -a.y / dy
        guard t > 0 else { return nil }
        return SIMD2(a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t)
    }
}

extension RenoEditor: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === pinch { return inside }
        if g === pan {
            // тащить можно только выбранную добавленную мебель
            dragIndex = nil
            dragCustom = nil
            if case .added(let j)? = pick, case .added(let hit)? = hitPick(at: g.location(in: view)), hit == j {
                dragIndex = j
                return true
            }
            if case .custom(let j)? = pick, case .custom(let hit)? = hitPick(at: g.location(in: view)), hit == j {
                dragCustom = j
                return true
            }
            return inside
        }
        return true
    }
}
