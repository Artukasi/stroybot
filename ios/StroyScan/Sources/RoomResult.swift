import Foundation
import RoomPlan
import simd
import UIKit

/// Размеры комнаты, посчитанные из скана RoomPlan. Всё в метрах.
struct RoomResult {
    struct Wall {
        let length: Double
        let height: Double
        /// Площадь окон, дверей и проёмов в этой стене
        var openingsArea: Double = 0
    }
    struct Opening {
        let kind: String
        let width: Double
        let height: Double
        /// Номер стены (с нуля)
        var wall: Int?
        /// От начала стены (wallLines) до середины проёма вдоль стены
        var offset: Double?
        /// Высота низа проёма от пола (у дверей ≈ 0)
        var bottom: Double?
    }
    /// Мебель и техника. x, y, angle — в тех же координатах, что и `plan`.
    struct Item {
        let kind: String
        let width: Double
        let height: Double
        let depth: Double
        let x: Double
        let y: Double
        let angle: Double
        /// Высота низа предмета над полом (телевизор на стене и т.п.)
        var bottom: Double = 0

        var title: String { RoomResult.itemTitle(kind) }
    }
    /// Что стоит доснять
    struct Quality {
        var score = 100
        var issues: [String] = []
        /// Номера стен (с нуля), которые сняты плохо
        var weakWalls: Set<Int> = []
        /// Точки на плане, где стены не сомкнулись
        var gaps: [SIMD2<Double>] = []
    }

    var room: String = "Комната"
    var walls: [Wall] = []
    /// Концы каждой стены на плане: x1, y1, x2, y2 (тот же порядок, что у `walls`)
    var wallLines: [SIMD4<Double>] = []
    var openings: [Opening] = []
    var items: [Item] = []
    /// Контур пола сверху, повёрнут так, что самая длинная стена идёт по горизонтали
    var plan: [SIMD2<Double>] = []
    var height: Double = 0
    var length: Double = 0
    var width: Double = 0
    var usdz: URL?
    /// Фото комнаты (JPEG) для ИИ-ремонта
    var photo: Data?
    var quality = Quality()

    var perimeter: Double {
        guard plan.count > 2 else { return walls.reduce(0) { $0 + $1.length } }
        return zip(plan, plan.dropFirst() + [plan[0]]).reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }
    var floorArea: Double {
        guard plan.count > 2 else { return length * width }
        let s = zip(plan, plan.dropFirst() + [plan[0]]).reduce(0.0) { $0 + ($1.0.x * $1.1.y - $1.1.x * $1.0.y) }
        return abs(s) / 2
    }
    var openingsArea: Double { openings.reduce(0) { $0 + $1.width * $1.height } }
    var wallArea: Double {
        let gross = walls.reduce(0.0) { $0 + $1.length * $1.height }
        return max(0, gross - openingsArea)
    }
    var windows: Int { openings.filter { $0.kind == "window" }.count }
    var doors: Int { openings.filter { $0.kind == "door" }.count }
    /// Плинтус: периметр минус ширина дверей и проёмов
    var skirting: Double {
        let gaps = openings.filter { $0.kind != "window" }.reduce(0.0) { $0 + $1.width }
        return max(0, perimeter - gaps)
    }
    /// Откосы окон, погонные метры: две боковины и верх у каждого окна
    var slopes: Double {
        openings.filter { $0.kind == "window" }.reduce(0.0) { $0 + 2 * $1.height + $1.width }
    }

    /// JSON для бота (/scan/rooms) и файла скана, версия 2
    var payload: [String: Any] {
        let r = { (v: Double) in (v * 1000).rounded() / 1000 }
        var sizes: [String: Double] = [:]
        sizes["length"] = r(length)
        sizes["width"] = r(width)
        sizes["height"] = r(height)
        sizes["perimeter"] = r(perimeter)
        sizes["floor_area"] = r(floorArea)
        sizes["wall_area"] = r(wallArea)
        sizes["openings_area"] = r(openingsArea)
        sizes["skirting"] = r(skirting)
        sizes["slopes"] = r(slopes)

        let wallsJSON: [[String: Double]] = walls.map { w in
            ["length": r(w.length), "height": r(w.height), "openings_area": r(w.openingsArea)]
        }
        let linesJSON: [[Double]] = wallLines.map { [r($0.x), r($0.y), r($0.z), r($0.w)] }
        let openingsJSON: [[String: Any]] = openings.map { o in
            var d: [String: Any] = ["kind": o.kind, "width": r(o.width), "height": r(o.height)]
            if let w = o.wall { d["wall"] = w } else { d["wall"] = NSNull() }
            if let v = o.offset { d["offset"] = r(v) } else { d["offset"] = NSNull() }
            if let v = o.bottom { d["bottom"] = r(v) } else { d["bottom"] = NSNull() }
            return d
        }
        let planJSON: [[Double]] = plan.map { [r($0.x), r($0.y)] }
        let objectsJSON: [[String: Any]] = items.map { i in
            var d: [String: Any] = ["kind": i.kind]
            d["width"] = r(i.width)
            d["depth"] = r(i.depth)
            d["height"] = r(i.height)
            d["x"] = r(i.x)
            d["y"] = r(i.y)
            d["angle"] = r(i.angle)
            return d
        }
        let qualityJSON: [String: Any] = ["score": quality.score, "issues": quality.issues]
        var out: [String: Any] = [:]
        out["format"] = "stroyscan"
        out["version"] = 2
        out["room"] = room
        out["sizes"] = sizes
        out["walls"] = wallsJSON
        out["wall_lines"] = linesJSON
        out["openings"] = openingsJSON
        out["plan"] = planJSON
        out["objects"] = objectsJSON
        out["quality"] = qualityJSON
        if let photo { out["photo"] = photo.base64EncodedString() }
        return out
    }

