import SwiftUI
import simd

// MARK: - Свет: сколько светильников и где

enum Lighting {
    struct Kind {
        let title: String
        /// Норма СП 52.13330 и комфортная освещённость, лк
        let norm: Int
        let comfort: Int
        let tip: String
    }

    static func kind(_ room: String) -> Kind {
        let r = room.lowercased()
        let has = { (words: [String]) in words.contains { r.contains($0) } }
        if has(["кухн", "столов"]) {
            return Kind(title: "Кухня", norm: 150, comfort: 250,
                        tip: "Над столешницей — отдельная подсветка (лента под шкафами), иначе тень от вас на рабочей зоне.")
        }
        if has(Estimate.wetRooms) {
            return Kind(title: "Ванная, санузел", norm: 50, comfort: 150,
                        tip: "Светильники с защитой IP44 и выше, над ванной и душем — IP65. У зеркала — свет на лицо спереди.")
        }
        if has(["детск"]) {
            return Kind(title: "Детская", norm: 200, comfort: 250, tip: "У стола — отдельная лампа, у кровати — неяркий ночник.")
        }
        if has(["кабинет", "офис"]) {
            return Kind(title: "Кабинет", norm: 300, comfort: 350, tip: "Рабочий стол — с настольной лампой слева (для правши).")
        }
        if has(["коридор", "прихож", "холл", "гардероб"]) {
            return Kind(title: "Коридор, прихожая", norm: 50, comfort: 100, tip: "У зеркала и шкафа — свет поярче, выключатели у входа и у комнат.")
        }
        if has(["спальн"]) {
            return Kind(title: "Спальня", norm: 150, comfort: 150, tip: "У кровати — бра или ночники с выключателем рядом, общий свет — тёплый, 2700–3000 К.")
        }
        return Kind(title: "Жилая комната", norm: 150, comfort: 200,
                    tip: "Общий свет плюс бра или торшер у дивана: вечером уютнее, чем одна люстра.")
    }

    enum Level: String, CaseIterable { case cozy = "Уютно", comfort = "Комфорт", bright = "Ярко" }

    static func lux(_ k: Kind, _ level: Level) -> Int {
        switch level {
        case .cozy: return max(k.norm, k.comfort * 3 / 4)
        case .comfort: return k.comfort
        case .bright: return k.comfort * 3 / 2
        }
    }

    /// Световой поток на комнату, лм: свет теряется на стенах и потолке (×1/0,7), высокий потолок — ещё запас
    static func lumens(lux: Int, area: Double, height: Double) -> Int {
        let kh = height <= 2.75 ? 1.0 : height <= 3.05 ? 1.2 : 1.5
        return Int((Double(lux) * area * kh / 0.7 / 50).rounded(.up)) * 50
    }

    /// Сетка точечных светильников: не меньше count штук, ровно по комнате, не ближе 35 см к стенам
    static func grid(_ plan: [SIMD2<Double>], count: Int) -> [SIMD2<Double>] {
        guard plan.count > 2, count > 0 else { return [] }
        let poly = plan.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        let lo = plan.reduce(plan[0]) { simd_min($0, $1) }, hi = plan.reduce(plan[0]) { simd_max($0, $1) }
        let size = hi - lo
        var area = 0.0
        for (a, b) in zip(plan, plan.dropFirst() + [plan[0]]) { area += a.x * b.y - b.x * a.y }
        var step = (abs(area) / 2 / Double(count)).squareRoot()
        var best: [SIMD2<Double>] = []
        for _ in 0..<60 {
            let cols = max(1, Int((size.x / step).rounded())), rows = max(1, Int((size.y / step).rounded()))
            var pts: [SIMD2<Double>] = []
            for i in 0..<cols {
                for j in 0..<rows {
                    let p = lo + SIMD2((Double(i) + 0.5) * size.x / Double(cols), (Double(j) + 0.5) * size.y / Double(rows))
                    if Room3D.contains(poly, SIMD2(Float(p.x), Float(p.y))) && edgeDistance(plan, p) >= 0.35 { pts.append(p) }
                }
            }
            best = pts
            if pts.count >= count || pts.count >= 40 { break }
            step *= 0.93
        }
        return Array(best.prefix(40))
    }

    private static func edgeDistance(_ plan: [SIMD2<Double>], _ p: SIMD2<Double>) -> Double {
        var best = Double.greatestFiniteMagnitude
        for (a, b) in zip(plan, plan.dropFirst() + [plan[0]]) {
            let ab = b - a
            let t = min(max(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-9), 0), 1)
            best = min(best, simd_distance(p, a + ab * t))
        }
        return best
    }
}

