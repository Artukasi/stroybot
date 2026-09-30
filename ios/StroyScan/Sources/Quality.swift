import Foundation
import RoomPlan
import simd

/// Проверка скана: где RoomPlan не уверен, какие углы не сомкнулись, что не нашлось.
/// Подсказки короткие и по-русски: их читает человек с телефоном в руке.
extension RoomResult {
    static let maxIssues = 10
    static let maxIssueLength = 120

    /// Разбор готового скана (после «Готово»)
    static func check(_ captured: CapturedRoom, _ r: RoomResult) -> Quality {
        var q = Quality()
        var found: [(Int, String)] = []     // (важность, текст)
        var penalty = 0
        let lines = r.wallLines
        let n = lines.count
        let segs = lines.map { (SIMD2($0.x, $0.y), SIMD2($0.z, $0.w)) }

        // где стена на плане — чтобы человек нашёл её глазами
        let maxX = max(r.plan.map(\.x).max() ?? 1, 0.1), maxY = max(r.plan.map(\.y).max() ?? 1, 0.1)
        func name(_ i: Int) -> String {
            guard i < n else { return "стена \(i + 1)" }
            let m = (segs[i].0 + segs[i].1) / 2
            let dx = (m.x - maxX / 2) / maxX, dy = (m.y - maxY / 2) / maxY
            let side: String
            if abs(dx) > abs(dy) { side = dx < 0 ? "слева" : "справа" } else { side = dy < 0 ? "сверху" : "снизу" }
            return "стена \(i + 1) (\(side) на плане)"
        }

        if n < 3 {
            found.append((0, "Найдено стен: \(n). Обойдите комнату и снимите все стены целиком."))
            penalty += 40
        }

        // стены, в которых RoomPlan не уверен
        for (i, wall) in captured.walls.enumerated() where i < n {
            switch wall.confidence {
            case .low:
                q.weakWalls.insert(i)
                found.append((1, "\(name(i).capitalizedFirst): снята неуверенно — пройдите вдоль неё ещё раз, медленно."))
                penalty += 12
            case .medium:
                penalty += 3
            default:
                break
            }
        }

        // углы: конец стены должен упираться в соседнюю стену
        if n >= 2 {
            var pairs = Set<String>()
            for i in 0..<n {
                for end in [segs[i].0, segs[i].1] {
                    var best = Double.greatestFiniteMagnitude, bestJ = -1
                    var point = end
                    for j in 0..<n where j != i {
                        let (d, p) = segmentDistance(end, segs[j].0, segs[j].1)
                        if d < best { best = d; bestJ = j; point = p }
                    }
                    guard best > 0.3, bestJ >= 0 else { continue }
                    let key = "\(min(i, bestJ))-\(max(i, bestJ))"
                    guard !pairs.contains(key) else { continue }
                    pairs.insert(key)
                    q.weakWalls.insert(i)
                    q.gaps.append((end + point) / 2)
                    if best < 2.5 {
                        q.weakWalls.insert(bestJ)
                        found.append((1, "Угол между стенами \(min(i, bestJ) + 1) и \(max(i, bestJ) + 1) не досканирован — снимите его ближе."))
                    } else {
                        found.append((1, "Край стены \(i + 1) ни с чем не сомкнулся — доснимите угол рядом с ним."))
                    }
                    penalty += 10
                }
            }
        }

        // высота потолка
        if n >= 3 && (r.height < 2.0 || r.height > 4.5) {
            found.append((1, "Высота потолка вышла \(fmt(r.height)) м — похоже, пол или потолок сняты не полностью. Наведите камеру на пол и на потолок."))
            penalty += 15
        } else if n >= 3 {
            for (i, w) in r.walls.enumerated() where i < n && abs(w.height - r.height) > 0.15 {
                let cm = Int((abs(w.height - r.height) * 100).rounded())
                q.weakWalls.insert(i)
                found.append((2, "\(name(i).capitalizedFirst) \(w.height < r.height ? "ниже" : "выше") остальных на \(cm) см — доснимите её от пола до потолка."))
                penalty += 6
            }
        }

        if #available(iOS 17.0, *), captured.floors.isEmpty, n >= 3 {
            found.append((2, "Пол не найден — медленно проведите камерой по полу всей комнаты."))
            penalty += 10
        }
        if n >= 3 && r.floorArea < 1.5 {
            found.append((1, "Площадь пола вышла очень маленькой — пройдите по всей комнате."))
            penalty += 20
        }

