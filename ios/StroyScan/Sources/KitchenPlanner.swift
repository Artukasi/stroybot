import SwiftUI
import simd

/// Кухня по размерам: модули 60/45/40/30… вдоль выбранной стены. Мойка встаёт к выводу воды или канализации,
/// плита — к силовой розетке, холодильник — с краю, двери обходим, окна оставляют место без верхних шкафов.
enum KitchenPlanner {
    struct Module: Identifiable {
        let id = UUID()
        var kind: Kind
        var start: Double   // см от начала стены
        var width: Double   // см
    }

    enum Kind: String {
        case sink = "Мойка"
        case stove = "Плита"
        case fridge = "Холодильник"
        case dishwasher = "Посудомойка"
        case drawers = "Ящики"
        case cabinet = "Тумба"
        case bottle = "Бутылочница"
        case filler = "Добор"

        var color: Color {
            switch self {
            case .sink: return Color(EngKind.coldColor)
            case .stove: return .orange
            case .fridge: return Color(white: 0.8)
            case .dishwasher: return .teal
            case .drawers: return Palette.signal
            case .cabinet: return Color(red: 0.95, green: 0.88, blue: 0.62)
            case .bottle: return .purple.opacity(0.6)
            case .filler: return .gray.opacity(0.4)
            }
        }
    }

    struct Plan {
        var modules: [Module]
        /// Места, где не будет верхних шкафов: окна и вытяжка
        var noUpper: [ClosedRange<Double>]
        var length: Double
        var notes: [String]
    }

    static let widths: [Double] = [80, 60, 50, 45, 40, 30, 20]

    /// Заполнить промежуток модулями так, чтобы осталось меньше всего, и модулей было поменьше
    static func fill(_ gap: Double) -> [Double] {
        let n = Int(gap.rounded(.down))
        guard n >= 15 else { return [] }
        var best = [Int: [Double]]()
        best[0] = []
        for w in 0...n {
            guard let cur = best[w] else { continue }
            for m in widths {
                let nw = w + Int(m)
                guard nw <= n else { continue }
                if best[nw] == nil || best[nw]!.count > cur.count + 1 { best[nw] = cur + [m] }
            }
        }
        let reach = best.keys.max() ?? 0
        // широкие модули — к краям, узкие — в середину выглядит аккуратнее
        return (best[reach] ?? []).sorted(by: >)
    }

