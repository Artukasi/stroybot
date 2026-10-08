import Foundation
import simd

/// Чертёж DXF (AutoCAD R12 — открывают AutoCAD, nanoCAD, КОМПАС, ArchiCAD, LibreCAD и онлайн-просмотрщики).
/// Миллиметры, слои: стены, окна, двери, размеры, мебель, электрика, сантехника, трубы. Подписи — по-русски (кодировка 1251).
enum PlanDXF {
    private struct Layer {
        let name: String
        let color: Int
    }

    private static let layers = [
        Layer(name: "STENY", color: 7),
        Layer(name: "POL", color: 9),
        Layer(name: "OKNA", color: 5),
        Layer(name: "DVERI", color: 2),
        Layer(name: "RAZMERY", color: 1),
        Layer(name: "MEBEL", color: 8),
        Layer(name: "ELEKTRIKA", color: 30),
        Layer(name: "SANTEHNIKA", color: 4),
        Layer(name: "TRUBY", color: 150),
        Layer(name: "PROVODA", color: 30),
        Layer(name: "PODPISI", color: 7),
    ]

    /// Одна комната: стены, проёмы, размеры стен, мебель, электрика и сантехника
    static func room(_ r: RoomResult) -> URL? {
        var d = Writer()
        let mm = { (p: SIMD2<Double>) in SIMD2(p.x * 1000, -p.y * 1000) }   // в DXF ось Y смотрит вверх

        if r.plan.count > 2 { d.polyline(r.plan.map(mm), closed: true, layer: "POL") }
        let center = r.plan.isEmpty ? SIMD2<Double>(0, 0) : r.plan.reduce(SIMD2<Double>(0, 0), +) / Double(r.plan.count)
        for l in r.wallLines {
            let a = mm(SIMD2(l.x, l.y)), b = mm(SIMD2(l.z, l.w))
            d.line(a, b, layer: "STENY")
            // длина стены — снаружи, вдоль стены
            let len = simd_distance(a, b)
            guard len > 1 else { continue }
            let u = (b - a) / len
            var n = SIMD2(-u.y, u.x)
            if simd_dot(mm(center) - (a + b) / 2, n) > 0 { n = -n }
            var angle = atan2(u.y, u.x) * 180 / .pi
            if angle > 90 || angle < -90 { angle += 180 }
            d.text("\(Int(len.rounded()))", at: (a + b) / 2 + n * 180, height: 120, angle: angle, layer: "RAZMERY")
        }
        for o in r.openings {
            guard let wi = o.wall, wi < r.wallLines.count, let off = o.offset else { continue }
            let l = r.wallLines[wi]
            let a = SIMD2(l.x, l.y), b = SIMD2(l.z, l.w)
            let len = simd_distance(a, b)
            guard len > 0 else { continue }
            let u = (b - a) / len
            let p1 = mm(a + u * max(0, off - o.width / 2)), p2 = mm(a + u * min(len, off + o.width / 2))
            let layer = o.kind == "window" ? "OKNA" : "DVERI"
            d.line(p1, p2, layer: layer)
            // засечки по краям проёма и ширина
            let du = simd_normalize(p2 - p1)
            let n = SIMD2(-du.y, du.x) * 80
            d.line(p1 - n, p1 + n, layer: layer)
            d.line(p2 - n, p2 + n, layer: layer)
            var angle = atan2(du.y, du.x) * 180 / .pi
            if angle > 90 || angle < -90 { angle += 180 }
            let title = o.kind == "window" ? "окно" : "дверь"
            d.text("\(title) \(Int((o.width * 1000).rounded()))", at: (p1 + p2) / 2 - n * 2.6, height: 80, angle: angle, layer: layer)
        }
        for it in r.items {
            let c = SIMD2(it.x, it.y)
            let ca = cos(it.angle), sa = sin(it.angle)
            let corners = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)].map { sx, sy -> SIMD2<Double> in
                let lx = sx * it.width / 2, ly = sy * it.depth / 2
                return mm(c + SIMD2(lx * ca - ly * sa, lx * sa + ly * ca))
            }
            d.polyline(corners, closed: true, layer: "MEBEL")
            d.text(it.title, at: mm(c), height: 70, angle: 0, layer: "MEBEL")
        }
        for p in r.engineering.points {
            guard let k = EngKind.find(p.kind) else { continue }
            let c = mm(SIMD2(p.x, p.y))
            let layer = k.group == .electric ? "ELEKTRIKA" : "SANTEHNIKA"
            d.circle(c, radius: 70, layer: layer)
            let h = p.wall == nil ? "потолок" : "h=\(Int((p.height * 1000).rounded()))"
            d.text("\(k.short) \(h)", at: c + SIMD2(0, -150), height: 60, angle: 0, layer: layer)
        }
        for p in r.engineering.pipes {
            let color = ["cold": 5, "hot": 1, "sewer": 8, "heating": 6][p.kind]
            d.polyline(p.points.map { mm(SIMD2($0.x, $0.y)) }, closed: false, layer: "TRUBY", color: color)
            if let first = p.points.first, let k = PipeKind.find(p.kind) {
                d.text("\(k.title) Ø\(p.diameter)", at: mm(SIMD2(first.x, first.y)) + SIMD2(0, 120), height: 60, angle: 0,
                       layer: "TRUBY")
            }
        }
        for p in r.engineering.wires {
            d.polyline(p.points.map { mm(SIMD2($0.x, $0.y)) }, closed: false, layer: "PROVODA", color: 30)
            if let first = p.points.first, let k = WireKind.find(p.kind) {
                d.text("\(k.title) \(k.cable)", at: mm(SIMD2(first.x, first.y)) + SIMD2(0, -120), height: 60, angle: 0,
                       layer: "PROVODA")
            }
        }
        d.text("\(r.room) · пол \(fmt(r.floorArea)) м2 · h=\(Int((r.height * 1000).rounded()))", at: mm(center), height: 160,
               angle: 0, layer: "PODPISI")
        return d.save(name: r.room)
    }

    /// Квартира: контуры комнат (в общих координатах, если снимали за один раз) и подписи
    static func flat(name: String, rooms: [RoomResult], outlines: [[[Double]]]?) -> URL? {
        var d = Writer()
        let shapes = FlatLayout.shapes(rooms: rooms, outlines: outlines)
        for (s, r) in zip(shapes, rooms) {
            let pts = s.points.map { SIMD2($0.x * 1000, -$0.y * 1000) }
            guard pts.count > 2 else { continue }
            d.polyline(pts, closed: true, layer: "STENY")
            for (a, b) in zip(pts, pts.dropFirst() + [pts[0]]) {
                let len = simd_distance(a, b)
                guard len > 300 else { continue }
                var angle = atan2(b.y - a.y, b.x - a.x) * 180 / .pi
                if angle > 90 || angle < -90 { angle += 180 }
                d.text("\(Int(len.rounded()))", at: (a + b) / 2, height: 100, angle: angle, layer: "RAZMERY")
            }
            let c = FlatLayout.centroid(s.points)
            d.text("\(r.room) \(fmt(r.floorArea)) м2", at: SIMD2(c.x * 1000, -c.y * 1000), height: 150, angle: 0, layer: "PODPISI")
        }
        return d.save(name: name)
    }

    // MARK: - Запись

    private struct Writer {
        var body: [String] = []

        mutating func add(_ code: Int, _ value: String) {
            body.append("\(code)")
            body.append(value)
        }

        mutating func add(_ code: Int, _ v: Double) { add(code, String(format: "%.1f", v)) }

        mutating func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>, layer: String) {
            add(0, "LINE"); add(8, layer)
            add(10, a.x); add(20, a.y); add(30, 0.0)
            add(11, b.x); add(21, b.y); add(31, 0.0)
        }

        mutating func polyline(_ pts: [SIMD2<Double>], closed: Bool, layer: String, color: Int? = nil) {
            guard pts.count > 1 else { return }
            add(0, "POLYLINE"); add(8, layer)
            if let color { add(62, "\(color)") }
            add(66, "1"); add(10, 0.0); add(20, 0.0); add(30, 0.0); add(70, closed ? "1" : "0")
            for p in pts {
                add(0, "VERTEX"); add(8, layer)
                add(10, p.x); add(20, p.y); add(30, 0.0)
            }
            add(0, "SEQEND"); add(8, layer)
        }

        mutating func circle(_ c: SIMD2<Double>, radius: Double, layer: String) {
            add(0, "CIRCLE"); add(8, layer)
            add(10, c.x); add(20, c.y); add(30, 0.0); add(40, radius)
        }

        /// Текст по центру точки
        mutating func text(_ s: String, at p: SIMD2<Double>, height: Double, angle: Double, layer: String) {
            let clean = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "²", with: "2")
                .replacingOccurrences(of: "Ø", with: "%%c")   // знак диаметра в AutoCAD
            add(0, "TEXT"); add(8, layer)
            add(10, p.x); add(20, p.y); add(30, 0.0)
            add(40, height); add(1, clean)
            if angle != 0 { add(50, angle) }
            add(72, "1"); add(73, "2")
            add(11, p.x); add(21, p.y); add(31, 0.0)
        }

        func save(name: String) -> URL? {
            var out: [String] = []
            let a = { (c: Int, v: String) in out.append("\(c)"); out.append(v) }
            a(0, "SECTION"); a(2, "HEADER")
            a(9, "$ACADVER"); a(1, "AC1009")
            a(9, "$DWGCODEPAGE"); a(3, "ANSI_1251")
            a(9, "$INSUNITS"); a(70, "4")
            a(0, "ENDSEC")
            a(0, "SECTION"); a(2, "TABLES")
            a(0, "TABLE"); a(2, "LTYPE"); a(70, "1")
            a(0, "LTYPE"); a(2, "CONTINUOUS"); a(70, "0"); a(3, "Solid line"); a(72, "65"); a(73, "0"); a(40, "0.0")
            a(0, "ENDTAB")
            a(0, "TABLE"); a(2, "LAYER"); a(70, "\(PlanDXF.layers.count)")
            for l in PlanDXF.layers {
                a(0, "LAYER"); a(2, l.name); a(70, "0"); a(62, "\(l.color)"); a(6, "CONTINUOUS")
            }
            a(0, "ENDTAB")
            a(0, "TABLE"); a(2, "STYLE"); a(70, "1")
            a(0, "STYLE"); a(2, "STANDARD"); a(70, "0"); a(40, "0.0"); a(41, "1.0"); a(50, "0.0"); a(71, "0")
            a(42, "2.5"); a(3, "txt"); a(4, "")
            a(0, "ENDTAB")
            a(0, "ENDSEC")
            a(0, "SECTION"); a(2, "ENTITIES")
            out += body
            a(0, "ENDSEC")
            a(0, "EOF")
            let text = out.joined(separator: "\r\n") + "\r\n"
            guard let data = text.data(using: .windowsCP1251, allowLossyConversion: true) else { return nil }
            let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Чертёж — \(safe).dxf")
            do {
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }
    }
}
