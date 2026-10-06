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
    static let doubleNear = 0.06         // (дальше — может быть две стороны тонкой перегородки: пробуем оба варианта)
    static let bridgeFree = 0.08         // …и концы так близко — всегда одна стена (тоньше любой перегородки)
    static let bridgeGap = 1.0           // …или так близко, если в промежуток не упирается другая стена (не ниша и не пилон)
    static let bridgeNear = 0.50         // конец стены так близко к линии в промежутке — ниша, пилон или перегородка
    static let bridgeTol = 0.10
    static let mergeAng = 12 * deg       // куски одной косой стены
    static let doubleOff = 0.35          // двойная стена (уплыла): дальше, но перекрываются (больше rawClosed)
    static let doubleSeen = 0.50         // стена без углов рядом с более уверенной: оставляем, но «двоится»
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
    static let lost = 0.40               // проверка: каждая снятая стена рядом с выпрямленной (больше doubleOff)
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
    }

    struct Opening {
        var center: SIMD2<Double>
        var width: Double
    }

    struct Piece {
        var s0: Double
        var s1: Double
        var conf: Int
    }

    /// Кусок выпрямленной стены, который RoomPlan видел (с его уверенностью)
    struct OutPiece {
        var a: SIMD2<Double>
        var b: SIMD2<Double>
        var conf: Int
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
        /// Короткая стена, которую дорисовали между параллельными (её никто не снимал)
        var made: Bool
        var angled: Bool
        var length: Double { simd_distance(a, b) }
    }

    /// corner — угол не сомкнулся, missing — нет стены, end — конец стены ни во что не упёрся,
    /// hole — кусок стены не снят, double — стена снята дважды со сдвигом («двоится»)
    enum Kind { case corner, missing, end, hole, double }

    /// Где доснять: ломаная по полу (жёлтый пунктир) и между какими стенами (-1 — нет).
    /// У double: wallA — копия, wallB — стена, которую она повторяет
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

    /// Пара концов внутри подгонки. seam — стык кончиков (торец перегородки): сомкнут, наружу не выходит
    private enum PairKind { case corner, missing, end, seam, double }

    private struct PairedGap {
        let a: End
        let b: End?
        let path: [SIMD2<Double>]
        let kind: PairKind
    }

    private typealias Ops = [(SIMD2<Double>, Double)]
    /// Оценка попытки, меньше — лучше: выглядит неверно, не замкнулась, сколько мест жёлтые и их длина
    private typealias Score = (Int, Int, Int, Double)

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

    private static func pathLength(_ path: [SIMD2<Double>]) -> Double {
        zip(path, path.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
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
                    conf: w.conf, src: [i], pieces: [Piece(s0: s0, s1: s1, conf: w.conf)], ra: a, rb: b)
    }

    /// Дверь, окно или проём на линии l перекрывает промежуток g0…g1
    private static func covered(_ l: Line, _ g0: Double, _ g1: Double, _ ops: Ops) -> Bool {
        for (c, width) in ops {
            if abs(simd_dot(c, l.n) - l.o) >= openPerp { continue }
            let s = simd_dot(c, l.u)
            if s - width / 2 <= g0 + openTol && s + width / 2 >= g1 - openTol { return true }
        }
        return false
    }

    /// В промежуток g0…g1 на линии a упирается другая стена: ниша, пилон или перегородка, а не неснятый кусок
    private static func blocked(_ lines: [Line], _ a: Int, _ b: Int, _ g0: Double, _ g1: Double) -> Bool {
        let A = lines[a]
        for (k, C) in lines.enumerated() where k != a && k != b && fold(A.u, C.u) >= minCorner {
            for e in 0...1 {
                let p = C.end(e)
                let s = simd_dot(p, A.u)
                if g0 - bridgeTol <= s && s <= g1 + bridgeTol && abs(simd_dot(p, A.n) - A.o) <= bridgeNear { return true }
            }
        }
        return false
    }

    /// Сколько от lo…hi на линии A покрывают её снятые куски
    private static func seenOverlap(_ A: Line, _ lo: Double, _ hi: Double) -> Double {
        let ps = A.pieces.map { (max($0.s0, lo), min($0.s1, hi)) }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var total = 0.0, reach = lo
        for (a0, b) in ps {
            let a = max(a0, reach)
            if b > a {
                total += b - a
                reach = b
            }
        }
        return total
    }

    /// j — кусок i (или i — кусок j): то же направление, на той же линии (считаем от длинной), концы рядом.
    /// → 0 — нет, 1 — одна стена, 2 — одна стена, снятая дважды чуть в стороне
    private static func mergeable(_ lines: [Line], _ i: Int, _ j: Int, _ ops: Ops, _ doubles: Bool) -> Int {
        if fold(lines[i].u, lines[j].u) > mergeAng { return 0 }
        let (a, b) = lines[j].length > lines[i].length ? (j, i) : (i, j)
        let A = lines[a], B = lines[b]
        let perp = abs(simd_dot(B.mid, A.n) - A.o)
        let p0 = simd_dot(B.end(0), A.u), p1 = simd_dot(B.end(1), A.u)
        let lo = min(p0, p1), hi = max(p0, p1)
        let g0 = min(A.s1, hi), g1 = max(A.s0, lo)
        let gap = g1 - g0
        if perp < mergeOff && (gap <= bridgeFree || (gap < bridgeGap && !blocked(lines, a, b, g0, g1))) {
            if perp < doubleNear { return 1 }
            return doubles ? 2 : 0
        }
        // стена, разорванная дверью, даже чуть в стороне от своей линии (уплыла)
        if perp < doubleOff && 0 < gap && gap < openGap && covered(A, g0, g1, ops) { return 1 }
        if doubles && perp < doubleOff && seenOverlap(A, lo, hi) >= max(doubleMin, doubleShare * (hi - lo)) { return 2 }
        return 0
    }

    private static func mergeGroup(_ ws: [Line]) -> Line {
        guard ws.count > 1 else { return ws[0] }
        var longest = ws[0]
        for w in ws.dropFirst() where w.length > longest.length { longest = w }
        var weights = ws.map { $0.length * confWeight[$0.conf] }
        if weights.reduce(0, +) <= 0 { weights = ws.map { _ in 1 } }
        // направление: куски как были (не выпрямленные), потом выпрямляем целиком
        let ref = unit(longest.rb - longest.ra)
        var v = SIMD2<Double>(0, 0)
        for (w, k) in zip(ws, weights) {
            let d = unit(w.rb - w.ra)
            v += (simd_dot(d, ref) >= 0 ? d : -d) * k
        }
        let (axis, u) = snapDir(atan2(v.y, v.x), true)
        let n = SIMD2(-u.y, u.x)
        // где стоит стена: самый уверенный кусок и куски на его линии; копия в стороне её не тянет
        var best = 0
        for k in 1..<ws.count where (ws[k].conf, ws[k].length) > (ws[best].conf, ws[best].length) { best = k }
        let ob = simd_dot(ws[best].mid, n)
        var core = ws.indices.filter { abs(simd_dot(ws[$0].mid, n) - ob) < mergeOff }
        if core.reduce(0.0, { $0 + weights[$1] }) <= 0 { core = Array(ws.indices) }
        let tw = core.reduce(0.0) { $0 + weights[$1] }
        let o = core.reduce(0.0) { $0 + weights[$1] * simd_dot(ws[$1].mid, n) } / tw
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
                pieces.append(Piece(s0: min(q0, q1), s1: max(q0, q1), conf: p.conf))
            }
        }
        let tl = core.reduce(0.0) { $0 + ws[$1].length }
        let weighted = core.reduce(0.0) { $0 + ws[$1].length * Double(ws[$1].conf) }
        let mean = tl > 0 ? weighted / tl : 2
        let conf = mean < 0.75 ? 0 : (mean < 1.5 ? 1 : 2)
        // та же стена до выпрямления: среднее направление и сдвиг снятых кусков на её линии
        var rv = SIMD2<Double>(0, 0)
        for k in core {
            let d = unit(ws[k].rb - ws[k].ra)
            rv += (simd_dot(d, u) >= 0 ? d : -d) * weights[k]
        }
        let ru = unit(rv)
        let rn = SIMD2(-ru.y, ru.x)
        let ro = core.reduce(0.0) { $0 + weights[$1] * simd_dot((ws[$1].ra + ws[$1].rb) * 0.5, rn) } / tw
        var rs: [Double] = []
        for w in ws { rs += [simd_dot(w.ra, ru), simd_dot(w.rb, ru)] }
        let ra = ru * (rs.min() ?? 0) + rn * ro, rb = ru * (rs.max() ?? 0) + rn * ro
        let src = ws.flatMap(\.src).sorted()
        return Line(u: u, n: n, o: o, s0: s0, s1: s1, axis: axis, height: longest.height, bottom: longest.bottom,
                    conf: conf, src: src, pieces: pieces, ra: ra, rb: rb)
    }

    /// → склеенные стены и склеена ли двойная стена
    private static func merge(_ input: [Line], _ ops: Ops, _ doubles: Bool) -> ([Line], Bool) {
        var lines = input
        var used = false
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
                for j in (i + 1)..<max(i + 1, n) {
                    let kind = mergeable(lines, i, j, ops, doubles)
                    guard kind > 0 else { continue }
                    let ri = find(i), rj = find(j)
                    if ri != rj {
                        parent[max(ri, rj)] = min(ri, rj)
                        if kind == 2 { used = true }
                    }
                }
            }
            var groups: [Int: [Int]] = [:]
            for i in 0..<n { groups[find(i), default: []].append(i) }
            if groups.count == n { break }
            lines = groups.keys.sorted().map { r in mergeGroup(groups[r]!.map { lines[$0] }) }
        }
        return (lines, used)
    }

    /// Промежутки внутри собранной стены, которые не покрыл ни один кусок
    private static func holes(_ l: Line, _ ops: Ops) -> [(Double, Double)] {
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

    /// Конец e можно сдвинуть на t: чуть-чуть или через дверь (проём) у самого конца и чуть дальше неё
    private static func reach(_ l: Line, _ e: Int, _ t: Double, _ ops: Ops) -> Bool {
        if okExt(l, t) { return true }
        if t <= join || t > openGap + join { return false }
        for (c, width) in ops {
            if abs(simd_dot(c, l.n) - l.o) >= openPerp { continue }
            let s = simd_dot(c, l.u)
            let lo = s - width / 2, hi = s + width / 2
            if e == 1 && lo <= l.s1 + openTol && hi > l.s1 && l.s1 + t - hi <= join { return true }
            if e == 0 && hi >= l.s0 - openTol && lo < l.s0 && lo - (l.s0 - t) <= join { return true }
        }
        return false
    }

    private static func trimCost(_ l: Line, _ t: Double) -> Double { -t > trimShare * l.length ? 1 : 0 }

    private static func setEnd(_ l: inout Line, _ e: Int, _ s: Double) {
        if e == 1 { l.s1 = s } else { l.s0 = s }
    }

    private static func newLen(_ l: Line, _ e: Int, _ s: Double) -> Double { e == 1 ? s - l.s0 : l.s1 - s }

    /// Обрезка конца e до s оставит от стены слишком мало (короткая стена может и вырасти)
    private static func tooShort(_ l: Line, _ e: Int, _ s: Double) -> Bool {
        let k = newLen(l, e, s)
        return k < minWall && k < l.length
    }

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

    /// Углы и Т-стыки: концы продлеваем (и через дверь у самого угла) или обрезаем до пересечения
    private static func closeCorners(_ W: inout [Line], _ ops: Ops, _ link: inout [End: End], _ closed: inout Set<End>) {
        let n = W.count
        var cands: [Corner] = []
        for i in 0..<n {
            for e in 0...1 {
                for j in 0..<n where j != i && fold(W[i].u, W[j].u) >= minCorner {
                    guard let X = intersect(W[i], W[j]) else { continue }
                    let ti = ext(W[i], e, simd_dot(X, W[i].u))
                    guard reach(W[i], e, ti, ops) else { continue }
                    let sj = simd_dot(X, W[j].u)
                    if sj - W[j].s0 > join && W[j].s1 - sj > join {
                        cands.append(Corner(cost: abs(ti) + tPenalty + trimCost(W[i], ti), kind: 1, i: i, e: e, j: j, f: -1, x: X))
                        continue
                    }
                    if i > j { continue }
                    for f in 0...1 {
                        let tj = ext(W[j], f, sj)
                        if reach(W[j], f, tj, ops) {
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
            if tooShort(W[c.i], c.e, si) { continue }
            if c.kind == 0 {
                let ej = End(wall: c.j, e: c.f)
                if closed.contains(ej) { continue }
                let sj = simd_dot(c.x, W[c.j].u)
                if tooShort(W[c.j], c.f, sj) { continue }
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

    /// Параллельные стены чуть со сдвигом: соединяем короткой стеной поперёк. Её никто не снимал — это «доснять»
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
            W.append(Line(u: u, n: nn, o: simd_dot(P, nn), s0: lo, s1: hi, axis: axis, height: h, bottom: bt, conf: 0,
                          src: [], pieces: [Piece(s0: lo, s1: hi, conf: 0)], ra: P, rb: Q, made: true))
            let ep = End(wall: k, e: a <= b ? 0 : 1), eq = End(wall: k, e: a <= b ? 1 : 0)
            link[ei] = ep
            link[ep] = ei
            link[ej] = eq
            link[eq] = ej
            closed.formUnion([ei, ej, End(wall: k, e: 0), End(wall: k, e: 1)])
        }
    }

    /// Стена j увереннее стены i: выше уверенность, потом длиннее, потом раньше
    private static func stronger(_ W: [Line], _ i: Int, _ j: Int) -> Bool {
        if W[j].conf != W[i].conf { return W[j].conf > W[i].conf }
        if W[j].length != W[i].length { return W[j].length > W[i].length }
        return j < i
    }

    /// Стена, ни с чем не сомкнутая, рядом с более уверенной сомкнутой (одна стена снята дважды, уплыла)
    /// → [копия: (стена, которую она повторяет, насколько в стороне)]
    private static func findCopies(_ W: [Line], _ closed: Set<End>) -> [Int: (Int, Double)] {
        var out: [Int: (Int, Double)] = [:]
        for i in W.indices {
            let A = W[i]
            if A.made || closed.contains(End(wall: i, e: 0)) || closed.contains(End(wall: i, e: 1)) { continue }
            var best = -1, bd = doubleSeen
            for j in W.indices {
                let B = W[j]
                if j == i || B.made || fold(A.u, B.u) > mergeAng || !stronger(W, i, j) { continue }
                if !closed.contains(End(wall: j, e: 0)) && !closed.contains(End(wall: j, e: 1)) { continue }
                let perp = abs(simd_dot(A.mid, B.n) - B.o)
                if perp >= bd { continue }
                let p0 = simd_dot(A.end(0), B.u), p1 = simd_dot(A.end(1), B.u)
                if seenOverlap(B, min(p0, p1), max(p0, p1)) < max(doubleMin, doubleShare * A.length) { continue }
                best = j
                bd = perp
            }
            if best >= 0 { out[i] = (best, bd) }
        }
        return out
    }

    /// Копия i становится частью стены j: что она видела, считается снятым на j
    private static func absorb(_ W: inout [Line], _ holesOf: inout [Int: [(Double, Double)]], _ i: Int, _ j: Int) {
        let A = W[i], B = W[j]
        var added: [Piece] = []
        for p in A.pieces {
            let q0 = simd_dot(A.at(p.s0), B.u), q1 = simd_dot(A.at(p.s1), B.u)
            added.append(Piece(s0: min(q0, q1), s1: max(q0, q1), conf: p.conf))
        }
        W[j].pieces = B.pieces + added
        W[j].src = (B.src + A.src).sorted()
        var left: [(Double, Double)] = []
        for (h0, h1) in holesOf[j] ?? [] {
            var parts = [(h0, h1)]
            for p in added {
                var next: [(Double, Double)] = []
                for (a, b) in parts {
                    if p.s1 <= a || p.s0 >= b {
                        next.append((a, b))
                        continue
                    }
                    if p.s0 > a { next.append((a, p.s0)) }
                    if p.s1 < b { next.append((p.s1, b)) }
                }
                parts = next
            }
            left += parts.filter { $0.1 - $0.0 > holeMin }
        }
        holesOf[j] = left
        holesOf[i] = nil
    }

    private struct GapCand: Comparable {
        let cost: Double
        let a: Int
        let b: Int
        let path: [SIMD2<Double>]
        let kind: PairKind

        static func < (x: GapCand, y: GapCand) -> Bool {
            if x.cost != y.cost { return x.cost < y.cost }
            if x.a != y.a { return x.a < y.a }
            return x.b < y.b
        }
    }

    /// Открытые концы → пунктир: открытый угол (через сам угол), нет стены или «хвостик».
    /// Концы параллельных стен в паре сантиметров (торец перегородки) — стык: сомкнут, не показываем
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
                let angle = fold(W[i].u, W[j].u) >= minCorner
                if angle, let X = intersect(W[i], W[j]) {
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
                    cands.append(GapCand(cost: d, a: a, b: b, path: path, kind: angle || d > holeMin ? .missing : .seam))
                    continue
                }
                if simd_dot(Q - P, oi) < -0.2 * d || simd_dot(P - Q, oj) < -0.2 * d { continue }
                // параллельные концы смотрят друг на друга: не хватает куска стены, это не угол
                let kind: PairKind = angle && d <= cornerGap ? .corner : (angle || d > holeMin ? .missing : .seam)
                cands.append(GapCand(cost: d, a: a, b: b, path: [P, Q], kind: kind))
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

    private struct Hop {
        let to: End
        let path: [SIMD2<Double>]?
        let missing: Bool
    }

    /// Стены по кругу комнаты: через углы, открытые углы (через сам угол), стыки и не больше одной пропущенной стены.
    /// → порядок (стена, вперёд ли) и путь после каждой стены (nil — угол)
    private static func findLoop(_ W: [Line], _ link: [End: End], _ gaps: [PairedGap],
                                 _ skip: Set<Int>) -> ([(Int, Bool)], [[SIMD2<Double>]?])? {
        var hops: [End: Hop] = [:]
        for (a, b) in link { hops[a] = Hop(to: b, path: nil, missing: false) }
        for g in gaps {
            guard let gb = g.b, g.kind == .corner || g.kind == .missing || g.kind == .seam else { continue }
            hops[g.a] = Hop(to: gb, path: g.path, missing: g.kind == .missing)
            hops[gb] = Hop(to: g.a, path: Array(g.path.reversed()), missing: g.kind == .missing)
        }
        var total = 0.0
        for i in W.indices where !skip.contains(i) { total += W[i].length }
        var best: (key: (Int, Double, Int), order: [(Int, Bool)], outs: [[SIMD2<Double>]?])?
        for start in W.indices where !skip.contains(start) {
            var order: [(Int, Bool)] = [(start, true)]
            var outs: [[SIMD2<Double>]?] = []
            var seen: Set<Int> = [start]
            var cur = End(wall: start, e: 1)
            var closedLoop = false
            var missing = 0
            while let h = hops[cur] {
                if h.missing {
                    missing += 1
                    if missing > 1 { break }
                }
                outs.append(h.path)
                if h.to.wall == start {
                    closedLoop = h.to.e == 0
                    break
                }
                if seen.contains(h.to.wall) { break }
                seen.insert(h.to.wall)
                order.append((h.to.wall, h.to.e == 0))
                cur = End(wall: h.to.wall, e: 1 - h.to.e)
            }
            if !closedLoop || order.count < 3 { continue }
            let coverLen = order.reduce(0.0) { $0 + W[$1.0].length }
            if coverLen < cover * total { continue }
            let key = (outs.filter { $0 != nil }.count, -coverLen, start)
            if let b = best, !(key < b.key) { continue }
            best = (key: key, order: order, outs: outs)
        }
        guard let best else { return nil }
        return (best.order, best.outs)
    }

    private static func polygon(_ W: [Line], _ order: [(Int, Bool)], _ outs: [[SIMD2<Double>]?]) -> [SIMD2<Double>] {
        var pts: [SIMD2<Double>] = []
        for ((i, fwd), path) in zip(order, outs) {
            pts.append(W[i].at(fwd ? W[i].s0 : W[i].s1))
            if let path { pts += path.dropLast() }
        }
        return pts
    }

    /// Убирает точки, где контур идёт ровно назад (открытый угол чуть дальше своей стены), и повторы
    private static func unspike(_ input: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var pts = input
        var k = 0
        while pts.count > 3 && k < pts.count {
            let p = pts[(k - 1 + pts.count) % pts.count], v = pts[k], q = pts[(k + 1) % pts.count]
            let a = v - p, b = q - v
            if simd_length(a) < 1e-9 || (abs(cross(a, b)) < 1e-9 && simd_dot(a, b) < 0) {
                pts.remove(at: k)
                k = max(0, k - 1)
            } else {
                k += 1
            }
        }
        return pts
    }

    /// Площадь по снятым (не выпрямленным) концам стен в том же порядке
    private static func refArea(_ W: [Line], _ order: [(Int, Bool)], _ outs: [[SIMD2<Double>]?]) -> Double {
        var pts: [SIMD2<Double>] = []
        for ((i, fwd), path) in zip(order, outs) {
            let a = W[i].ra, b = W[i].rb
            var d = W[i].end(1) - W[i].end(0)
            if !fwd { d = -d }
            pts += simd_dot(b - a, d) >= 0 ? [a, b] : [b, a]
            if let path, path.count > 2 { pts += path[1..<(path.count - 1)] }
        }
        return abs(area(pts))
    }

    /// Концы стен скана, которые ни во что не упираются. Стена рядом (параллельно, в стороне) не в счёт:
    /// двойная стена не сомкнута с той, которую повторяет
    private static func rawOpen(_ segs: [(SIMD2<Double>, SIMD2<Double>)]) -> [End] {
        let dirs = segs.map { unit($0.1 - $0.0) }
        var out: [End] = []
        for (i, s) in segs.enumerated() {
            for (e, p) in [s.0, s.1].enumerated() {
                var near = false
                for (j, t) in segs.enumerated() where j != i && segDist(p, t.0, t.1) <= rawClosed {
                    if fold(dirs[i], dirs[j]) <= mergeAng && abs(cross(dirs[j], p - t.0)) >= mergeOff { continue }
                    near = true
                    break
                }
                if !near { out.append(End(wall: i, e: e)) }
            }
        }
        return out
    }

    private static func publicKind(_ k: PairKind) -> Kind? {
        switch k {
        case .corner: return .corner
        case .missing: return .missing
        case .end: return .end
        case .double: return .double
        case .seam: return nil
        }
    }

    private static func outGaps(_ gaps: [PairedGap], _ index: [Int: Int], _ phi: Double) -> [Gap] {
        var out: [Gap] = []
        for g in gaps {
            guard let kind = publicKind(g.kind) else { continue }
            let a = index[g.a.wall] ?? -1
            let b = g.b.flatMap { index[$0.wall] } ?? -1
            let (wa, wb) = kind == .double || b < 0 ? (a, b) : (min(a, b), max(a, b))
            out.append(Gap(path: g.path.map { rot($0, phi) }, wallA: wa, wallB: wb, kind: kind))
        }
        return out
    }

    // MARK: - Всё вместе

    /// Выпрямляет стены. prev — угол сетки прошлого кадра (чтобы линии не дёргались)
    static func run(_ raw: [Wall], openings: [Opening] = [], prev: Double? = nil) -> Result {
        guard !raw.isEmpty else { return Result(angle: prev ?? 0) }
        let phi0 = dominant(raw)
        let ops0 = openings.map { (rot($0.center, -phi0), $0.width) }
        let W0 = merge(raw.enumerated().map { makeLine($1, $0, phi0, true) }, ops0, true).0
        let phi = settle(refine(raw, W0, phi0), prev)
        let ops = openings.map { (rot($0.center, -phi), $0.width) }
        let (first, used, score) = attempt(raw, ops, phi, true)
        var res = first
        if used {
            // две стороны перегородки — не одна стена, снятая дважды: оставляем их врозь, если так комната не хуже
            let (alt, _, altScore) = attempt(raw, ops, phi, false)
            if altScore <= score { res = alt }
        }
        return res ?? rawResult(raw, phi)
    }

    /// Одна попытка выпрямить → (итог или nil, если он выглядит хуже скана; склеена ли двойная стена; оценка)
    private static func attempt(_ raw: [Wall], _ ops: Ops, _ phi: Double, _ doubles: Bool) -> (Result?, Bool, Score) {
        let merged = merge(raw.enumerated().map { makeLine($1, $0, phi, true) }, ops, doubles)
        var W = merged.0
        let used = merged.1
        var holesOf: [Int: [(Double, Double)]] = [:]
        for (k, l) in W.enumerated() {
            let hs = holes(l, ops)
            if !hs.isEmpty { holesOf[k] = hs }
        }
        var link: [End: End] = [:]
        var closed = Set<End>()
        closeCorners(&W, ops, &link, &closed)
        closeSteps(&W, &link, &closed)
        // одна стена снята дважды: копию рядом убираем, копию подальше показываем как «двоится»
        var gone: [Int: Int] = [:], dbl: [Int: Int] = [:]
        let copies = findCopies(W, closed)
        for i in copies.keys.sorted() {
            let (j, d) = copies[i]!
            if d < doubleOff {
                gone[i] = j
                absorb(&W, &holesOf, i, j)
            } else {
                dbl[i] = j
            }
        }
        var openEnds: [End] = []
        for i in W.indices where gone[i] == nil && dbl[i] == nil {
            for e in 0...1 where !closed.contains(End(wall: i, e: e)) { openEnds.append(End(wall: i, e: e)) }
        }
        var gaps = pairGaps(W, openEnds)
        for g in gaps where g.kind == .seam {
            closed.insert(g.a)
            if let b = g.b { closed.insert(b) }
        }
        for i in dbl.keys.sorted() {
            gaps.append(PairedGap(a: End(wall: i, e: 0), b: End(wall: dbl[i]!, e: 0), path: [W[i].end(0), W[i].end(1)], kind: .double))
        }
        let skip = Set(gone.keys).union(dbl.keys)
        var loop = findLoop(W, link, gaps, skip)

        let rsegs = raw.map { (rot($0.a, -phi), rot($0.b, -phi)) }
        var poly: [SIMD2<Double>] = []
        var sane = true
        if var (order, outs) = loop {
            if area(polygon(W, order, outs)) < 0 {
                let n = order.count
                let old = outs
                order = order.reversed().map { ($0.0, !$0.1) }
                outs = (0..<n).map { m in old[((n - 2 - m) % n + n) % n].map { Array($0.reversed()) } }
            }
            var k = 0
            for q in order.indices where W[order[q].0].length > W[order[k].0].length { k = q }
            order = Array(order[k...] + order[..<k])
            outs = Array(outs[k...] + outs[..<k])
            loop = (order, outs)
            poly = unspike(polygon(W, order, outs))
            let A = area(poly)
            let R = refArea(W, order, outs)
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
        let openKind = gaps.contains { $0.kind == .corner || $0.kind == .missing || $0.kind == .end }
        if rsegs.count > 2 && rawOpen(rsegs).isEmpty && openKind { sane = false }
        guard sane else { return (nil, used, (1, 1, 0, 0)) }
        var marks: [Double] = gaps.map { pathLength($0.path) }
        for k in holesOf.keys.sorted() { marks += holesOf[k]!.map { $0.1 - $0.0 } }
        marks += W.filter { $0.made }.map { $0.length }
        let score: Score = (0, loop != nil ? 0 : 1, marks.count, marks.reduce(0, +))

        var seq: [Int] = []
        var fwd: [Int: Bool] = [:]
        if let (order, _) = loop {
            for (i, f) in order {
                seq.append(i)
                fwd[i] = f
            }
        }
        for i in W.indices where fwd[i] == nil && gone[i] == nil { seq.append(i) }
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
                if q1 - q0 > 0.02 { pieces.append(OutPiece(a: rot(l.at(q0), phi), b: rot(l.at(q1), phi), conf: p.conf)) }
            }
            let copy = dbl[old] != nil
            res.walls.append(OutWall(a: rot(l.end(ea), phi), b: rot(l.end(eb), phi), height: l.height, bottom: l.bottom,
                                     conf: l.conf, src: l.src, pieces: pieces,
                                     openA: !closed.contains(End(wall: old, e: ea)) && !copy,
                                     openB: !closed.contains(End(wall: old, e: eb)) && !copy,
                                     made: l.made, angled: l.axis < 0))
            for r in l.src { res.rawToWall[r] = new }
        }
        res.gaps = outGaps(gaps, index, phi)
        for k in holesOf.keys.sorted() {
            let l = W[k]
            for (s0, s1) in holesOf[k]! {
                res.gaps.append(Gap(path: [rot(l.at(s0), phi), rot(l.at(s1), phi)], wallA: index[k] ?? -1, wallB: -1, kind: .hole))
            }
        }
        return (res, used, score)
    }

    /// Скан как есть: находим только открытые концы и двойные стены
    private static func rawResult(_ raw: [Wall], _ phi: Double) -> Result {
        let W = raw.enumerated().map { makeLine($1, $0, phi, false) }
        let openEnds = rawOpen(W.map { ($0.end(0), $0.end(1)) })
        var closed = Set<End>()
        for i in W.indices {
            for e in 0...1 { closed.insert(End(wall: i, e: e)) }
        }
        closed.subtract(openEnds)
        var dbl: [Int: Int] = [:]
        for (i, c) in findCopies(W, closed) { dbl[i] = c.0 }
        var gaps = pairGaps(W, openEnds.filter { dbl[$0.wall] == nil })
        for i in dbl.keys.sorted() {
            gaps.append(PairedGap(a: End(wall: i, e: 0), b: End(wall: dbl[i]!, e: 0), path: [W[i].end(0), W[i].end(1)], kind: .double))
        }
        var res = Result(angle: phi, ok: false)
        res.rawToWall = Array(raw.indices)
        var oe = Set(openEnds)
        for g in gaps where g.kind == .seam {
            oe.remove(g.a)
            if let b = g.b { oe.remove(b) }
        }
        for (i, l) in W.enumerated() {
            let a = rot(l.end(0), phi), b = rot(l.end(1), phi)
            let copy = dbl[i] != nil
            res.walls.append(OutWall(a: a, b: b, height: l.height, bottom: l.bottom, conf: l.conf, src: [i],
                                     pieces: [OutPiece(a: a, b: b, conf: l.conf)],
                                     openA: oe.contains(End(wall: i, e: 0)) && !copy,
                                     openB: oe.contains(End(wall: i, e: 1)) && !copy,
                                     made: false, angled: true))
        }
        var identity: [Int: Int] = [:]
        for i in W.indices { identity[i] = i }
        res.gaps = outGaps(gaps, identity, phi)
        return res
    }
}