    static func plan(_ r: RoomResult, wall: Int, fridgeLeft: Bool, dishwasher: Bool) -> Plan? {
        guard wall >= 0, wall < r.wallLines.count else { return nil }
        let l = r.wallLines[wall]
        let length = (simd_distance(SIMD2(l.x, l.y), SIMD2(l.z, l.w)) * 100).rounded()
        guard length >= 120 else { return nil }
        var notes: [String] = []
        // двери на этой стене — туда шкафы не ставим
        var blocked: [ClosedRange<Double>] = []
        var noUpper: [ClosedRange<Double>] = []
        for o in r.openings where o.wall == wall {
            guard let off = o.offset else { continue }
            let a = max(0, (off - o.width / 2) * 100 - 5), b = min(length, (off + o.width / 2) * 100 + 5)
            guard a < b else { continue }
            if o.kind == "window" && (o.bottom ?? 0.9) >= 0.8 {
                noUpper.append(a...b)
            } else {
                blocked.append(a...b)
            }
        }
        // самый длинный свободный кусок стены
        var free: [ClosedRange<Double>] = []
        var cursor = 0.0
        for b in blocked.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if b.lowerBound - cursor >= 60 { free.append(cursor...b.lowerBound) }
            cursor = max(cursor, b.upperBound)
        }
        if length - cursor >= 60 { free.append(cursor...length) }
        guard let run = free.max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }) else { return nil }
        if !blocked.isEmpty { notes.append("На стене дверь — кухня встала на свободный кусок \(Int(run.upperBound - run.lowerBound)) см.") }

        var fixed: [Module] = []
        // холодильник — с края
        let fridgeAt = fridgeLeft ? run.lowerBound : run.upperBound - 60
        fixed.append(Module(kind: .fridge, start: fridgeAt, width: 60))
        let usable = fridgeLeft ? (run.lowerBound + 60)...run.upperBound : run.lowerBound...(run.upperBound - 60)

        // мойка — к выводу воды или канализации на этой стене, иначе у окна, иначе посередине
        let wet = r.engineering.points.filter { $0.wall == wall && ["cold", "hot", "sewer50", "washer"].contains($0.kind) }
        let window = noUpper.first.map { ($0.lowerBound + $0.upperBound) / 2 }
        let sinkCenter: Double
        if let w = wet.map({ $0.offset * 100 }).sorted().first {
            sinkCenter = w
            notes.append("Мойка — у вывода воды (\(Int(w)) см от угла).")
        } else if let window {
            sinkCenter = window
            notes.append("Вывода воды на этой стене нет — мойка под окном. Отметьте воду в «Сантехнике», чтобы мойка встала к ней.")
        } else {
            sinkCenter = (usable.lowerBound + usable.upperBound) / 2
            notes.append("Вывода воды на этой стене нет — мойка посередине.")
        }
        let snap = { (v: Double) in (v / 5).rounded() * 5 }
        let sinkStart = snap(min(max(sinkCenter - 30, usable.lowerBound), usable.upperBound - 60))
        var used: [Module] = [Module(kind: .sink, start: sinkStart, width: 60)]
        if dishwasher {
            // посудомойка рядом с мойкой — с той стороны, где больше места
            let left = sinkStart - usable.lowerBound, right = usable.upperBound - sinkStart - 60
            if right >= 60 { used.append(Module(kind: .dishwasher, start: sinkStart + 60, width: 60)) }
            else if left >= 60 { used.append(Module(kind: .dishwasher, start: sinkStart - 60, width: 60)) }
            else if right >= 45 { used.append(Module(kind: .dishwasher, start: sinkStart + 60, width: 45)) }
            else { notes.append("Посудомойке не хватило места.") }
        }
        // плита — к силовой розетке, иначе не ближе 40 см от мойки, где больше места
        let power = r.engineering.points.first { $0.wall == wall && $0.kind == "socket_power" }.map { $0.offset * 100 }
        let taken = { (a: Double, w: Double) in used.contains { $0.start < a + w && a < $0.start + $0.width } }
        var stoveStart: Double?
        var candidates: [Double] = []
        if let power { candidates.append(snap(power - 30)) }
        let lo = used.map(\.start).min() ?? sinkStart, hi = used.map { $0.start + $0.width }.max() ?? sinkStart + 60
        candidates += [hi + 40, lo - 40 - 60, hi + 60, lo - 120, hi + 20, lo - 80]
        for c in candidates where c >= usable.lowerBound && c + 60 <= usable.upperBound && !taken(c, 60) {
            // между плитой и мойкой — хотя бы 40 см рабочей поверхности, если места хватает
            stoveStart = c
            break
        }
        if let s = stoveStart {
            used.append(Module(kind: .stove, start: s, width: 60))
            noUpper.append(s...(s + 60))   // над плитой вытяжка
            if power != nil { notes.append("Плита — у силовой розетки.") }
        } else {
            notes.append("Плите не хватило места на этой стене — попробуйте другую стену.")
        }
        // промежутки — ящики и тумбы
        var filled: [Module] = []
        var pos = usable.lowerBound
        for m in used.sorted(by: { $0.start < $1.start }) + [Module(kind: .filler, start: usable.upperBound, width: 0)] {
            let gap = m.start - pos
            if gap > 0 {
                var x = pos
                let parts = fill(gap)
                for (i, w) in parts.enumerated() {
                    let kind: Kind = w <= 20 ? .bottle : (i == 0 && w >= 45 ? .drawers : .cabinet)
                    filled.append(Module(kind: kind, start: x, width: w))
                    x += w
                }
                if m.start - x >= 1 { filled.append(Module(kind: .filler, start: x, width: m.start - x)) }
            }
            pos = max(pos, m.start + m.width)
        }
        return Plan(modules: (fixed + used + filled).filter { $0.width > 0 }.sorted { $0.start < $1.start },
                    noUpper: noUpper, length: length, notes: notes)
    }
}

struct KitchenView: View {
    let result: RoomResult
    @State private var wall = 0
    @State private var fridgeLeft = true
    @State private var dishwasher = true
    @State private var shown = false