struct LightingView: View {
    let result: RoomResult
    @Binding var engineering: Engineering
    @State private var level = Lighting.Level.comfort
    @State private var spotLumens = 500
    @State private var placed: Int?

    var body: some View {
        let kind = Lighting.kind(result.room)
        let lux = Lighting.lux(kind, level)
        let height = result.height > 0 ? result.height : 2.7
        let total = Lighting.lumens(lux: lux, area: result.floorArea, height: height)
        let need = max(1, Int((Double(total) / Double(spotLumens)).rounded(.up)))
        let spots = Lighting.grid(result.plan, count: need)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Яркость", selection: $level) {
                    ForEach(Lighting.Level.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                plan(spots)
                    .frame(height: 260)
                    .padding(12)
                    .background(Palette.black, in: RoundedRectangle(cornerRadius: 22))
                VStack(alignment: .leading, spacing: 8) {
                    row("Комната", "\(kind.title), \(m2(result.floorArea))")
                    row("Освещённость", "\(lux) лк (норма СП — \(kind.norm) лк)")
                    row("Нужно света всего", "\(total) лм ≈ \(max(1, total / 100)) Вт LED")
                    Divider()
                    row("Точечные по \(spotLumens) лм", "\(spots.count) шт.", bold: true)
                    row("Или люстра + бра", "люстра \(total * 7 / 10 / 50 * 50) лм и 2 бра")
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                Picker("Светильник", selection: $spotLumens) {
                    Text("400 лм (5 Вт)").tag(400)
                    Text("500 лм (7 Вт)").tag(500)
                    Text("650 лм (9 Вт)").tag(650)
                }
                .pickerStyle(.segmented)
                Button { place(spots) } label: {
                    Label(placed == nil ? "Поставить \(spots.count) точек в «Электрику»" : "Поставлено \(placed ?? 0) — смотрите в «Электрике»",
                          systemImage: placed == nil ? "lightbulb.2" : "checkmark")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Palette.signal, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Palette.ink)
                }
                .disabled(spots.isEmpty)
                Text("Светильники встанут на потолок в «Электрике» вместо прежних точек света: там их можно подвинуть и протянуть к ним провод. \(kind.tip)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Цвет света: в спальне и гостиной 2700–3000 К, на кухне и в ванной 3000–4000 К, в кабинете 4000 К. Расчёт по площади и высоте потолка \(String(format: "%.2f", height)) м, с запасом на светлые стены.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Свет")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: level) { _ in placed = nil }
        .onChange(of: spotLumens) { _ in placed = nil }
    }

    private func row(_ t: String, _ v: String, bold: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(t)
            Spacer()
            Text(v).fontWeight(bold ? .bold : .semibold).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func m2(_ v: Double) -> String { String(format: "%.1f м²", v).replacingOccurrences(of: ".", with: ",") }

    /// План комнаты сверху с точками света и пятнами от них
    private func plan(_ spots: [SIMD2<Double>]) -> some View {
        Canvas { ctx, size in
            let pts = result.plan
            guard pts.count > 2 else { return }
            let lo = pts.reduce(pts[0]) { simd_min($0, $1) }, hi = pts.reduce(pts[0]) { simd_max($0, $1) }
            let k = min(size.width / max(hi.x - lo.x, 0.1), size.height / max(hi.y - lo.y, 0.1))
            let ox = (size.width - (hi.x - lo.x) * k) / 2, oy = (size.height - (hi.y - lo.y) * k) / 2
            let map = { (p: SIMD2<Double>) in CGPoint(x: ox + (p.x - lo.x) * k, y: oy + (p.y - lo.y) * k) }
            var room = Path()
            room.addLines(pts.map(map))
            room.closeSubpath()
            ctx.fill(room, with: .color(.white.opacity(0.06)))
            ctx.clip(to: room)
            let r = CGFloat(1.3 * k)
            for s in spots {
                let c = map(s)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                         with: .radialGradient(Gradient(colors: [Palette.signal.opacity(0.45), .clear]), center: c, startRadius: 0, endRadius: r))
            }
            for s in spots {
                let c = map(s)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(Palette.signal))
            }
            ctx.stroke(room, with: .color(.white), lineWidth: 3)
        }
    }

    private func place(_ spots: [SIMD2<Double>]) {
        var e = engineering
        e.points.removeAll { $0.kind == "ceiling_light" }
        let h = result.height > 0 ? result.height : 2.7
        for s in spots where e.points.count < Engineering.maxPoints {
            e.points.append(Engineering.Point(kind: "ceiling_light", wall: nil, offset: 0, x: s.x, y: s.y, height: h))
        }
        engineering = e
        placed = e.points.filter { $0.kind == "ceiling_light" }.count
    }
}
