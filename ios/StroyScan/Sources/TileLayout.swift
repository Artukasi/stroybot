import SwiftUI
import simd

/// Раскладка плитки и ламината по настоящему контуру пола: где целые, где подрезка,
/// узкие полоски (их видно красным), сколько штук и упаковок купить.
enum TileLayout {
    enum Material: String, CaseIterable {
        case tile = "Плитка"
        case laminate = "Ламинат"
    }

    enum Start: String, CaseIterable {
        case center = "По центру"
        case corner = "От угла"
    }

    struct Piece {
        let rect: CGRect          // метры, координаты плана
        let poly: [SIMD2<Double>] // что остаётся после подрезки по стенам
        let area: Double
        let full: Bool
        /// Узкая подрезка: меньше четверти по ширине или длине
        let narrow: Bool
    }

    struct Result {
        let pieces: [Piece]
        let full: Int
        let cut: Int
        let narrow: Int
        let buy: Int
        let area: Double
        /// Для ламината: обрезки переносятся на следующий ряд
        let note: String
    }

    /// Обрезка многоугольника прямоугольником (Сазерленд — Ходжман): прямоугольник выпуклый, пол может быть Г-образным
    static func clip(_ poly: [SIMD2<Double>], to r: CGRect) -> [SIMD2<Double>] {
        var out = poly
        let edges: [(SIMD2<Double>) -> Double] = [
            { $0.x - Double(r.minX) }, { Double(r.maxX) - $0.x }, { $0.y - Double(r.minY) }, { Double(r.maxY) - $0.y },
        ]
        for inside in edges {
            guard !out.isEmpty else { break }
            let input = out
            out = []
            for i in input.indices {
                let a = input[i], b = input[(i + 1) % input.count]
                let da = inside(a), db = inside(b)
                if da >= 0 { out.append(a) }
                if (da >= 0) != (db >= 0) {
                    let t = da / (da - db)
                    out.append(a + (b - a) * t)
                }
            }
        }
        return out
    }

    static func area(_ p: [SIMD2<Double>]) -> Double {
        guard p.count > 2 else { return 0 }
        var s = 0.0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return abs(s) / 2
    }

