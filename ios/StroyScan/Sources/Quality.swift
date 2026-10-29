import Foundation
import RoomPlan
import simd

/// Проверка скана: где RoomPlan не уверен, какие углы не сомкнулись, что не нашлось.
/// Подсказки короткие и по-русски: их читает человек с телефоном в руке.
/// Места «доснять» одни и те же: в подсказке во время скана и в списке после него.
extension RoomResult {
    static let maxIssues = 10
    static let maxIssueLength = 120

    /// Разбор готового скана (после «Готово») по выпрямленным стенам без копий
    static func check(_ captured: ScanParts, _ r: RoomResult, _ rect: Rectify.Result) -> Quality {
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

        // стены и куски стен, которые RoomPlan толком не видел
        for (i, wall) in rect.walls.enumerated() where i < n {
            if wall.made {
                q.weakWalls.insert(i)
                let cm = Int((wall.length * 100).rounded())
                found.append((1, "Стена \(i + 1): уступ около \(cm) см не снят, его дорисовали — доснимите это место."))
                penalty += 6
                continue
            }
            if wall.conf == 0 {
                q.weakWalls.insert(i)
                found.append((1, "\(name(i).capitalizedFirst): снята неуверенно — пройдите вдоль неё ещё раз, медленно."))
                penalty += 12
                continue
            }
            if wall.conf == 1 { penalty += 3 }
            let unsure = rect.unsureSpans(i)
            if !unsure.isEmpty {
                q.weakWalls.insert(i)
                let m = fmt((unsure.reduce(0) { $0 + simd_distance($1.0, $1.1) } * 10).rounded() / 10)
                found.append((2, "Стена \(i + 1): кусок около \(m) м снят неуверенно — пройдите вдоль неё ещё раз."))
                penalty += 3
            }
        }

        // углы, которые не удалось сомкнуть, неснятые куски, двойные стены
        for g in rect.gaps {
            let a = g.wallA + 1, b = g.wallB + 1
            let m = fmt((g.length * 10).rounded() / 10)
            switch g.kind {
            case .corner where g.wallB >= 0:
                q.weakWalls.formUnion([g.wallA, g.wallB])
                found.append((1, "Угол между стенами \(a) и \(b) не сомкнулся — доснимите его."))
                penalty += 10
            case .missing where g.wallB >= 0:
                q.weakWalls.formUnion([g.wallA, g.wallB])
                found.append((1, "Между стенами \(a) и \(b) не хватает стены (около \(m) м) — доснимите это место."))
                penalty += 15
            case .hole:
                q.weakWalls.insert(g.wallA)
                found.append((2, "Стена \(a): кусок около \(m) м не снят — пройдите вдоль неё."))
                penalty += 6
            case .double:
                q.weakWalls.insert(g.wallA)
                found.append((1, "Стена \(a) двоится — переснимите её медленно."))
                penalty += 10
            default:
                if g.wallA >= 0 { q.weakWalls.insert(g.wallA) }
                found.append((1, "Край стены \(a) ни с чем не сомкнулся — доснимите угол рядом с ним."))
                penalty += 10
            }
        }

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
        q.weakWalls = q.weakWalls.filter { $0 >= 0 && $0 < n }

        if captured.floorMissing, n >= 3 {
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

    /// Место «доснять» во время скана: что не так и где (ломаная по полу, мировые x, z)
    struct LiveMark {
        enum Kind { case corner, missing, end, hole, double, unsure, step }
        let kind: Kind
        let path: [SIMD2<Double>]

        /// Коротко — для подсказки над камерой
        var text: String {
            switch kind {
            case .corner: return "Угол не сомкнулся"
            case .missing: return "Не хватает стены"
            case .end: return "Угол не снят"
            case .hole: return "Кусок стены не снят"
            case .double: return "Стена двоится"
            case .unsure: return "Стена снята неуверенно"
            case .step: return "Уступ стены не снят"
            }
        }

        /// Пока комнату обходят, открытый конец и пропущенная стена — просто ещё не снятое
        var inProgress: Bool { kind == .end || kind == .missing }
    }

    /// Все места «доснять» живого скана — по свежей подгонке
    static func liveMarks(_ rect: Rectify.Result) -> [LiveMark] {
        var out: [LiveMark] = []
        for g in rect.gaps {
            let kind: LiveMark.Kind
            switch g.kind {
            case .corner: kind = .corner
            case .missing: kind = .missing
            case .end: kind = .end
            case .hole: kind = .hole
            case .double: kind = .double
            }
            out.append(LiveMark(kind: kind, path: g.path))
        }
        let copies = rect.copies
        for (i, w) in rect.walls.enumerated() where copies[i] == nil {
            if w.made {
                out.append(LiveMark(kind: .step, path: [w.a, w.b]))
            } else if w.conf == 0 {
                out.append(LiveMark(kind: .unsure, path: [w.a, w.b]))
            } else {
                for (a, b) in rect.unsureSpans(i) { out.append(LiveMark(kind: .unsure, path: [a, b])) }
            }
        }
        return out
    }

    /// Чего ещё не видно, кроме мест «доснять»
    static func liveExtras(_ room: ScanParts) -> [String] {
        var out: [String] = []
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

/// Что из подгонки считать местами «доснять» (те же правила во время скана и после него)
extension Rectify.Result {
    /// Копии стен («двоится») → стена, которую повторяет копия. Копию не рисуем и в размеры не берём
    var copies: [Int: Int] {
        var out: [Int: Int] = [:]
        for g in gaps where g.kind == .double && g.wallA >= 0 { out[g.wallA] = g.wallB }
        return out
    }

    /// Сколько стен на самом деле: без копий и дорисованных уступов
    var wallCount: Int {
        let cp = copies
        return walls.indices.filter { cp[$0] == nil && !walls[$0].made }.count
    }

    /// Неснятые промежутки внутри стены i: метры от её начала
    func holes(_ i: Int) -> [(Double, Double)] {
        guard i >= 0, i < walls.count else { return [] }
        let w = walls[i]
        let len = w.length
        guard len > 0 else { return [] }
        let dir = (w.b - w.a) / len
        return gaps.filter { $0.kind == .hole && $0.wallA == i && $0.path.count == 2 }.map { g in
            let s = simd_dot(g.path[0] - w.a, dir), e = simd_dot(g.path[1] - w.a, dir)
            return (max(0, min(s, e)), min(len, max(s, e)))
        }
    }

    /// Куски стены i, которые RoomPlan видел только неуверенно и не перекрыл уверенными: метры от начала.
    /// Продление до угла и промежуток у двери — не куски, их не трогаем
    func unsure(_ i: Int) -> [(Double, Double)] {
        guard i >= 0, i < walls.count else { return [] }
        let w = walls[i]
        let len = w.length
        guard len > 0 else { return [] }
        let dir = (w.b - w.a) / len
        let spans: [(Double, Double, Int)] = w.pieces.map { p in
            let s = simd_dot(p.a - w.a, dir), e = simd_dot(p.b - w.a, dir)
            return (max(0, min(s, e)), min(len, max(s, e)), p.conf)
        }
        let cuts = Set(spans.flatMap { [$0.0, $0.1] }).sorted()
        var out: [(Double, Double)] = []
        for (t0, t1) in zip(cuts, cuts.dropFirst()) where t1 - t0 > 0.005 {
            let m = (t0 + t1) / 2
            let cover = spans.filter { $0.0 <= m && m <= $0.1 }
            if cover.isEmpty || cover.contains(where: { $0.2 > 0 }) { continue }
            if let last = out.last, abs(last.1 - t0) < 1e-9 {
                out[out.count - 1] = (last.0, t1)
            } else {
                out.append((t0, t1))
            }
        }
        return out.filter { $0.1 - $0.0 > 0.02 }
    }

    /// То же — точками по полу
    func unsureSpans(_ i: Int) -> [(SIMD2<Double>, SIMD2<Double>)] {
        guard i >= 0, i < walls.count else { return [] }
        let w = walls[i]
        let len = w.length
        guard len > 0 else { return [] }
        let dir = (w.b - w.a) / len
        return unsure(i).map { (w.a + dir * $0.0, w.a + dir * $0.1) }
    }

    /// Без копий: копия — та же стена, в размеры не идёт; её «двоится» относится к стене, которую она повторяет
    func withoutCopies() -> Rectify.Result {
        let cp = copies
        guard !cp.isEmpty else { return self }
        var map = Array(repeating: -1, count: walls.count)
        var next = 0
        for i in walls.indices where cp[i] == nil {
            map[i] = next
            next += 1
        }
        func to(_ i: Int) -> Int {
            guard i >= 0, i < map.count else { return -1 }
            if map[i] >= 0 { return map[i] }
            if let j = cp[i], j >= 0, j < map.count { return map[j] }
            return -1
        }
        var r = self
        r.walls = walls.indices.filter { cp[$0] == nil }.map { walls[$0] }
        r.rawToWall = rawToWall.map(to)
        r.gaps = gaps.map { g in
            var g = g
            g.wallA = to(g.wallA)
            g.wallB = g.kind == .double ? -1 : to(g.wallB)
            if g.wallA >= 0 && g.wallB >= 0 && g.wallA > g.wallB { (g.wallA, g.wallB) = (g.wallB, g.wallA) }
            return g
        }
        return r
    }
}

extension String {
    /// «стена 2» → «Стена 2»
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
    /// «Угол не сомкнулся» → «угол не сомкнулся»
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
