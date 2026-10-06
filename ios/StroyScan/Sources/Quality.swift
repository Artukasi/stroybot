import Foundation
import RoomPlan
import simd

/// Проверка скана: где RoomPlan не уверен, какие углы не сомкнулись, что не нашлось.
/// Подсказки короткие и по-русски: их читает человек с телефоном в руке.
extension RoomResult {
    static let maxIssues = 10
    static let maxIssueLength = 120

    /// Разбор готового скана (после «Готово») по выпрямленным стенам
    static func check(_ captured: CapturedRoom, _ r: RoomResult, _ rect: Rectify.Result,
                      _ toPlan: (SIMD2<Double>) -> SIMD2<Double>) -> Quality {
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

        // стены и куски стен, в которых RoomPlan не уверен
        for (i, wall) in rect.walls.enumerated() where i < n {
            switch wall.conf {
            case 0:
                q.weakWalls.insert(i)
                found.append((1, "\(name(i).capitalizedFirst): снята неуверенно — пройдите вдоль неё ещё раз, медленно."))
                penalty += 12
            case 1:
                penalty += 3
            default:
                for p in wall.pieces where p.conf == 0 { q.marks.append([toPlan(p.a), toPlan(p.b)]) }
            }
        }

        // углы, которые не удалось сомкнуть, и неснятые куски — жёлтым пунктиром на плане
        for g in rect.gaps {
            q.marks.append(g.path.map(toPlan))
            let a = g.wallA + 1, b = g.wallB + 1
            let m = fmt((g.length * 10).rounded() / 10)
            switch g.kind {
            case .corner where g.wallB >= 0:
                q.weakWalls.formUnion([g.wallA, g.wallB])
                found.append((1, "Угол между стенами \(a) и \(b) не сомкнулся — доснимите его (жёлтый пунктир на плане)."))
                penalty += 10
            case .missing where g.wallB >= 0:
                q.weakWalls.formUnion([g.wallA, g.wallB])
                found.append((1, "Между стенами \(a) и \(b) не хватает стены (около \(m) м) — доснимите это место."))
                penalty += 15
            case .hole:
                found.append((2, "Стена \(a): кусок около \(m) м не снят — пройдите вдоль неё (жёлтый пунктир)."))
                penalty += 6
            default:
                if g.wallA >= 0 { q.weakWalls.insert(g.wallA) }
                found.append((1, "Край стены \(a) ни с чем не сомкнулся — доснимите угол рядом с ним."))
                penalty += 10
            }
        }
        q.weakWalls = q.weakWalls.filter { $0 >= 0 && $0 < n }

        // высота потолка
        if n >= 3 && (r.height < 2.0 || r.height > 4.5) {
            found.append((1, "Высота потолка вышла \(fmt(r.height)) м — похоже, пол или потолок сняты не полностью. Наведите камеру на пол и на потолок."))
            penalty += 15
        } else if n >= 3 {
            for (i, w) in r.walls.enumerated() where i < rect.walls.count && !rect.walls[i].made && abs(w.height - r.height) > 0.15 {
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

        q.issues = found.enumerated().sorted { $0.element.0 != $1.element.0 ? $0.element.0 < $1.element.0 : $0.offset < $1.offset }
            .prefix(maxIssues).map { String($0.element.1.prefix(maxIssueLength)) }
        q.score = max(0, min(100, 100 - penalty))
        return q
    }

    /// Быстрая проверка во время съёмки: что ещё не снято. where — где ближайший пунктир («справа, 2 м»)
    static func liveIssues(_ room: CapturedRoom, _ rect: Rectify.Result, where place: String? = nil) -> [String] {
        if rect.walls.count < 3 { return ["Пока видно мало стен — медленно обведите камерой всю комнату"] }
        var out: [String] = []
        let unclosed = rect.gaps.filter { $0.kind != .hole }
        if !unclosed.isEmpty {
            if let place {
                out.append("Не все углы сомкнулись — жёлтый пунктир \(place): подойдите и снимите это место")
            } else {
                out.append("Не все углы сомкнулись — подойдите к жёлтому пунктиру и снимите это место")
            }
        }
        let weak = rect.walls.filter { $0.conf == 0 }.count
        if weak > 0 { out.append("Стены сняты неуверенно (\(weak)) — пройдите вдоль жёлтого пунктира ещё раз") }
        if rect.gaps.contains(where: { $0.kind == .hole }) {
            out.append("Кусок стены не снят — пройдите вдоль жёлтого пунктира")
        }
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
