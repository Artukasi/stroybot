import Foundation
import RoomPlan
import simd

/// Стены, проёмы и мебель одного или нескольких сканов одной комнаты.
/// «Доснять» добавляет к прошлому скану новый (в тех же координатах — тот же ARSession):
/// стены идут в подгонку вместе (куски одной стены склеятся, копии уйдут), проёмы и мебель — без повторов.
struct ScanParts {
    var walls: [CapturedRoom.Surface] = []
    var doors: [CapturedRoom.Surface] = []
    var windows: [CapturedRoom.Surface] = []
    var openings: [CapturedRoom.Surface] = []
    var objects: [CapturedRoom.Object] = []
    /// Контур пола от RoomPlan (iOS 17), мировые x, z
    var floorPolygon: [SIMD2<Double>] = []
    /// RoomPlan не нашёл пол (только iOS 17 это знает)
    var floorMissing = false

    init(_ room: CapturedRoom) {
        self.init([room])
    }

    /// Несколько сканов одной комнаты; более свежий — последний: его проёмы и мебель главнее
    init(_ rooms: [CapturedRoom]) {
        for room in rooms {
            walls += room.walls
            doors = ScanParts.merge(doors, room.doors)
            windows = ScanParts.merge(windows, room.windows)
            openings = ScanParts.merge(openings, room.openings)
            objects = ScanParts.merge(objects, room.objects)
        }
        if #available(iOS 17.0, *) {
            floorMissing = rooms.allSatisfy { $0.floors.isEmpty }
            // самый большой контур пола из сканов
            var best: [SIMD2<Double>] = []
            for room in rooms {
                for floor in room.floors where floor.polygonCorners.count > 2 {
                    let pts = floor.polygonCorners.map { c -> SIMD2<Double> in
                        let w = floor.transform * SIMD4<Float>(c.x, c.y, c.z, 1)
                        return SIMD2(Double(w.x), Double(w.z))
                    }
                    if ScanParts.area(pts) > ScanParts.area(best) { best = pts }
                }
            }
            floorPolygon = best
        }
    }

    var isEmpty: Bool { walls.isEmpty }

    /// Тот же проём из нового скана заменяет старый: тот же вид, середина ближе 40 см
    static func merge(_ old: [CapturedRoom.Surface], _ new: [CapturedRoom.Surface]) -> [CapturedRoom.Surface] {
        let kept = old.filter { o in !new.contains { n in near(o.transform, n.transform, 0.4) } }
        return kept + new
    }

    /// Тот же предмет из нового скана заменяет старый: тот же вид, середина ближе 50 см
    static func merge(_ old: [CapturedRoom.Object], _ new: [CapturedRoom.Object]) -> [CapturedRoom.Object] {
        let kept = old.filter { o in !new.contains { n in n.category == o.category && near(o.transform, n.transform, 0.5) } }
        return kept + new
    }

    private static func near(_ a: simd_float4x4, _ b: simd_float4x4, _ meters: Float) -> Bool {
        let pa = SIMD3(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let pb = SIMD3(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        return simd_distance(pa, pb) < meters
    }

    static func area(_ p: [SIMD2<Double>]) -> Double {
        guard p.count > 2 else { return 0 }
        let s = zip(p, p.dropFirst() + [p[0]]).reduce(0.0) { $0 + ($1.0.x * $1.1.y - $1.1.x * $1.0.y) }
        return abs(s) / 2
    }

    /// Новый скан лёг на старый: хотя бы одна его стена совпала со старой (параллельна, ближе 30 см).
    /// Если телефон потерял место (приложение сворачивали), координаты другие — тогда сканы не склеиваем
    static func fits(_ old: [CapturedRoom], _ new: CapturedRoom) -> Bool {
        let before = RoomResult.rawWalls(old.flatMap(\.walls)).filter { simd_distance($0.a, $0.b) > 0.5 }
        let after = RoomResult.rawWalls(new.walls).filter { simd_distance($0.a, $0.b) > 0.5 }
        guard !before.isEmpty, !after.isEmpty else { return false }
        for w in after {
            let mid = (w.a + w.b) / 2
            let dir = simd_normalize(w.b - w.a)
            for o in before {
                let od = simd_normalize(o.b - o.a)
                guard abs(simd_dot(dir, od)) > cos(10 * Rectify.deg) else { continue }
                if Rectify.segDist(mid, o.a, o.b) < 0.3 { return true }
            }
        }
        return false
    }
}