    private var plan: KitchenPlanner.Plan? {
        KitchenPlanner.plan(result, wall: wall, fridgeLeft: fridgeLeft, dishwasher: dishwasher)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                wallPicker
                if let p = plan {
                    elevation(p)
                        .frame(height: 230)
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                    list(p)
                    ForEach(p.notes, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("Эта стена короче 1,2 м или вся занята дверью — выберите другую.").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Toggle("Холодильник слева", isOn: $fridgeLeft)
                    Toggle("Посудомойка", isOn: $dishwasher)
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                Text("Ширины — стандартные модули кухонь (ИКЕА, Леруа, кухни на заказ). Глубина низа 60 см, высота 85 см, верх 72 см.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Кухня · \(result.room)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // по умолчанию — стена с выводом воды, иначе самая длинная
            if let w = result.engineering.points.first(where: { ["cold", "sewer50"].contains($0.kind) })?.wall {
                wall = w
            } else if let longest = result.walls.indices.max(by: { result.walls[$0].length < result.walls[$1].length }) {
                wall = longest
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) { shown = true }
        }
        .onChange(of: wall) { _ in replay() }
        .onChange(of: fridgeLeft) { _ in replay() }
        .onChange(of: dishwasher) { _ in replay() }
    }

    private func replay() {
        shown = false
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { shown = true }
    }

    private var wallPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Стена (номер как на плане)").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(result.wallLines.indices, id: \.self) { i in
                        let l = result.wallLines[i]
                        let len = simd_distance(SIMD2(l.x, l.y), SIMD2(l.z, l.w))
                        Button { wall = i } label: {
                            VStack(spacing: 1) {
                                Text("№\(i + 1)").font(.subheadline.bold())
                                Text("\(fmt((len * 100).rounded() / 100)) м").font(.caption2)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(wall == i ? Palette.signal : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(wall == i ? Palette.ink : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Вид на стену спереди: низ, верх, окна, вытяжка над плитой
    private func elevation(_ p: KitchenPlanner.Plan) -> some View {
        GeometryReader { geo in
            let k = geo.size.width / CGFloat(p.length)
            let floorY = geo.size.height - 4
            let cm = { (v: Double) in CGFloat(v) * k }
            let h = { (v: Double) in floorY - CGFloat(v) * min(k, geo.size.height / 270) }
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(.tertiarySystemFill)).frame(width: geo.size.width, height: 2).offset(y: floorY)
                // окна
                ForEach(Array(result.openings.enumerated()), id: \.offset) { _, o in
                    if o.wall == wall, let off = o.offset {
                        let bottom = (o.bottom ?? 0) * 100, top = bottom + o.height * 100
                        Rectangle().fill(o.kind == "window" ? Color.cyan.opacity(0.25) : Color.brown.opacity(0.25))
                            .overlay(Rectangle().stroke(o.kind == "window" ? Color.cyan : Color.brown, lineWidth: 1))
                            .frame(width: cm(o.width * 100), height: h(bottom) - h(top))
                            .offset(x: cm((off - o.width / 2) * 100), y: h(top))
                    }
                }
                ForEach(Array(p.modules.enumerated()), id: \.element.id) { i, m in
                    let tall = m.kind == .fridge
                    let top = tall ? 200.0 : 85
                    RoundedRectangle(cornerRadius: 3)
                        .fill(m.kind.color)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.ink.opacity(0.6), lineWidth: 1))
                        .overlay(
                            VStack(spacing: 1) {
                                if m.width >= 40 { Text(m.kind.rawValue).font(.system(size: 8, weight: .bold)).lineLimit(1) }
                                Text("\(Int(m.width))").font(.system(size: 9, weight: .heavy)).monospacedDigit()
                            }
                            .foregroundStyle(Palette.ink)
                            .minimumScaleFactor(0.5)
                        )
                        .frame(width: max(1, cm(m.width) - 1), height: h(0) - h(top))
                        .offset(x: cm(m.start), y: shown ? h(top) : floorY)
                        .opacity(shown ? 1 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.75).delay(Double(i) * 0.05), value: shown)
                    // верхние шкафы — кроме окон, вытяжки и холодильника
                    if !tall && m.kind != .filler && upper(m, p) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(m.kind.color.opacity(0.45))
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.ink.opacity(0.4), lineWidth: 1))
                            .frame(width: max(1, cm(m.width) - 1), height: h(140) - h(212))
                            .offset(x: cm(m.start), y: h(212))
                            .opacity(shown ? 1 : 0)
                            .animation(.easeOut(duration: 0.4).delay(0.3 + Double(i) * 0.05), value: shown)
                    }
                    if m.kind == .stove {
                        Path { path in
                            let x0 = cm(m.start), x1 = cm(m.start + m.width)
                            path.move(to: CGPoint(x: x0, y: h(150)))
                            path.addLine(to: CGPoint(x: x1, y: h(150)))
                            path.addLine(to: CGPoint(x: x0 + (x1 - x0) * 0.65, y: h(175)))
                            path.addLine(to: CGPoint(x: x0 + (x1 - x0) * 0.35, y: h(175)))
                            path.closeSubpath()
                        }
                        .fill(Color.gray.opacity(0.5))
                        .opacity(shown ? 1 : 0)
                    }
                }
            }
        }
    }

    /// Верхний шкаф над модулем — если он не больше чем наполовину под окном или вытяжкой
    private func upper(_ m: KitchenPlanner.Module, _ p: KitchenPlanner.Plan) -> Bool {
        !p.noUpper.contains { r in
            max(0, min(r.upperBound, m.start + m.width) - max(r.lowerBound, m.start)) > m.width / 2
        }
    }

    private func list(_ p: KitchenPlanner.Plan) -> some View {
        let counted = Dictionary(grouping: p.modules.filter { $0.kind != .filler }) { "\($0.kind.rawValue) \(Int($0.width)) см" }
            .map { ($0.key, $0.value.count) }.sorted { $0.0 < $1.0 }
        let total = p.modules.filter { $0.kind != .fridge && $0.kind != .filler }.reduce(0) { $0 + $1.width }
        let fillers = p.modules.filter { $0.kind == .filler }.reduce(0) { $0 + $1.width }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Модули").font(.headline)
            ForEach(counted, id: \.0) { name, n in
                HStack {
                    Text(name)
                    Spacer()
                    Text("\(n) шт").bold().monospacedDigit()
                }
                .font(.subheadline)
            }
            Divider()
            HStack {
                Text("Столешница")
                Spacer()
                Text("\(fmt((total / 100 * 10).rounded(.up) / 10)) м").bold()
            }
            .font(.subheadline)
            if fillers >= 1 {
                Text("Добор \(Int(fillers.rounded())) см — закрывается панелью в цвет фасадов.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}
