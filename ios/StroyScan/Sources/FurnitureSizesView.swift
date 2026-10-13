import SwiftUI
import simd

/// Вещь из скана: сколько места у неё есть и ссылки на поиск в магазинах
struct FurnitureOffer: Identifiable {
    struct Shop: Identifiable {
        let id: String
        let url: URL
    }

    let id: Int
    let title: String
    /// Размер сейчас: «200 × 90 × 85 см»
    let now: String?
    /// Сколько места есть: «240 × 100 см»
    let limit: String?
    let note: String
    let shops: [Shop]
}

/// Мебель по размерам прямо в телефоне (то же, что считает бот в furniture.py, попроще)
enum FurnitureFit {
    static let passage = 0.7      // проход перед мебелью
    static let touch = 0.35       // ближе — стоит «у стены»
    static let skip: Set<String> = ["stairs", "fireplace", "object"]
    static let furnitureOnly: Set<String> = ["sofa", "bed", "chair", "table", "storage"]
    static let shops: [(String, String)] = [
        ("Яндекс Маркет", "https://market.yandex.ru/search?text="),
        ("Ozon", "https://www.ozon.ru/search/?text="),
        ("Wildberries", "https://www.wildberries.ru/catalog/0/search.aspx?search="),
        ("Divan.ru", "https://www.divan.ru/search?ProductSearch%5Bname%5D="),
    ]
    /// больше этого (ширина, глубина, м) такую вещь не делают
    static let caps: [String: (Double, Double)] = [
        "sofa": (4.0, 2.0), "bed": (2.2, 2.3), "chair": (1.0, 1.0), "table": (3.0, 1.4), "storage": (3.0, 0.7),
        "refrigerator": (1.0, 0.8), "stove": (0.9, 0.7), "oven": (0.9, 0.7), "sink": (1.2, 0.7), "toilet": (0.5, 0.8),
        "bathtub": (2.0, 1.0), "washerDryer": (0.7, 0.7), "television": (2.5, 0.5), "dishwasher": (0.7, 0.7),
    ]
    static let nouns: [String: String] = [
        "sofa": "диван", "bed": "кровать", "chair": "стул", "table": "стол", "storage": "шкаф",
        "refrigerator": "холодильник", "stove": "плита", "oven": "духовка", "sink": "раковина",
        "toilet": "унитаз", "bathtub": "ванна", "washerDryer": "стиральная машина", "television": "телевизор",
        "dishwasher": "посудомойка",
    ]
    static let variantNouns: [String: String] = [
        "straight": "прямой диван", "corner": "угловой диван", "chesterfield": "диван честерфилд",
        "modular": "модульный диван", "platform": "кровать-подиум", "upholstered": "мягкая кровать",
        "classic": "классическая кровать", "dining": "обеденный стул", "armchair": "кресло", "stool": "табурет",
        "dining_rect": "прямоугольный обеденный стол", "dining_round": "круглый обеденный стол",
        "coffee": "журнальный столик", "desk": "письменный стол", "wardrobe": "шкаф", "dresser": "комод",
        "shelving": "стеллаж", "tv_stand": "тумба под ТВ",
    ]
    static let tvInches = [24, 32, 43, 50, 55, 65, 75, 85, 98]

    struct Box {
        let kind: String
        let variant: String?
        let x, y, w, d, h, angle: Double
        var u: SIMD2<Double> { SIMD2(cos(angle), sin(angle)) }
        var v: SIMD2<Double> { SIMD2(-sin(angle), cos(angle)) }
        func point(_ a: Double, _ b: Double) -> SIMD2<Double> {
            SIMD2(x, y) + u * (a * w / 2) + v * (b * d / 2)
        }
        var corners: [SIMD2<Double>] { [point(-1, -1), point(1, -1), point(1, 1), point(-1, 1)] }
        var segs: [(SIMD2<Double>, SIMD2<Double>)] {
            let c = corners
            return (0..<4).map { (c[$0], c[($0 + 1) % 4]) }
        }
    }

    static func links(_ query: String, kind: String) -> [FurnitureOffer.Shop] {
        return shops.compactMap { name, base in
            guard name != "Divan.ru" || furnitureOnly.contains(kind),
                  let url = ShopSearch.url(base, query) else { return nil }
            return FurnitureOffer.Shop(id: name, url: url)
        }
    }

    static func offers(_ r: RoomResult, look: Look?) -> [FurnitureOffer] {
        var boxes: [Box] = []
        for (i, it) in r.items.enumerated() {
            let ch = look?.objects[String(i)]
            if ch?.hidden == true { continue }
            boxes.append(Box(kind: it.kind, variant: ch?.variant, x: it.x, y: it.y, w: max(it.width, 0.01),
                             d: max(it.depth, 0.01), h: it.height, angle: it.angle))
        }
        for a in look?.added ?? [] {
            boxes.append(Box(kind: a.kind, variant: a.variant == "default" ? nil : a.variant, x: a.x, y: a.y,
                             w: a.width, d: a.depth, h: a.height, angle: a.angle))
        }
        var walls: [(SIMD2<Double>, SIMD2<Double>)] = []
        let p = r.plan
        if p.count >= 3 { walls += p.indices.map { (p[$0], p[($0 + 1) % p.count]) } }
        walls += r.wallLines.map { (SIMD2($0.x, $0.y), SIMD2($0.z, $0.w)) }
        var out: [FurnitureOffer] = []
        for (n, b) in boxes.enumerated() where !skip.contains(b.kind) {
            var segs = walls
            for (j, o) in boxes.enumerated() where j != n {
                if Set([o.kind, b.kind]) == ["chair", "table"] || overlaps(o, b) { continue }
                segs += o.segs
            }
            out.append(offer(b, segs: segs, plan: p, id: n))
        }
        return out
    }