    /// Файл «<комната>.stroyscan.json»: его можно прислать в чат бота
    func exportFile(look: Look?) -> URL? {
        var data = payload
        if let look { data["look"] = look.json }
        guard let json = try? JSONSerialization.data(withJSONObject: data) else { return nil }
        let name = room.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).stroyscan.json")
        try? FileManager.default.removeItem(at: url)
        do {
            try json.write(to: url)
        } catch {
            return nil
        }
        return url
    }

    static func itemTitle(_ kind: String) -> String {
        switch kind {
        case "bathtub": return "Ванна"
        case "bed": return "Кровать"
        case "chair": return "Стул"
        case "dishwasher": return "Посудомойка"
        case "fireplace": return "Камин"
        case "oven": return "Духовка"
        case "refrigerator": return "Холодильник"
        case "sink": return "Раковина"
        case "sofa": return "Диван"
        case "stairs": return "Лестница"
        case "storage": return "Шкаф / тумба"
        case "stove": return "Плита"
        case "table": return "Стол"
        case "television": return "Телевизор"
        case "toilet": return "Унитаз"
        case "washerDryer": return "Стиральная машина"
        default: return "Предмет"
        }
    }

    static func kind(of category: CapturedRoom.Object.Category) -> String {
        switch category {
        case .bathtub: return "bathtub"
        case .bed: return "bed"
        case .chair: return "chair"
        case .dishwasher: return "dishwasher"
        case .fireplace: return "fireplace"
        case .oven: return "oven"
        case .refrigerator: return "refrigerator"
        case .sink: return "sink"
        case .sofa: return "sofa"
        case .stairs: return "stairs"
        case .storage: return "storage"
        case .stove: return "stove"
        case .table: return "table"
        case .television: return "television"
        case .toilet: return "toilet"
        case .washerDryer: return "washerDryer"
        default: return "object"
        }
    }

    /// Уменьшает фото (длинная сторона ≤ 1600 px) и сжимает в JPEG
    static func jpeg(_ image: UIImage) -> Data? {
        let side = max(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        let k = min(1, 1600 / side)
        let size = CGSize(width: (image.size.width * k).rounded(), height: (image.size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return small.jpegData(compressionQuality: 0.8)
    }

    /// Кадр камеры ARKit → JPEG (телефон держат вертикально)
    static func jpeg(from buffer: CVPixelBuffer) -> Data? {
        let ci = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        let image = UIImage(cgImage: cg, scale: 1, orientation: .right)
        return jpeg(image)
    }
}

private func center3(_ t: simd_float4x4) -> SIMD3<Float> {
    SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
}

/// Расстояние от точки до стены (отрезок по полу + разница по высоте)
private func distance(_ p: SIMD3<Float>, toWall wall: CapturedRoom.Surface) -> Float {
    let t = wall.transform
    let c = center3(t)
    let dir = simd_normalize(SIMD3(t.columns.0.x, t.columns.0.y, t.columns.0.z))
    let half = wall.dimensions.x / 2
    let along = max(-half, min(half, simd_dot(p - c, dir)))
    let nearest = c + dir * along
    return simd_distance(p, nearest)
}

extension RoomResult {
    init(_ captured: CapturedRoom) {
        let capturedWalls = captured.walls
        walls = capturedWalls.map { Wall(length: Double($0.dimensions.x), height: Double($0.dimensions.y)) }

        // высота — медиана высот стен: одна «выросшая» стена не портит результат
        let heights = walls.map(\.height).sorted()
        if !heights.isEmpty {
            let mid = heights.count / 2
            height = heights.count % 2 == 1 ? heights[mid] : (heights[mid - 1] + heights[mid]) / 2
        }
        // уровень пола — низ самой низкой стены
        let floorY = capturedWalls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min() ?? 0

        // контур пола: на iOS 17 RoomPlan отдаёт его сам, на iOS 16 собираем из концов стен
        var points: [SIMD2<Double>] = []
        if #available(iOS 17.0, *), let floor = captured.floors.first, floor.polygonCorners.count > 2 {
            points = floor.polygonCorners.map { c in
                let w = floor.transform * SIMD4<Float>(c.x, c.y, c.z, 1)
                return SIMD2(Double(w.x), Double(w.z))
            }
        } else {
            points = RoomResult.convexHull(capturedWalls.flatMap { wall -> [SIMD2<Double>] in
                let e = RoomResult.ends(wall)
                return [e.0, e.1]
            })
        }

        // поворачиваем так, чтобы самая длинная стена шла по горизонтали: тогда габариты = длина × ширина
        var a = 0.0
        if let longest = capturedWalls.max(by: { $0.dimensions.x < $1.dimensions.x }) {
            a = atan2(Double(longest.transform.columns.0.z), Double(longest.transform.columns.0.x))
        }
        let c = cos(-a), s = sin(-a)
        let rotate = { (p: SIMD2<Double>) -> SIMD2<Double> in SIMD2(p.x * c - p.y * s, p.x * s + p.y * c) }
        points = points.map(rotate)
        var shift = SIMD2<Double>(0, 0)
        if let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
           let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() {
            shift = SIMD2(minX, minY)
            plan = points.map { $0 - shift }
            length = max(maxX - minX, maxY - minY)
            width = min(maxX - minX, maxY - minY)
        }
        let toPlan = { (p: SIMD2<Double>) -> SIMD2<Double> in rotate(p) - shift }

        // стены на плане: два конца в тех же координатах, что и контур пола
        wallLines = capturedWalls.map { wall in
            let e = RoomResult.ends(wall)
            let p = toPlan(e.0), q = toPlan(e.1)
            return SIMD4(p.x, p.y, q.x, q.y)
        }

        // проёмы: к какой стене, где по длине и на какой высоте
        var surfaces: [(String, CapturedRoom.Surface)] = []
        surfaces += captured.doors.map { ("door", $0) }
        surfaces += captured.windows.map { ("window", $0) }
        surfaces += captured.openings.map { ("opening", $0) }
        for (kind, surface) in surfaces {
            let w = Double(surface.dimensions.x), h = Double(surface.dimensions.y)
            var o = Opening(kind: kind, width: w, height: h)
            if let i = RoomResult.wallIndex(for: surface, in: capturedWalls) {
                walls[i].openingsArea += w * h
                let line = wallLines[i]
                let start = SIMD2(line.x, line.y), end = SIMD2(line.z, line.w)
                let len = simd_distance(start, end)
                let t = surface.transform
                let center = toPlan(SIMD2(Double(t.columns.3.x), Double(t.columns.3.z)))
                o.wall = i
                o.offset = len > 0 ? min(max(simd_dot(center - start, (end - start) / len), 0), len) : 0
                let wt = capturedWalls[i].transform
                let wallBottom = Double(wt.columns.3.y - capturedWalls[i].dimensions.y / 2)
                var bottom = Double(t.columns.3.y) - h / 2 - wallBottom
                if kind != "window" && bottom < 0.12 { bottom = 0 }
                o.bottom = max(0, bottom)
            }
            openings.append(o)
        }

        // мебель в тех же координатах, что и план
        items = captured.objects.map { o in
            let t = o.transform
            let p = toPlan(SIMD2(Double(t.columns.3.x), Double(t.columns.3.z)))
            let angle = atan2(Double(t.columns.0.z), Double(t.columns.0.x)) - a
            let bottom = Double(t.columns.3.y - o.dimensions.y / 2 - floorY)
            return Item(kind: RoomResult.kind(of: o.category),
                        width: Double(o.dimensions.x), height: Double(o.dimensions.y), depth: Double(o.dimensions.z),
                        x: p.x, y: p.y, angle: angle, bottom: bottom < 0.08 ? 0 : bottom)
        }

        quality = RoomResult.check(captured, self)
    }

    /// Концы стены по полу в мировых x, z
    static func ends(_ wall: CapturedRoom.Surface) -> (SIMD2<Double>, SIMD2<Double>) {
        let t = wall.transform
        let center = SIMD2(Double(t.columns.3.x), Double(t.columns.3.z))
        var dir = SIMD2(Double(t.columns.0.x), Double(t.columns.0.z))
        dir = simd_length(dir) > 0 ? simd_normalize(dir) : SIMD2(1, 0)
        let half = Double(wall.dimensions.x) / 2
        return (center - dir * half, center + dir * half)
    }

    /// Какой стене принадлежит окно/дверь: на iOS 17 — по parentIdentifier, иначе ближайшая стена
    static func wallIndex(for surface: CapturedRoom.Surface, in walls: [CapturedRoom.Surface]) -> Int? {
        if #available(iOS 17.0, *), let parent = surface.parentIdentifier,
           let i = walls.firstIndex(where: { $0.identifier == parent }) {
            return i
        }
        let p = center3(surface.transform)
        var best: Int?
        var bestDist = Float.greatestFiniteMagnitude
        for (i, w) in walls.enumerated() {
            let d = distance(p, toWall: w)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    /// Выпуклая оболочка точек (алгоритм Эндрю)
    static func convexHull(_ pts: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let p = pts.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count > 2 else { return p }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Double>] = [], upper: [SIMD2<Double>] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}