        // окна и двери
        if n >= 3 && captured.doors.isEmpty && captured.openings.isEmpty {
            found.append((3, "Не нашёл дверь — снимите вход в комнату целиком, вместе с проёмом."))
            penalty += 5
        }
        // (название, «на нём/ней», «снят/снята/снято») — порядок как в RoomResult.openings
        var surfaces: [(String, String, String, CapturedRoom.Surface)] = []
        surfaces += captured.doors.map { ("Дверь", "ней", "снята", $0) }
        surfaces += captured.windows.map { ("Окно", "нём", "снято", $0) }
        surfaces += captured.openings.map { ("Проём", "нём", "снят", $0) }
        for (k, s) in surfaces.enumerated() where s.3.confidence == .low {
            let wall = k < r.openings.count ? r.openings[k].wall : nil
            let place = wall.map { " на стене \($0 + 1)" } ?? ""
            found.append((3, "\(s.0)\(place) \(s.2) неуверенно — задержите на \(s.1) камеру пару секунд."))
            penalty += 4
        }

        // мебель, которую не обошли
        var seen = Set<String>()
        for o in captured.objects where o.confidence == .low {
            let kind = RoomResult.kind(of: o.category)
            guard !seen.contains(kind) else { continue }
            seen.insert(kind)
            found.append((4, "\(RoomResult.itemTitle(kind)): снято не полностью — обойдите с двух сторон."))
            penalty += 3
        }

        q.issues = found.sorted { $0.0 < $1.0 }.prefix(maxIssues).map { String($0.1.prefix(maxIssueLength)) }
        q.score = max(0, min(100, 100 - penalty))
        return q
    }

    /// Быстрая проверка во время съёмки: что ещё не снято
    static func liveIssues(_ room: CapturedRoom) -> [String] {
        let walls = room.walls
        if walls.count < 3 { return ["Пока видно мало стен — медленно обведите камерой всю комнату"] }
        var out: [String] = []
        let weak = walls.filter { $0.confidence == .low }.count
        if weak > 0 { out.append("Стены сняты неуверенно (\(weak)) — пройдите вдоль них ещё раз") }
        let segs = walls.map { RoomResult.ends($0) }
        var open = 0
        for (i, s) in segs.enumerated() {
            for end in [s.0, s.1] {
                var best = Double.greatestFiniteMagnitude
                for (j, t) in segs.enumerated() where j != i {
                    best = min(best, segmentDistance(end, t.0, t.1).0)
                }
                if best > 0.5 { open += 1 }
            }
        }
        if open > 0 { out.append("Не все углы сомкнулись — подойдите и снимите углы комнаты") }
        if room.doors.isEmpty && room.openings.isEmpty { out.append("Не видно двери — снимите вход в комнату целиком") }
        if room.objects.contains(where: { $0.confidence == .low }) {
            out.append("Мебель снята не полностью — обойдите её с двух сторон")
        }
        return out
    }

    /// Расстояние от точки до отрезка и ближайшая точка на нём
    static func segmentDistance(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> (Double, SIMD2<Double>) {
        let ab = b - a
        let len2 = simd_dot(ab, ab)
        let t = len2 > 0 ? max(0, min(1, simd_dot(p - a, ab) / len2)) : 0
        let q = a + ab * t
        return (simd_distance(p, q), q)
    }
}

extension String {
    /// «стена 2» → «Стена 2»
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