    private static func offer(_ b: Box, segs: [(SIMD2<Double>, SIMD2<Double>)], plan: [SIMD2<Double>], id: Int) -> FurnitureOffer {
        func clear(_ a: Double, _ c: Double) -> Double {
            let dir = b.u * a + b.v * c
            var best = 50.0
            for k in [-0.7, 0.0, 0.7] {
                let start = b.point(a != 0 ? a : k, c != 0 ? c : k) + dir * 0.005
                best = min(best, inside(start, plan) ? cast(start, dir, segs) : 0)
            }
            return best
        }
        let right = clear(1, 0), left = clear(-1, 0)
        var front = clear(0, 1), back = clear(0, -1)
        if front < back { swap(&front, &back) }
        let against = back < touch
        let maxW, maxD: Double
        if against {
            maxW = b.w + right + left
            maxD = b.d + max(0, front - passage)
        } else {
            maxW = b.w + max(0, right - passage) + max(0, left - passage)
            maxD = b.d + max(0, front - passage) + max(0, back - passage)
        }
        let cap = caps[b.kind] ?? (maxW, maxD)
        let w = cm(b.w), d = cm(b.d)
        let topW = max(down(min(maxW, cap.0)), w), topD = max(down(min(maxD, cap.1)), d)
        let noun = b.variant.flatMap { variantNouns[$0] } ?? nouns[b.kind] ?? "мебель"
        let query: String
        if b.kind == "television" {
            let inches = tvInches.min { abs(Double($0) * 2.54 * 0.8716 - Double(w)) < abs(Double($1) * 2.54 * 0.8716 - Double(w)) } ?? 55
            query = "телевизор \(inches) дюймов"
        } else {
            query = "\(noun) \(five(w, topW))×\(five(d, topD)) см"
        }
        let note: String
        if !against {
            note = "Стоит посреди комнаты: вокруг оставлен проход 70 см"
        } else if front >= passage {
            note = "У стены: по ширине свободно \(meters(maxW)) м, спереди проход 70 см"
        } else {
            note = "У стены: по ширине свободно \(meters(maxW)) м, проход спереди всего \(cm(front)) см — глубже не брать"
        }
        let h = cm(b.h)
        return FurnitureOffer(
            id: id, title: noun.prefix(1).uppercased() + noun.dropFirst(),
            now: h > 0 ? "\(w) × \(d) × \(h) см" : "\(w) × \(d) см",
            limit: "\(topW) × \(topD) см", note: note, shops: links(query, kind: b.kind))
    }

    // MARK: геометрия

    static func cast(_ p: SIMD2<Double>, _ d: SIMD2<Double>, _ segs: [(SIMD2<Double>, SIMD2<Double>)]) -> Double {
        var best = 50.0
        for (a, b) in segs {
            let e = b - a
            let den = d.x * e.y - d.y * e.x
            if abs(den) < 1e-9 { continue }
            let w = a - p
            let t = (w.x * e.y - w.y * e.x) / den
            let s = (w.x * d.y - w.y * d.x) / den
            if t > 1e-6, t < best, s >= -1e-9, s <= 1 + 1e-9 { best = t }
        }
        return best
    }

    static func inside(_ p: SIMD2<Double>, _ poly: [SIMD2<Double>]) -> Bool {
        guard poly.count >= 3 else { return true }
        var c = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }

    static func overlaps(_ a: Box, _ b: Box, shrink: Double = 0.02) -> Bool {
        let ca = a.corners, cb = b.corners
        for axis in [a.u, a.v, b.u, b.v] {
            let pa = ca.map { simd_dot($0, axis) }, pb = cb.map { simd_dot($0, axis) }
            if pa.max()! - shrink <= pb.min()! || pb.max()! - shrink <= pa.min()! { return false }
        }
        return true
    }

    static func cm(_ v: Double) -> Int { Int((v * 100).rounded()) }
    static func down(_ v: Double) -> Int { Int((v * 100 + 1e-6).rounded(.down)) }
    /// Размер для поиска: до 5 см, но не больше того, что встанет
    static func five(_ v: Int, _ top: Int) -> Int { max(5, min(Int(Double(v) / 5 + 0.5) * 5, top / 5 * 5)) }
    static func meters(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.replacingOccurrences(of: ".", with: ",")
    }
}

/// «Мебель по размерам»: что встанет в комнату и где это купить
struct FurnitureSizesView: View {
    let result: RoomResult
    let look: Look?
    @State private var offers: [FurnitureOffer] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Сколько места у каждой вещи по скану. Кнопки открывают поиск в магазине сразу с нужными размерами.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !loaded {
                    ProgressView("Считаю, что встанет…")
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                } else if offers.isEmpty {
                    Text("В скане нет мебели. Добавьте её в «Ремонт в 3D» — и здесь появятся размеры и магазины.")
                }
                ForEach(offers) { card($0) }
            }
            .padding()
        }
        .navigationTitle("Мебель по размерам")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            offers = FurnitureFit.offers(result, look: look)
            loaded = true
        }
    }

    private func card(_ o: FurnitureOffer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(o.title).font(.headline)
            if let now = o.now { Text("Сейчас: \(now)").font(.subheadline) }
            if let limit = o.limit { Text("Встанет до: \(limit)").font(.subheadline.bold()) }
            if !o.note.isEmpty { Text(o.note).font(.footnote).foregroundStyle(.secondary) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(o.shops) { shop in
                        Link(destination: shop.url) {
                            Text(shop.id).font(.subheadline.bold())
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Palette.signal, in: Capsule())
                                .foregroundStyle(Palette.ink)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
