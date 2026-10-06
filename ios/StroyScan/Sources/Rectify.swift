import Foundation
import simd

/// «Подгонка» стен по полу (x, z): прямые углы, куски одной стены — в одну, углы сомкнуты,
/// что сомкнуть нельзя — список мест «доснять». Чистая геометрия, без RoomPlan:
/// работает и вживую во время скана, и для итоговых размеров. Если подгонка портит комнату —
/// отдаём скан как есть. Тот же алгоритм с теми же числами проверен на модели (snapsim/rectify.py).
enum Rectify {
    // MARK: - Постоянные (метры, радианы)

    static let deg = Double.pi / 180
    static let quarter = Double.pi / 2

    static let snap = 8 * deg            // насколько стена может отклоняться от сетки, чтобы её выпрямить
    static let refineWindow = 10 * deg   // стены ближе к грубой сетке уточняют её
    static let keep = 0.5 * deg          // сетка не дёргается между кадрами
    static let followZone = 5 * deg      // меньше — сетка догоняет наполовину, больше — прыгает сразу
    static let follow = 0.5
    static let mergeOff = 0.10           // одна стена: линии так близко…
    static let bridgeGap = 1.0           // …и концы так близко (промежуток — «не снято»)
    static let mergeAng = 12 * deg       // куски одной косой стены
    static let doubleOff = 0.25          // двойная стена: дальше, но перекрываются
    static let doubleMin = 0.30
    static let doubleShare = 0.5
    static let openGap = 2.5             // дверь или проём может перекрыть промежуток побольше
    static let openPerp = 0.30
    static let openTol = 0.15
    static let holeMin = 0.25            // неснятый кусок внутри стены, который стоит показать
    static let join = 0.50               // насколько можно продлить или обрезать стену до угла
    static let minCorner = 25 * deg
    static let tPenalty = 0.05
    static let trimMax = 0.6             // никогда не отрезаем больше этой доли стены
    static let trimShare = 0.3           // отрезать больше этой доли — только когда других углов нет
    static let minWall = 0.10
    static let stepMax = 0.35            // параллельные стены так близко — соединяем короткой стеной
    static let stepAlign = 0.30
    static let gapMax = 10.0
    static let cornerGap = 1.0
    static let cornerExt = 2.0           // открытый угол рисуем через сам угол, если он так близко
    static let stub = 0.6
    static let maxMove = 0.5             // проверка: концы стен остаются рядом со сканом
    static let lost = 0.35               // проверка: каждая снятая стена рядом с выпрямленной
    static let areaTol = 0.15
    static let rawClosed = 0.30
    static let cover = 0.85
    static let confWeight: [Double] = [0.5, 0.8, 1.0]
    static let dirTrust = 0.25           // своё направление куска против того, где его середина

    // MARK: - Данные

    /// Стена из скана: концы по полу, высота, низ, уверенность (0 — низкая, 1 — средняя, 2 — высокая)
    struct Wall {
        var a: SIMD2<Double>
        var b: SIMD2<Double>
        var height: Double = 2.6
        var bottom: Double = 0
        var conf: Int = 2
        /// Сняты ли верхний и нижний край
        var top = true
        var bot = true
    }

    struct Opening {
        var center: SIMD2<Double>
        var width: Double
    }

    struct Piece {
        var s0: Double
        var s1: Double
        var conf: Int
        var top: Bool
        var bot: Bool
    }

    /// Кусок выпрямленной стены, который RoomPlan видел (с его уверенностью)
    struct OutPiece {
        var a: SIMD2<Double>
        var b: SIMD2<Double>
        var conf: Int
        var top: Bool
        var bot: Bool
    }

    struct OutWall {
        var a: SIMD2<Double>
        var b: SIMD2<Double>
        var height: Double
        var bottom: Double
        var conf: Int
        /// Номера стен скана, из которых собрана эта
        var src: [Int]
        var pieces: [OutPiece]
        /// Концы, которые ни во что не упёрлись
        var openA: Bool
        var openB: Bool
        /// Короткая стена, которую дорисовали между параллельными
        var made: Bool
        var angled: Bool
        var length: Double { simd_distance(a, b) }
    }

    enum Kind { case corner, missing, end, hole }