    /// w, h — размер плитки или доски (м), joint — шов (м). turned — поперёк длинной стены.
    /// shift — разбежка рядов ламината (доля длины доски); reserve — запас
    static func lay(_ plan: [SIMD2<Double>], material: Material, w: Double, h: Double, joint: Double,
                    turned: Bool, start: Start, shift: Double, perPack: Int) -> Result? {
        guard plan.count > 2, w > 0.02, h > 0.02 else { return nil }
        // поворот на 90° — просто меняем оси местами у пола, потом обратно
        let floor = turned ? plan.map { SIMD2($0.y, $0.x) } : plan
        guard let minX = floor.map(\.x).min(), let maxX = floor.map(\.x).max(),
              let minY = floor.map(\.y).min(), let maxY = floor.map(\.y).max() else { return nil }
        let stepX = w + joint, stepY = h + joint
        guard (maxX - minX) / stepX * (maxY - minY) / stepY < 6000 else { return nil }   // слишком мелко для экрана

        // начало: от угла — с края; по центру — подрезка по краям одинаковая
        func origin(_ lo: Double, _ hi: Double, _ step: Double) -> Double {
            guard start == .center else { return lo }
            let span = hi - lo
            let mid = lo + span / 2
            // либо шов, либо середина плитки по центру — выбираем, где крайние куски шире
            let a = mid - (span / 2 / step).rounded(.up) * step
            let b = mid - step / 2 - ((span / 2 - step / 2) / step).rounded(.up) * step
            let edgeA = (lo - a).truncatingRemainder(dividingBy: step), edgeB = (lo - b).truncatingRemainder(dividingBy: step)
            return step - edgeA >= step - edgeB ? a : b
        }
        let ox = origin(minX, maxX, stepX), oy = origin(minY, maxY, stepY)

        var pieces: [Piece] = []
        var row = 0
        var y = oy
        while y < maxY {
            // ламинат: ряды сдвинуты на разбежку
            var x = ox - (material == .laminate ? (Double(row) * shift).truncatingRemainder(dividingBy: 1) * stepX : 0)
            while x < maxX {
                let rect = CGRect(x: x, y: y, width: w, height: h)
                let poly = clip(floor, to: rect)
                let a = area(poly)
                if a > 0.0001 {
                    let full = a > w * h * 0.985
                    let bw = (poly.map(\.x).max() ?? 0) - (poly.map(\.x).min() ?? 0)
                    let bh = (poly.map(\.y).max() ?? 0) - (poly.map(\.y).min() ?? 0)
                    let narrow = !full && (bw < w * 0.25 || bh < h * 0.25)
                    let back = turned ? poly.map { SIMD2($0.y, $0.x) } : poly
                    let r = turned ? CGRect(x: y, y: x, width: h, height: w) : rect
                    pieces.append(Piece(rect: r, poly: back, area: a, full: full, narrow: narrow))
                }
                x += stepX
            }
            y += stepY
            row += 1
        }
        let full = pieces.filter(\.full).count
        let cut = pieces.count - full
        let narrow = pieces.filter(\.narrow).count
        let floorArea = area(plan)
        let buy: Int
        let note: String
        if material == .laminate {
            // обрезок с конца ряда идёт в начало следующего, если он не короче 30 см — считаем по длине
            let boardsByArea = (pieces.reduce(0) { $0 + $1.area } / (w * h)).rounded(.up)
            buy = Int((boardsByArea * 1.07).rounded(.up))
            note = "Ламинат: +7% на подрезку. Обрезок с конца ряда кладите в начало следующего, если он длиннее 30 см."
        } else {
            buy = Int((Double(full + cut) * 1.05).rounded(.up))
            note = "Плитка: каждая подрезанная — отдельная плитка, плюс 5% на бой."
        }
        _ = perPack
        return Result(pieces: pieces, full: full, cut: cut, narrow: narrow, buy: buy, area: floorArea, note: note)
    }
}

struct TileLayoutView: View {
    let result: RoomResult
    @AppStorage("tile.material") private var materialRaw = TileLayout.Material.tile.rawValue
    @AppStorage("tile.w") private var tileW = 60.0
    @AppStorage("tile.h") private var tileH = 60.0
    @AppStorage("tile.joint") private var joint = 2.0
    @AppStorage("lam.w") private var lamW = 138.0
    @AppStorage("lam.h") private var lamH = 19.3
    @AppStorage("lam.pack") private var lamPack = 8
    @AppStorage("tile.pack") private var tilePack = 4
    @State private var turned = false
    @State private var start = TileLayout.Start.center
    @State private var shift = 1.0 / 3
    @State private var shown: CGFloat = 0
    @State private var layout: TileLayout.Result?

    private var material: TileLayout.Material { TileLayout.Material(rawValue: materialRaw) ?? .tile }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Материал", selection: $materialRaw) {
                    ForEach(TileLayout.Material.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)

                canvas
                    .frame(height: 300)
                    .padding(14)
                    .background(Palette.ink, in: RoundedRectangle(cornerRadius: 22))

