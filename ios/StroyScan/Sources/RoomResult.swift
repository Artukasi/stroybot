import Foundation
import RoomPlan
import simd

/// Размеры комнаты, посчитанные из скана RoomPlan. Всё в метрах.
struct RoomResult {
    struct Wall { let length: Double; let height: Double }
    struct Opening { let kind: String; let width: Double; let height: Double }

    var room: String = "Комната"
    var walls: [Wall] = []
    var openings: [Opening] = []
    /// Контур пола сверху, повёрнут так, что самая длинная стена идёт по горизонтали
    var plan: [SIMD2<Double>] = []
    var height: Double = 0
    var length: Double = 0
    var width: Double = 0
    var usdz: URL?

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
    var wallArea: Double { max(0, walls.reduce(0) { $0 + $1.length * $1.height } - openingsArea) }
    var windows: Int { openings.filter { $0.kind == "window" }.count }
    var doors: Int { openings.filter { $0.kind == "door" }.count }

    /// JSON для бота (/scan/rooms)
    var payload: [String: Any] {
        let r = { (v: Double) in (v * 1000).rounded() / 1000 }
        return [
            "room": room,
            "sizes": ["length": r(length), "width": r(width), "height": r(height), "perimeter": r(perimeter),
                      "floor_area": r(floorArea), "wall_area": r(wallArea), "openings_area": r(openingsArea)],
            "walls": walls.map { ["length": r($0.length), "height": r($0.height)] },
            "openings": openings.map { ["kind": $0.kind, "width": r($0.width), "height": r($0.height)] as [String: Any] },
            "plan": plan.map { [r($0.x), r($0.y)] },
        ]
    }
}

extension RoomResult {
    init(_ captured: CapturedRoom) {
        walls = captured.walls.map { Wall(length: Double($0.dimensions.x), height: Double($0.dimensions.y)) }
        openings = captured.doors.map { Opening(kind: "door", width: Double($0.dimensions.x), height: Double($0.dimensions.y)) }
            + captured.windows.map { Opening(kind: "window", width: Double($0.dimensions.x), height: Double($0.dimensions.y)) }
            + captured.openings.map { Opening(kind: "opening", width: Double($0.dimensions.x), height: Double($0.dimensions.y)) }
        height = walls.map(\.height).max() ?? 0

        // контур пола: на iOS 17 RoomPlan отдаёт его сам, на iOS 16 собираем из концов стен
        var points: [SIMD2<Double>] = []
        if #available(iOS 17.0, *), let floor = captured.floors.first, floor.polygonCorners.count > 2 {
            points = floor.polygonCorners.map { c in
                let w = floor.transform * SIMD4<Float>(c.x, c.y, c.z, 1)
                return SIMD2(Double(w.x), Double(w.z))
            }
        } else {
            let ends = captured.walls.flatMap { wall -> [SIMD2<Double>] in
                let t = wall.transform
                let center = SIMD2(Double(t.columns.3.x), Double(t.columns.3.z))
                let dir = simd_normalize(SIMD2(Double(t.columns.0.x), Double(t.columns.0.z)))
                let half = Double(wall.dimensions.x) / 2
                return [center - dir * half, center + dir * half]
            }
            points = RoomResult.convexHull(ends)
        }

        // поворачиваем так, чтобы самая длинная стена шла по горизонтали: тогда габариты = длина × ширина
        if let longest = captured.walls.max(by: { $0.dimensions.x < $1.dimensions.x }) {
            let a = atan2(Double(longest.transform.columns.0.z), Double(longest.transform.columns.0.x))
            let c = cos(-a), s = sin(-a)
            points = points.map { SIMD2($0.x * c - $0.y * s, $0.x * s + $0.y * c) }
        }
        if let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
           let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() {
            plan = points.map { SIMD2($0.x - minX, $0.y - minY) }
            length = max(maxX - minX, maxY - minY)
            width = min(maxX - minX, maxY - minY)
        }
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