    /// Где доснять: ломаная по полу (жёлтый пунктир) и между какими стенами (-1 — нет)
    struct Gap {
        var path: [SIMD2<Double>]
        var wallA: Int
        var wallB: Int
        var kind: Kind
        var length: Double { zip(path, path.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) } }
    }

    struct Result {
        var angle: Double
        var walls: [OutWall] = []
        var rawToWall: [Int] = []
        var gaps: [Gap] = []
        /// Контур пола по выпрямленным стенам (пусто, если стены не замкнулись)
        var loop: [SIMD2<Double>] = []
        /// false — подгонка не удалась, это скан как есть
        var ok = true
    }

    /// Стена в повёрнутой системе (сетка по осям): точки u*s + n*o, s от s0 до s1
    private struct Line {
        var u: SIMD2<Double>
        var n: SIMD2<Double>
        var o: Double
        var s0: Double
        var s1: Double
        /// 0 / 1 — по сетке, -1 — косая
        var axis: Int
        var height: Double
        var bottom: Double
        var conf: Int
        var src: [Int]
        var pieces: [Piece]
        /// Та же стена до выпрямления
        var ra: SIMD2<Double>
        var rb: SIMD2<Double>
        var made = false

        var length: Double { s1 - s0 }
        func at(_ s: Double) -> SIMD2<Double> { u * s + n * o }
        func end(_ e: Int) -> SIMD2<Double> { at(e == 1 ? s1 : s0) }
        func out(_ e: Int) -> SIMD2<Double> { e == 1 ? u : -u }
        var mid: SIMD2<Double> { at((s0 + s1) / 2) }
    }

    private struct End: Hashable {
        let wall: Int
        let e: Int
    }

    private struct PairedGap {
        let a: End
        let b: End?
        let path: [SIMD2<Double>]
        let kind: Kind
    }

    // MARK: - Помощники

    static func rot(_ p: SIMD2<Double>, _ ang: Double) -> SIMD2<Double> {
        let c = cos(ang), s = sin(ang)
        return SIMD2(p.x * c - p.y * s, p.x * s + p.y * c)
    }

    /// Угол → (-45°, 45°]
    static func wrap90(_ x: Double) -> Double { x - quarter * (x / quarter + 0.5).rounded(.down) }

    /// Угол линии → [0, π)
    static func canon(_ t: Double) -> Double {
        var th = fmod(t, Double.pi)
        if th < 0 { th += Double.pi }
        if th >= Double.pi { th -= Double.pi }
        return th
    }

    /// Угол между линиями, 0…90°
    static func fold(_ u: SIMD2<Double>, _ v: SIMD2<Double>) -> Double { acos(min(1, abs(simd_dot(u, v)))) }

    static func unit(_ a: SIMD2<Double>) -> SIMD2<Double> {
        let n = simd_length(a)
        return n > 0 ? a / n : SIMD2(1, 0)
    }

    static func segDist(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let l2 = simd_dot(ab, ab)
        let t = l2 > 0 ? max(0, min(1, simd_dot(p - a, ab) / l2)) : 0
        return simd_distance(p, a + ab * t)
    }

    private static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }

    static func area(_ poly: [SIMD2<Double>]) -> Double {
        guard !poly.isEmpty else { return 0 }
        var s = 0.0
        for k in poly.indices { s += cross(poly[k], poly[(k + 1) % poly.count]) }
        return s / 2
    }

    // MARK: - Шаги

    /// Грубая сетка по направлениям стен (по модулю 90°, длинные весят больше)
    private static func dominant(_ raw: [Wall]) -> Double {
        var sx = 0.0, sy = 0.0
        var th: [Double] = [], wt: [Double] = []
        for w in raw {
            let d = w.b - w.a
            let len = simd_length(d)
            let t = atan2(d.y, d.x)
            let k = len >= 0.05 ? len * confWeight[w.conf] : 0
            th.append(t)
            wt.append(k)
            sx += k * cos(4 * t)
            sy += k * sin(4 * t)
        }
        if sx == 0 && sy == 0 { return 0 }
        let phi = atan2(sy, sx) / 4
        var num = 0.0, den = 0.0
        for (t, k) in zip(th, wt) {
            let d = wrap90(t - phi)
            if abs(d) < refineWindow {
                num += k * d
                den += k
            }
        }
        return den > 0 ? wrap90(phi + num / den) : phi
    }

    /// Уточняет сетку по стенам на сетке (наименьшие квадраты): середины кусков вдоль стены
    /// и, с меньшим доверием, их собственное направление
    private static func refine(_ raw: [Wall], _ lines: [Line], _ phi: Double) -> Double {
        var A = 0.0, B = 0.0
        for l in lines where l.axis >= 0 {
            var tw = 0.0
            var c = SIMD2<Double>(0, 0)
            for i in l.src {
                let k = confWeight[raw[i].conf] * simd_distance(raw[i].a, raw[i].b)
                c += rot((raw[i].a + raw[i].b) * 0.5, -phi) * k
                tw += k
            }
            guard tw > 0 else { continue }
            c /= tw
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for i in l.src {
                let len = simd_distance(raw[i].a, raw[i].b)
                let k = confWeight[raw[i].conf] * len
                let d = rot((raw[i].a + raw[i].b) * 0.5, -phi) - c
                let u = unit(rot(raw[i].b - raw[i].a, -phi))
                let q = dirTrust * len * len / 12
                sxx += k * (d.x * d.x + q * u.x * u.x)
                syy += k * (d.y * d.y + q * u.y * u.y)
                sxy += k * (d.x * d.y + q * u.x * u.y)
            }
            let sign = l.axis == 0 ? 1.0 : -1.0
            A += sign * (sxx - syy) / 2
            B += sign * sxy
        }
        guard A > 0 else { return phi }
        let d = atan2(B, A) / 2
        return abs(d) <= snap ? wrap90(phi + d) : phi
    }

    /// Сетка не дёргается между кадрами
    private static func settle(_ phi: Double, _ prev: Double?) -> Double {
        guard let prev else { return phi }
        let d = wrap90(phi - prev)
        if abs(d) < keep { return prev }
        if abs(d) < followZone { return wrap90(prev + follow * d) }
        return phi
    }

    /// Угол линии → (ось, направление): на сетке, если близко к ней
    private static func snapDir(_ t: Double, _ snapOn: Bool) -> (Int, SIMD2<Double>) {
        let th = canon(t)
        let k = (th / quarter + 0.5).rounded(.down)
        if snapOn && abs(th - k * quarter) <= snap {
            let axis = Int(k) % 2
            return (axis, axis == 0 ? SIMD2(1, 0) : SIMD2(0, 1))
        }
        return (-1, SIMD2(cos(th), sin(th)))
    }

    private static func makeLine(_ w: Wall, _ i: Int, _ phi: Double, _ snapOn: Bool) -> Line {
        let a = rot(w.a, -phi), b = rot(w.b, -phi)
        let d = b - a
        let len = simd_length(d)
        let (axis, u) = snapDir(atan2(d.y, d.x), snapOn)
        let n = SIMD2(-u.y, u.x)
        let m = (a + b) * 0.5
        let c = simd_dot(m, u)
        let s0 = c - len / 2, s1 = c + len / 2
        return Line(u: u, n: n, o: simd_dot(m, n), s0: s0, s1: s1, axis: axis, height: w.height, bottom: w.bottom,
                    conf: w.conf, src: [i], pieces: [Piece(s0: s0, s1: s1, conf: w.conf, top: w.top, bot: w.bot)],
                    ra: a, rb: b)
    }

    /// Дверь, окно или проём на линии l перекрывает промежуток g0…g1
    private static func covered(_ l: Line, _ g0: Double, _ g1: Double, _ ops: [(SIMD2<Double>, Double)]) -> Bool {
        for (c, width) in ops {
            if abs(simd_dot(c, l.n) - l.o) >= openPerp { continue }
            let s = simd_dot(c, l.u)
            if s - width / 2 <= g0 + openTol && s + width / 2 >= g1 - openTol { return true }
        }
        return false
    }

    /// B — кусок A: то же направление, на той же линии (считаем от длинной), концы рядом
    private static func mergeable(_ first: Line, _ second: Line, _ ops: [(SIMD2<Double>, Double)]) -> Bool {
        if fold(first.u, second.u) > mergeAng { return false }
        let (A, B) = second.length > first.length ? (second, first) : (first, second)
        let perp = abs(simd_dot(B.mid, A.n) - A.o)
        let p0 = simd_dot(B.end(0), A.u), p1 = simd_dot(B.end(1), A.u)
        let lo = min(p0, p1), hi = max(p0, p1)
        let gap = max(A.s0, lo) - min(A.s1, hi)
        if perp < mergeOff && gap < bridgeGap { return true }
        if perp < doubleOff && -gap >= max(doubleMin, doubleShare * (hi - lo)) { return true }
        if perp < mergeOff && gap < openGap && covered(A, min(A.s1, hi), max(A.s0, lo), ops) { return true }
        return false
    }

    private static func mergeGroup(_ ws: [Line]) -> Line {
        guard ws.count > 1 else { return ws[0] }
        var longest = ws[0]
        for w in ws.dropFirst() where w.length > longest.length { longest = w }
        var weights = ws.map { $0.length * confWeight[$0.conf] }
        var tw = weights.reduce(0, +)
        if tw <= 0 {
            weights = ws.map { _ in 1 }
            tw = Double(ws.count)
        }
        // направление: куски как были (не выпрямленные), потом выпрямляем целиком
        let ref = unit(longest.rb - longest.ra)
        var v = SIMD2<Double>(0, 0)
        for (w, k) in zip(ws, weights) {
            let d = unit(w.rb - w.ra)
            v += (simd_dot(d, ref) >= 0 ? d : -d) * k
        }
        let (axis, u) = snapDir(atan2(v.y, v.x), true)
        let n = SIMD2(-u.y, u.x)
        var o = 0.0
        for (w, k) in zip(ws, weights) { o += k * simd_dot(w.mid, n) }
        o /= tw
        var s0 = Double.greatestFiniteMagnitude, s1 = -Double.greatestFiniteMagnitude
        for w in ws {
            let p = simd_dot(w.end(0), u), q = simd_dot(w.end(1), u)
            s0 = min(s0, min(p, q))
            s1 = max(s1, max(p, q))
        }
        var pieces: [Piece] = []
        for w in ws {
            for p in w.pieces {
                let q0 = simd_dot(w.at(p.s0), u), q1 = simd_dot(w.at(p.s1), u)
                pieces.append(Piece(s0: min(q0, q1), s1: max(q0, q1), conf: p.conf, top: p.top, bot: p.bot))
            }
        }
        let tl = ws.reduce(0.0) { $0 + $1.length }
        let weighted = ws.reduce(0.0) { $0 + $1.length * Double($1.conf) }
        let mean = tl > 0 ? weighted / tl : 2
        let conf = mean < 0.75 ? 0 : (mean < 1.5 ? 1 : 2)
        // та же стена до выпрямления: среднее направление и сдвиг снятых кусков
        var rv = SIMD2<Double>(0, 0)
        for (w, k) in zip(ws, weights) {
            let d = unit(w.rb - w.ra)
            rv += (simd_dot(d, u) >= 0 ? d : -d) * k
        }
        let ru = unit(rv)
        let rn = SIMD2(-ru.y, ru.x)
        var ro = 0.0
        for (w, k) in zip(ws, weights) { ro += k * simd_dot((w.ra + w.rb) * 0.5, rn) }
        ro /= tw
        var rs: [Double] = []
        for w in ws { rs += [simd_dot(w.ra, ru), simd_dot(w.rb, ru)] }
        let ra = ru * (rs.min() ?? 0) + rn * ro, rb = ru * (rs.max() ?? 0) + rn * ro
        let src = ws.flatMap(\.src).sorted()
        return Line(u: u, n: n, o: o, s0: s0, s1: s1, axis: axis, height: longest.height, bottom: longest.bottom,
                    conf: conf, src: src, pieces: pieces, ra: ra, rb: rb)
    }

    private static func merge(_ input: [Line], _ ops: [(SIMD2<Double>, Double)]) -> [Line] {
        var lines = input
        for _ in 0..<4 {
            let n = lines.count
            var parent = Array(0..<n)
            func find(_ x: Int) -> Int {
                var x = x
                while parent[x] != x {
                    parent[x] = parent[parent[x]]
                    x = parent[x]
                }
                return x
            }
            for i in 0..<n {
                for j in (i + 1)..<max(i + 1, n) where mergeable(lines[i], lines[j], ops) {
                    let ri = find(i), rj = find(j)
                    if ri != rj { parent[max(ri, rj)] = min(ri, rj) }
                }
            }
            var groups: [Int: [Int]] = [:]
            for i in 0..<n { groups[find(i), default: []].append(i) }
            if groups.count == n { break }
            lines = groups.keys.sorted().map { r in mergeGroup(groups[r]!.map { lines[$0] }) }
        }
        return lines
    }

    /// Промежутки внутри собранной стены, которые не покрыл ни один кусок
    private static func holes(_ l: Line, _ ops: [(SIMD2<Double>, Double)]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        let ps = l.pieces.map { ($0.s0, $0.s1) }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var reach = l.s0
        for (a, b) in ps {
            if a - reach > holeMin && !covered(l, reach, a, ops) { out.append((reach, a)) }
            reach = max(reach, b)
        }
        return out
    }

    private static func intersect(_ A: Line, _ B: Line) -> SIMD2<Double>? {
        let det = A.n.x * B.n.y - A.n.y * B.n.x
        if abs(det) < 1e-9 { return nil }
        return SIMD2((A.o * B.n.y - A.n.y * B.o) / det, (A.n.x * B.o - A.o * B.n.x) / det)
    }

    /// На сколько конец e уходит наружу, чтобы дойти до s (минус — обрезка)
    private static func ext(_ l: Line, _ e: Int, _ s: Double) -> Double { e == 1 ? s - l.s1 : l.s0 - s }

    private static func okExt(_ l: Line, _ t: Double) -> Bool { -min(join, trimMax * l.length) <= t && t <= join }

    private static func trimCost(_ l: Line, _ t: Double) -> Double { -t > trimShare * l.length ? 1 : 0 }

    private static func setEnd(_ l: inout Line, _ e: Int, _ s: Double) {
        if e == 1 { l.s1 = s } else { l.s0 = s }
    }

    private static func newLen(_ l: Line, _ e: Int, _ s: Double) -> Double { e == 1 ? s - l.s0 : l.s1 - s }

    private struct Corner: Comparable {
        let cost: Double
        let kind: Int        // 0 — угол, 1 — Т-стык
        let i: Int
        let e: Int
        let j: Int
        let f: Int
        let x: SIMD2<Double>

        static func < (a: Corner, b: Corner) -> Bool {
            if a.cost != b.cost { return a.cost < b.cost }
            if a.kind != b.kind { return a.kind < b.kind }
            if a.i != b.i { return a.i < b.i }
            if a.e != b.e { return a.e < b.e }
            if a.j != b.j { return a.j < b.j }
            return a.f < b.f
        }
    }

    /// Углы и Т-стыки: концы продлеваем или обрезаем до пересечения
    private static func closeCorners(_ W: inout [Line], _ link: inout [End: End], _ closed: inout Set<End>) {
        let n = W.count
        var cands: [Corner] = []
        for i in 0..<n {
            for e in 0...1 {
                for j in 0..<n where j != i && fold(W[i].u, W[j].u) >= minCorner {
                    guard let X = intersect(W[i], W[j]) else { continue }
                    let ti = ext(W[i], e, simd_dot(X, W[i].u))
                    guard okExt(W[i], ti) else { continue }
                    let sj = simd_dot(X, W[j].u)
                    if sj - W[j].s0 > join && W[j].s1 - sj > join {
                        cands.append(Corner(cost: abs(ti) + tPenalty + trimCost(W[i], ti), kind: 1, i: i, e: e, j: j, f: -1, x: X))
                        continue
                    }
                    if i > j { continue }
                    for f in 0...1 {
                        let tj = ext(W[j], f, sj)
                        if okExt(W[j], tj) {
                            let cost = abs(ti) + abs(tj) + trimCost(W[i], ti) + trimCost(W[j], tj)
                            cands.append(Corner(cost: cost, kind: 0, i: i, e: e, j: j, f: f, x: X))
                        }
                    }
                }
            }
        }
        cands.sort()
        for c in cands {
            let ei = End(wall: c.i, e: c.e)
            if closed.contains(ei) { continue }
            let si = simd_dot(c.x, W[c.i].u)
            if newLen(W[c.i], c.e, si) < minWall { continue }
            if c.kind == 0 {
                let ej = End(wall: c.j, e: c.f)
                if closed.contains(ej) { continue }
                let sj = simd_dot(c.x, W[c.j].u)
                if newLen(W[c.j], c.f, sj) < minWall { continue }
                setEnd(&W[c.j], c.f, sj)
                closed.insert(ej)
                link[ei] = ej
                link[ej] = ei
            }
            setEnd(&W[c.i], c.e, si)
            closed.insert(ei)
        }
    }

    private struct Step: Comparable {
        let cost: Double
        let i: Int
        let e: Int
        let j: Int
        let f: Int

        static func < (a: Step, b: Step) -> Bool {
            if a.cost != b.cost { return a.cost < b.cost }
            if a.i != b.i { return a.i < b.i }
            if a.e != b.e { return a.e < b.e }
            if a.j != b.j { return a.j < b.j }
            return a.f < b.f
        }
    }

    /// Параллельные стены чуть со сдвигом: соединяем короткой стеной поперёк (выступ, короб)
    private static func closeSteps(_ W: inout [Line], _ link: inout [End: End], _ closed: inout Set<End>) {
        let n = W.count
        var cands: [Step] = []
        for i in 0..<n {
            for e in 0...1 where !closed.contains(End(wall: i, e: e)) {
                for j in (i + 1)..<max(i + 1, n) where fold(W[i].u, W[j].u) <= mergeAng {
                    let perp = abs(simd_dot(W[j].mid, W[i].n) - W[i].o)
                    if perp < mergeOff || perp > stepMax { continue }
                    for f in 0...1 {
                        if closed.contains(End(wall: j, e: f)) || simd_dot(W[i].out(e), W[j].out(f)) > -0.5 { continue }
                        let si = e == 1 ? W[i].s1 : W[i].s0
                        let sj = simd_dot(W[j].end(f), W[i].u)
                        let d = abs(si - sj)
                        if d <= stepAlign { cands.append(Step(cost: d + perp, i: i, e: e, j: j, f: f)) }
                    }
                }
            }
        }
        cands.sort()
        for c in cands {
            let ei = End(wall: c.i, e: c.e), ej = End(wall: c.j, e: c.f)
            if closed.contains(ei) || closed.contains(ej) { continue }
            let si = c.e == 1 ? W[c.i].s1 : W[c.i].s0
            let s = (si + simd_dot(W[c.j].end(c.f), W[c.i].u)) / 2
            let P = W[c.i].at(s)
            let sj = simd_dot(P, W[c.j].u)
            if newLen(W[c.i], c.e, s) < minWall || newLen(W[c.j], c.f, sj) < minWall { continue }
            setEnd(&W[c.i], c.e, s)
            setEnd(&W[c.j], c.f, sj)
            let Q = W[c.j].end(c.f)
            let u: SIMD2<Double>
            let axis: Int
            if W[c.i].axis >= 0 {
                u = W[c.i].axis == 0 ? SIMD2(0, 1) : SIMD2(1, 0)
                axis = 1 - W[c.i].axis
            } else {
                let th = canon(atan2(Q.y - P.y, Q.x - P.x))
                u = SIMD2(cos(th), sin(th))
                axis = -1
            }
            let nn = SIMD2(-u.y, u.x)
            let a = simd_dot(P, u), b = simd_dot(Q, u)
            let k = W.count
            let h = (W[c.i].height + W[c.j].height) / 2
            let bt = (W[c.i].bottom + W[c.j].bottom) / 2
            let lo = min(a, b), hi = max(a, b)
            W.append(Line(u: u, n: nn, o: simd_dot(P, nn), s0: lo, s1: hi, axis: axis, height: h, bottom: bt, conf: 1,
                          src: [], pieces: [Piece(s0: lo, s1: hi, conf: 1, top: true, bot: true)], ra: P, rb: Q, made: true))
            let ep = End(wall: k, e: a <= b ? 0 : 1), eq = End(wall: k, e: a <= b ? 1 : 0)
            link[ei] = ep
            link[ep] = ei
            link[ej] = eq
            link[eq] = ej
            closed.formUnion([ei, ej, End(wall: k, e: 0), End(wall: k, e: 1)])
        }
    }

    private struct GapCand: Comparable {
        let cost: Double
        let a: Int
        let b: Int
        let path: [SIMD2<Double>]
        let kind: Kind

        static func < (x: GapCand, y: GapCand) -> Bool {
            if x.cost != y.cost { return x.cost < y.cost }
            if x.a != y.a { return x.a < y.a }
            return x.b < y.b
        }
    }

    /// Открытые концы → пунктир: открытый угол (через сам угол), нет стены или «хвостик»
    private static func pairGaps(_ W: [Line], _ ends: [End]) -> [PairedGap] {
        var cands: [GapCand] = []
        let m = ends.count
        for a in 0..<m {
            for b in (a + 1)..<max(a + 1, m) {
                let (i, e, j, f) = (ends[a].wall, ends[a].e, ends[b].wall, ends[b].e)
                if i == j { continue }
                let P = W[i].end(e), Q = W[j].end(f)
                let d = simd_distance(P, Q)
                if d > gapMax { continue }
                let oi = W[i].out(e), oj = W[j].out(f)
                if fold(W[i].u, W[j].u) >= minCorner, let X = intersect(W[i], W[j]) {
                    let ti = ext(W[i], e, simd_dot(X, W[i].u)), tj = ext(W[j], f, simd_dot(X, W[j].u))
                    if -0.05 <= ti && ti <= cornerExt && -0.05 <= tj && tj <= cornerExt {
                        cands.append(GapCand(cost: ti + tj, a: a, b: b, path: [P, X, Q], kind: .corner))
                        continue
                    }
                }
                if simd_dot(oi, oj) > 0.7 {
                    // оба конца смотрят в одну сторону: между ними нет стены
                    let s = max(simd_dot(P, oi), simd_dot(Q, oi))
                    let raw = [P, P + oi * (s - simd_dot(P, oi)), Q + oi * (s - simd_dot(Q, oi)), Q]
                    var path: [SIMD2<Double>] = []
                    for (k, p) in raw.enumerated() where k == 0 || simd_distance(p, raw[k - 1]) > 1e-6 { path.append(p) }
                    cands.append(GapCand(cost: d, a: a, b: b, path: path, kind: .missing))
                    continue
                }
                if simd_dot(Q - P, oi) < -0.2 * d || simd_dot(P - Q, oj) < -0.2 * d { continue }
                cands.append(GapCand(cost: d, a: a, b: b, path: [P, Q], kind: d <= cornerGap ? .corner : .missing))
            }
        }
        cands.sort()
        var used = Set<Int>()
        var out: [PairedGap] = []
        for c in cands where !used.contains(c.a) && !used.contains(c.b) {
            used.formUnion([c.a, c.b])
            out.append(PairedGap(a: ends[c.a], b: ends[c.b], path: c.path, kind: c.kind))
        }
        for (a, end) in ends.enumerated() where !used.contains(a) {
            let P = W[end.wall].end(end.e)
            out.append(PairedGap(a: end, b: nil, path: [P, P + W[end.wall].out(end.e) * stub], kind: .end))
        }
        return out
    }

    /// Обход стен по углам от start: порядок (стена, вперёд ли) и замкнулся ли круг
    private static func walk(_ link: [End: End], _ start: Int) -> ([(Int, Bool)], Bool) {
        var order: [(Int, Bool)] = [(start, true)]
        var seen: Set<Int> = [start]
        var cur = End(wall: start, e: 1)
        var closedLoop = false
        while let next = link[cur] {
            if next.wall == start {
                closedLoop = next.e == 0
                break
            }
            if seen.contains(next.wall) { break }
            seen.insert(next.wall)
            order.append((next.wall, next.e == 0))
            cur = End(wall: next.wall, e: 1 - next.e)
        }
        if !closedLoop {
            cur = End(wall: start, e: 0)
            while let next = link[cur] {
                if seen.contains(next.wall) { break }
                seen.insert(next.wall)
                order.insert((next.wall, next.e == 1), at: 0)
                cur = End(wall: next.wall, e: 1 - next.e)
            }
        }
        return (order, closedLoop)
    }

    private static func segsCross(_ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ q1: SIMD2<Double>, _ q2: SIMD2<Double>) -> Bool {
        let d1 = cross(p2 - p1, q1 - p1), d2 = cross(p2 - p1, q2 - p1)
        let d3 = cross(q2 - q1, p1 - q1), d4 = cross(q2 - q1, p2 - q1)
        return ((d1 > 1e-9 && d2 < -1e-9) || (d1 < -1e-9 && d2 > 1e-9)) &&
            ((d3 > 1e-9 && d4 < -1e-9) || (d3 < -1e-9 && d4 > 1e-9))
    }

    private static func simple(_ poly: [SIMD2<Double>]) -> Bool {
        let k = poly.count
        guard k >= 3 else { return false }
        for a in 0..<k {
            for b in (a + 2)..<max(a + 2, k) {
                if a == 0 && b == k - 1 { continue }
                if segsCross(poly[a], poly[(a + 1) % k], poly[b], poly[(b + 1) % k]) { return false }
            }
        }
        return true
    }

    /// Стены по кругу комнаты: замкнутые углами или одним местом «доснять»
    private static func findLoop(_ W: [Line], _ link: [End: End], _ gaps: [PairedGap]) -> ([(Int, Bool)], [SIMD2<Double>]?)? {
        let total = W.reduce(0) { $0 + $1.length }
        var best: (key: (Int, Double, Int), order: [(Int, Bool)], closing: [SIMD2<Double>]?)?
        for start in W.indices {
            let (order, closedLoop) = walk(link, start)
            if order.count < 3 { continue }
            let coverLen = order.reduce(0) { $0 + W[$1.0].length }
            if coverLen < cover * total { continue }
            var closing: [SIMD2<Double>]?
            if !closedLoop {
                let first = order[0], last = order[order.count - 1]
                let entry = End(wall: first.0, e: first.1 ? 0 : 1)
                let exit = End(wall: last.0, e: last.1 ? 1 : 0)
                for g in gaps where g.kind != .hole {
                    guard let gb = g.b else { continue }
                    if g.a == exit && gb == entry { closing = g.path }
                    else if g.a == entry && gb == exit { closing = Array(g.path.reversed()) }
                }
                if closing == nil { continue }
            }
            let key = (closedLoop ? 0 : 1, -coverLen, start)
            if let b = best, !(key < b.key) { continue }
            best = (key: key, order: order, closing: closing)
        }
        guard let best else { return nil }
        return (best.order, best.closing)
    }

    private static func polygon(_ W: [Line], _ order: [(Int, Bool)], _ closing: [SIMD2<Double>]?) -> [SIMD2<Double>] {
        var pts = order.map { W[$0.0].at($0.1 ? W[$0.0].s0 : W[$0.0].s1) }
        if let closing { pts += closing.dropLast() }
        return pts
    }

    /// Площадь по снятым (не выпрямленным) концам стен в том же порядке
    private static func refArea(_ W: [Line], _ order: [(Int, Bool)], _ closing: [SIMD2<Double>]?) -> Double {
        var pts: [SIMD2<Double>] = []
        for (i, fwd) in order {
            let a = W[i].ra, b = W[i].rb
            var d = W[i].end(1) - W[i].end(0)
            if !fwd { d = -d }
            pts += simd_dot(b - a, d) >= 0 ? [a, b] : [b, a]
        }
        if let closing, closing.count > 2 { pts += closing[1..<(closing.count - 1)] }
        return abs(area(pts))
    }

    private static func isClosed(_ segs: [(SIMD2<Double>, SIMD2<Double>)]) -> Bool {
        for (i, s) in segs.enumerated() {
            for p in [s.0, s.1] {
                var near = false
                for (j, t) in segs.enumerated() where j != i && segDist(p, t.0, t.1) <= rawClosed { near = true; break }
                if !near { return false }
            }
        }
        return segs.count > 2
    }

    // MARK: - Всё вместе

    /// Выпрямляет стены. prev — угол сетки прошлого кадра (чтобы линии не дёргались)
    static func run(_ raw: [Wall], openings: [Opening] = [], prev: Double? = nil) -> Result {
        guard !raw.isEmpty else { return Result(angle: prev ?? 0) }
        let phi0 = dominant(raw)
        let ops0 = openings.map { (rot($0.center, -phi0), $0.width) }
        let W0 = merge(raw.enumerated().map { makeLine($1, $0, phi0, true) }, ops0)
        let phi = settle(refine(raw, W0, phi0), prev)
        let ops = openings.map { (rot($0.center, -phi), $0.width) }
        var W = merge(raw.enumerated().map { makeLine($1, $0, phi, true) }, ops)
        var holeList: [(Int, Double, Double)] = []
        for (k, l) in W.enumerated() {
            for h in holes(l, ops) { holeList.append((k, h.0, h.1)) }
        }
        var link: [End: End] = [:]
        var closed = Set<End>()
        closeCorners(&W, &link, &closed)
        closeSteps(&W, &link, &closed)
        var openEnds: [End] = []
        for i in W.indices {
            for e in 0...1 where !closed.contains(End(wall: i, e: e)) { openEnds.append(End(wall: i, e: e)) }
        }
        let gaps = pairGaps(W, openEnds)
        var loop = findLoop(W, link, gaps)

        let rsegs = raw.map { (rot($0.a, -phi), rot($0.b, -phi)) }
        var poly: [SIMD2<Double>] = []
        var sane = true
        if var (order, closing) = loop {
            if area(polygon(W, order, closing)) < 0 {
                order = order.reversed().map { ($0.0, !$0.1) }
                closing = closing.map { Array($0.reversed()) }
            }
            if closing == nil {
                var k = 0
                for q in order.indices where W[order[q].0].length > W[order[k].0].length { k = q }
                order = Array(order[k...] + order[..<k])
            }
            loop = (order, closing)
            poly = polygon(W, order, closing)
            let A = area(poly)
            let R = refArea(W, order, closing)
            if !simple(poly) || A < 0.5 || abs(A - R) > areaTol * max(R, 0.5) { sane = false }
        }
        for l in W where !l.made {
            for e in 0...1 {
                let p = l.end(e)
                if (rsegs.map { segDist(p, $0.0, $0.1) }.min() ?? 0) > maxMove { sane = false }
            }
        }
        for (a, b) in rsegs where simd_distance(a, b) >= 0.4 {
            let m = (a + b) * 0.5
            if (W.map { segDist(m, $0.end(0), $0.end(1)) }.min() ?? 0) > lost { sane = false }
        }
        if isClosed(rsegs) && gaps.contains(where: { $0.kind != .hole }) { sane = false }
        guard sane else { return rawResult(raw, phi) }

        var seq: [Int] = []
        var fwd: [Int: Bool] = [:]
        if let (order, _) = loop {
            for (i, f) in order {
                seq.append(i)
                fwd[i] = f
            }
        }
        for i in W.indices where fwd[i] == nil { seq.append(i) }
        var index: [Int: Int] = [:]
        for (new, old) in seq.enumerated() { index[old] = new }
        var res = Result(angle: phi)
        res.loop = poly.map { rot($0, phi) }
        res.rawToWall = Array(repeating: -1, count: raw.count)
        for (new, old) in seq.enumerated() {
            let l = W[old]
            let f = fwd[old] ?? true
            let (ea, eb) = f ? (0, 1) : (1, 0)
            var pieces: [OutPiece] = []
            for p in l.pieces {
                let q0 = max(p.s0, l.s0), q1 = min(p.s1, l.s1)
                if q1 - q0 > 0.02 {
                    pieces.append(OutPiece(a: rot(l.at(q0), phi), b: rot(l.at(q1), phi), conf: p.conf, top: p.top, bot: p.bot))
                }
            }
            res.walls.append(OutWall(a: rot(l.end(ea), phi), b: rot(l.end(eb), phi), height: l.height, bottom: l.bottom,
                                     conf: l.conf, src: l.src, pieces: pieces,
                                     openA: !closed.contains(End(wall: old, e: ea)),
                                     openB: !closed.contains(End(wall: old, e: eb)),
                                     made: l.made, angled: l.axis < 0))
            for r in l.src { res.rawToWall[r] = new }
        }
        for g in gaps {
            let a = index[g.a.wall] ?? -1
            let b = g.b.flatMap { index[$0.wall] } ?? -1
            res.gaps.append(Gap(path: g.path.map { rot($0, phi) }, wallA: b >= 0 ? min(a, b) : a,
                                wallB: b >= 0 ? max(a, b) : -1, kind: g.kind))
        }
        for (k, s0, s1) in holeList {
            let l = W[k]
            res.gaps.append(Gap(path: [rot(l.at(s0), phi), rot(l.at(s1), phi)], wallA: index[k] ?? -1, wallB: -1, kind: .hole))
        }
        return res
    }

    /// Скан как есть: только находим открытые концы
    private static func rawResult(_ raw: [Wall], _ phi: Double) -> Result {
        let W = raw.enumerated().map { makeLine($1, $0, phi, false) }
        let segs = W.map { ($0.end(0), $0.end(1)) }
        var openEnds: [End] = []
        for i in W.indices {
            for e in 0...1 {
                let p = W[i].end(e)
                var near = false
                for (j, s) in segs.enumerated() where j != i && segDist(p, s.0, s.1) <= rawClosed { near = true; break }
                if !near { openEnds.append(End(wall: i, e: e)) }
            }
        }
        let gaps = pairGaps(W, openEnds)
        var res = Result(angle: phi, ok: false)
        res.rawToWall = Array(raw.indices)
        let oe = Set(openEnds)
        for (i, l) in W.enumerated() {
            let a = rot(l.end(0), phi), b = rot(l.end(1), phi)
            res.walls.append(OutWall(a: a, b: b, height: l.height, bottom: l.bottom, conf: l.conf, src: [i],
                                     pieces: [OutPiece(a: a, b: b, conf: l.conf, top: raw[i].top, bot: raw[i].bot)],
                                     openA: oe.contains(End(wall: i, e: 0)), openB: oe.contains(End(wall: i, e: 1)),
                                     made: false, angled: true))
        }
        for g in gaps {
            let a = g.a.wall, b = g.b?.wall ?? -1
            res.gaps.append(Gap(path: g.path.map { rot($0, phi) }, wallA: b >= 0 ? min(a, b) : a,
                                wallB: b >= 0 ? max(a, b) : -1, kind: g.kind))
        }
        return res
    }
}
