import SwiftUI
import simd

/// Тёплый пол: греем только свободный пол — без шкафов, кровати, ванны и техники, с отступом 10 см от стен.
/// Электрический кабель, мат или водяной — сколько метров, какая мощность, сколько петель.
enum WarmFloor {
    enum System: String, CaseIterable {
        case cable = "Кабель"
        case mat = "Мат"
        case water = "Водяной"
    }

    /// Под этим не греем: стоит на полу без ножек и закрывает пол
    static let blocking: Set<String> = ["bed", "sofa", "storage", "refrigerator", "stove", "oven", "washerDryer",
                                        "dishwasher", "bathtub", "toilet", "sink", "fireplace", "stairs"]

    struct Result {
        let floor: Double
        let furniture: Double
        let heated: Double
        let lines: [(String, String)]
    }

    static func furnitureArea(_ r: RoomResult) -> Double {
        r.items.filter { blocking.contains($0.kind) && $0.bottom < 0.15 }.reduce(0) { $0 + $1.width * $1.depth }
    }

    static func calc(_ r: RoomResult, system: System, wet: Bool) -> Result {
        let floor = r.floorArea
        let furniture = min(furnitureArea(r), floor * 0.8)
        let heated = max(0, floor - furniture - r.perimeter * 0.1)
        let power = wet ? 180.0 : 150.0
        var lines: [(String, String)] = []
        switch system {
        case .cable:
            let step = 0.1
            let len = heated / step
            lines = [("Шаг укладки", "10 см"),
                     ("Длина кабеля", "≈ \(Int(len.rounded())) м"),
                     ("Мощность", "\(Int(power)) Вт/м² · \(fmt((heated * power / 100).rounded() / 10)) кВт"),
                     ("Монтажная лента", "\(Int((heated / 0.5 * 1.1).rounded(.up))) м"),
                     ("Терморегулятор с датчиком пола", "1 шт")]
        case .mat:
            lines = [("Мат (рулон)", "\(fmt((heated * 2).rounded(.down) / 2)) м²"),
                     ("Мощность", "\(Int(power)) Вт/м² · \(fmt((heated * power / 100).rounded() / 10)) кВт"),
                     ("Укладка", "под плитку, в клей"),
                     ("Терморегулятор с датчиком пола", "1 шт")]
        case .water:
            let step = 0.15
            let pipe = heated / step + 2 * 5   // плюс подвод от коллектора туда и обратно
            let loops = max(1, Int((pipe / 80).rounded(.up)))
            lines = [("Шаг укладки", "15 см"),
                     ("Труба PE-Xa 16 мм", "≈ \(Int(pipe.rounded())) м"),
                     ("Петель (до 80 м)", "\(loops)"),
                     ("Демпферная лента", "\(Int((r.perimeter * 1.05).rounded(.up))) м"),
                     ("Утеплитель 30 мм", "\(fmt((floor * 1.05 * 10).rounded(.up) / 10)) м²"),
                     ("Стяжка над трубой (≥ 35 мм)", "≈ \(Int((floor * 0.05 * 1000 * 2).rounded())) кг ЦПС")]
        }
        return Result(floor: floor, furniture: furniture, heated: heated, lines: lines)
    }
}

struct WarmFloorView: View {
    let result: RoomResult
    @State private var system = WarmFloor.System.cable
    @State private var drawn: CGFloat = 0

    private var wet: Bool { Estimate.wetRooms.contains { result.room.lowercased().contains($0) } }

    var body: some View {
        let calc = WarmFloor.calc(result, system: system, wet: wet)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Система", selection: $system) {
                    ForEach(WarmFloor.System.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                drawing
                    .frame(height: 290)
                    .padding(14)
                    .background(Palette.ink, in: RoundedRectangle(cornerRadius: 22))
                HStack(spacing: 10) {
                    number("Пол", calc.floor)
                    number("Под мебелью", calc.furniture)
                    number("Греем", calc.heated, accent: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(calc.lines, id: \.0) { t, v in
                        HStack {
                            Text(t)
                            Spacer()
                            Text(v).bold().monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                Text("Под шкафами, кроватью, ванной и техникой пол не греют: перегрев и лишний расход. От стен отступ 10 см. Мощность — \(wet ? "180 Вт/м², помещение влажное" : "150 Вт/м² для комфортного подогрева"). Если сканер не нашёл какую-то мебель, оставьте запас.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Тёплый пол · \(result.room)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { animate() }
        .onChange(of: system) { _ in animate() }
    }

    private func animate() {
        drawn = 0
        withAnimation(.easeInOut(duration: 1.6)) { drawn = 1 }
    }

    private func number(_ t: String, _ v: Double, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                CountUp(value: drawn > 0 ? v : 0, digits: 1).font(.title3.bold()).foregroundStyle(accent ? Color.orange : Color.primary)
                Text("м²").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Змейка нагрева по свободному полу; мебель — серые прямоугольники поверх
    private var drawing: some View {
        let plan = result.plan
        let items = result.items.filter { WarmFloor.blocking.contains($0.kind) && $0.bottom < 0.15 }
        let step = system == .water ? 0.15 : (system == .cable ? 0.1 : 0.5)
        return Canvas { ctx, size in
            guard let f = planFrame(plan, in: CGRect(origin: .zero, size: size)),
                  let maxX = plan.map(\.x).max(), let maxY = plan.map(\.y).max() else { return }
            let map = { (p: SIMD2<Double>) in CGPoint(x: f.ox + CGFloat(p.x) * f.k, y: f.oy + CGFloat(p.y) * f.k) }
            var floor = Path()
            floor.addLines(plan.map(map))
            floor.closeSubpath()
            ctx.fill(floor, with: .color(.white.opacity(0.05)))

            // змейка внутри пола с отступом
            var snake = Path()
            var y = 0.1, leftToRight = true
            snake.move(to: map(SIMD2(0.1, y)))
            while y <= maxY - 0.1 {
                let x = leftToRight ? maxX - 0.1 : 0.1
                snake.addLine(to: map(SIMD2(x, y)))
                let ny = y + step
                if ny <= maxY - 0.1 { snake.addLine(to: map(SIMD2(x, ny))) }
                y = ny
                leftToRight.toggle()
            }
            var inner = ctx
            inner.clip(to: floor)
            let color: Color = system == .water ? Color(red: 1, green: 0.45, blue: 0.2) : .orange
            if system == .mat {
                inner.fill(floor, with: .color(color.opacity(0.25 * Double(drawn))))
            }
            inner.stroke(snake.trimmedPath(from: 0, to: drawn), with: .color(color),
                         style: StrokeStyle(lineWidth: system == .mat ? 1 : 1.6, lineCap: .round, lineJoin: .round))
            // мебель закрывает змейку
            for it in items {
                let w = CGFloat(it.width) * f.k, d = CGFloat(it.depth) * f.k
                let c = map(SIMD2(it.x, it.y))
                let rect = Path(roundedRect: CGRect(x: -w / 2, y: -d / 2, width: w, height: d), cornerRadius: 3)
                    .applying(CGAffineTransform(rotationAngle: CGFloat(it.angle)).concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
                inner.fill(rect, with: .color(Palette.ink))
                inner.fill(rect, with: .color(.white.opacity(0.18)))
                inner.stroke(rect, with: .color(.white.opacity(0.5)), lineWidth: 1)
                if w > 40 && d > 16 {
                    inner.draw(Text(it.title).font(.system(size: 9, weight: .semibold)).foregroundColor(.white.opacity(0.8)), at: c)
                }
            }
            ctx.stroke(floor, with: .color(Palette.signal), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
        }
    }
}
