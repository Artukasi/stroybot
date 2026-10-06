import Foundation
import simd

// Сверка Rectify.swift с эталоном на Python: те же стены на входе → те же выпрямленные стены.
// Запуск: rectify-check rectify_cases.json

struct Case: Decodable {
    struct Out: Decodable {
        struct W: Decodable {
            let p: [Double]
            let f: [Int]
            let src: [Int]
            let pieces: [[Double]]
        }
        struct G: Decodable {
            let kind: String
            let w: [Int]
            let path: [[Double]]
        }
        let angle: Double
        let ok: Bool
        let rawToWall: [Int]
        let walls: [W]
        let gaps: [G]
        let loop: [[Double]]
    }
    let name: String
    let walls: [[Double]]
    let openings: [[Double]]
    let prev: Double?
    let expect: Out
}

struct Cases: Decodable { let cases: [Case] }

let tol = 1e-4
var worst = 0.0

func near(_ a: Double, _ b: Double) -> Bool {
    worst = max(worst, abs(a - b))
    return abs(a - b) <= tol
}

func kindName(_ k: Rectify.Kind) -> String {
    switch k {
    case .corner: return "corner"
    case .missing: return "missing"
    case .end: return "end"
    case .hole: return "hole"
    }
}

/// Первое отличие или nil
func compare(_ c: Case) -> String? {
    let raw = c.walls.map {
        Rectify.Wall(a: SIMD2($0[0], $0[1]), b: SIMD2($0[2], $0[3]), height: $0[4], bottom: $0[5], conf: Int($0[6]),
                     top: $0[7] != 0, bot: $0[8] != 0)
    }
    let ops = c.openings.map { Rectify.Opening(center: SIMD2($0[0], $0[1]), width: $0[2]) }
    let r = Rectify.run(raw, openings: ops, prev: c.prev)
    let e = c.expect
    if r.ok != e.ok { return "ok \(r.ok) вместо \(e.ok)" }
    if abs(Rectify.wrap90(r.angle - e.angle)) > 1e-6 { return "угол \(r.angle) вместо \(e.angle)" }
    if r.walls.count != e.walls.count { return "стен \(r.walls.count) вместо \(e.walls.count)" }
    if r.rawToWall != e.rawToWall { return "rawToWall \(r.rawToWall) вместо \(e.rawToWall)" }
    for (i, (w, x)) in zip(r.walls, e.walls).enumerated() {
        let got = [w.a.x, w.a.y, w.b.x, w.b.y, w.height, w.bottom]
        for (g, v) in zip(got, x.p) where !near(g, v) { return "стена \(i): \(got) вместо \(x.p)" }
        let flags = [w.conf, w.openA ? 1 : 0, w.openB ? 1 : 0, w.made ? 1 : 0, w.angled ? 1 : 0]
        if flags != x.f { return "стена \(i): признаки \(flags) вместо \(x.f)" }
        if w.src != x.src { return "стена \(i): src \(w.src) вместо \(x.src)" }
        if w.pieces.count != x.pieces.count { return "стена \(i): кусков \(w.pieces.count) вместо \(x.pieces.count)" }
        for (k, (p, q)) in zip(w.pieces, x.pieces).enumerated() {
            let pg = [p.a.x, p.a.y, p.b.x, p.b.y]
            for (g, v) in zip(pg, q) where !near(g, v) { return "стена \(i), кусок \(k): \(pg) вместо \(q)" }
            if [p.conf, p.top ? 1 : 0, p.bot ? 1 : 0] != [Int(q[4]), Int(q[5]), Int(q[6])] { return "стена \(i), кусок \(k): признаки" }
        }
    }
    if r.gaps.count != e.gaps.count {
        return "мест доснять \(r.gaps.count) вместо \(e.gaps.count): \(r.gaps.map { kindName($0.kind) }) / \(e.gaps.map(\.kind))"
    }
    for (i, (g, x)) in zip(r.gaps, e.gaps).enumerated() {
        if kindName(g.kind) != x.kind || [g.wallA, g.wallB] != x.w {
            return "место \(i): \(kindName(g.kind)) \(g.wallA)-\(g.wallB) вместо \(x.kind) \(x.w)"
        }
        if g.path.count != x.path.count { return "место \(i): точек \(g.path.count) вместо \(x.path.count)" }
        for (p, q) in zip(g.path, x.path) where !near(p.x, q[0]) || !near(p.y, q[1]) { return "место \(i): точка \(p) вместо \(q)" }
    }
    if r.loop.count != e.loop.count { return "контур \(r.loop.count) точек вместо \(e.loop.count)" }
    for (p, q) in zip(r.loop, e.loop) where !near(p.x, q[0]) || !near(p.y, q[1]) { return "контур: точка \(p) вместо \(q)" }
    return nil
}

let args = CommandLine.arguments
guard args.count > 1, let data = FileManager.default.contents(atPath: args[1]) else {
    print("error: нет файла со случаями")
    exit(2)
}
let all = try JSONDecoder().decode(Cases.self, from: data).cases
var bad = 0
let started = Date()
for c in all {
    if let diff = compare(c) {
        bad += 1
        print("error: Rectify.swift не совпал с эталоном — \(c.name): \(diff)")
    }
}
let ms = Date().timeIntervalSince(started) * 1000 / Double(max(all.count, 1))
print(String(format: "Сверка с эталоном: %d случаев, совпало %d, наибольшее расхождение %.4f мм, %.2f мс на случай",
             all.count, all.count - bad, worst * 1000, ms))
exit(bad == 0 ? 0 : 1)