                if let l = layout { numbers(l) }
                settings
            }
            .padding()
        }
        .navigationTitle("Раскладка · \(result.room)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: recompute)
        .onChange(of: materialRaw) { _ in recompute() }
        .onChange(of: tileW) { _ in recompute() }
        .onChange(of: tileH) { _ in recompute() }
        .onChange(of: joint) { _ in recompute() }
        .onChange(of: lamW) { _ in recompute() }
        .onChange(of: lamH) { _ in recompute() }
        .onChange(of: turned) { _ in recompute() }
        .onChange(of: start) { _ in recompute() }
        .onChange(of: shift) { _ in recompute() }
    }

    private func recompute() {
        let tile = material == .tile
        layout = TileLayout.lay(result.plan, material: material,
                                w: (tile ? tileW : lamW) / 100, h: (tile ? tileH : lamH) / 100,
                                joint: tile ? joint / 1000 : 0, turned: turned, start: start, shift: shift,
                                perPack: tile ? tilePack : lamPack)
        shown = 0
        withAnimation(.easeOut(duration: 1.1)) { shown = 1 }
    }

    // MARK: - Чертёж

    private var canvas: some View {
        let plan = result.plan
        let l = layout
        return Canvas { ctx, size in
            guard let f = planFrame(plan, in: CGRect(origin: .zero, size: size)) else { return }
            let map = { (p: SIMD2<Double>) in CGPoint(x: f.ox + CGFloat(p.x) * f.k, y: f.oy + CGFloat(p.y) * f.k) }
            var floor = Path()
            floor.addLines(plan.map(map))
            floor.closeSubpath()
            ctx.fill(floor, with: .color(.white.opacity(0.06)))
            if let l {
                let total = max(l.pieces.count, 1)
                for (i, p) in l.pieces.enumerated() where CGFloat(i) / CGFloat(total) <= shown {
                    var path = Path()
                    path.addLines(p.poly.map(map))
                    path.closeSubpath()
                    let color: Color = p.full ? Color(white: 0.92) : (p.narrow ? .red : Palette.signal)
                    ctx.fill(path, with: .color(color.opacity(p.full ? 0.85 : 0.75)))
                    ctx.stroke(path, with: .color(Palette.ink.opacity(0.55)), lineWidth: material == .tile ? 1 : 0.6)
                }
            }
            ctx.stroke(floor, with: .color(Palette.signal), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
        }
    }

    private func numbers(_ l: TileLayout.Result) -> some View {
        let pack = material == .tile ? tilePack : lamPack
        let unit = material == .tile ? "плиток" : "досок"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                stat("Целых", "\(l.full)", Color(white: 0.85))
                stat("Подрезка", "\(l.cut)", Palette.signal)
                stat("Узкие", "\(l.narrow)", .red)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Купить").font(.headline)
                Spacer()
                Text("\(l.buy) \(unit)").font(.title3.bold()).monospacedDigit()
                if pack > 0 {
                    Text("≈ \(Int((Double(l.buy) / Double(pack)).rounded(.up))) уп.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if l.narrow > 0 {
                Label("Красные — узкие полоски меньше четверти \(material == .tile ? "плитки" : "доски"). Попробуйте «По центру» или поверните раскладку.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            Text(l.note).font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.title2.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            if material == .tile {
                field("Плитка, см", $tileW, $tileH)
                stepper("Шов", value: $joint, range: 0...10, step: 0.5, unit: "мм")
                Stepper("В упаковке: \(tilePack) шт", value: $tilePack, in: 1...40)
            } else {
                field("Доска, см", $lamW, $lamH)
                Picker("Разбежка", selection: $shift) {
                    Text("1/2").tag(0.5)
                    Text("1/3").tag(1.0 / 3)
                    Text("1/4").tag(0.25)
                }
                .pickerStyle(.segmented)
                Stepper("В упаковке: \(lamPack) досок", value: $lamPack, in: 1...30)
            }
            Picker("Начало", selection: $start) {
                ForEach(TileLayout.Start.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Toggle(material == .tile ? "Повернуть на 90°" : "Доски поперёк длинной стены", isOn: $turned)
        }
        .font(.subheadline)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func field(_ title: String, _ a: Binding<Double>, _ b: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: a, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 64)
                .textFieldStyle(.roundedBorder)
            Text("×")
            TextField("", value: b, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 64)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func stepper(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        Stepper("\(title): \(fmt(value.wrappedValue)) \(unit)", value: value, in: range, step: step)
    }
}
