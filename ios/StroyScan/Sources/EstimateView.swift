import SwiftUI

/// Смета по скану прямо в телефоне: материалы считаются так же, как в боте (calc.scan_materials),
/// работы — по площадям, электрика и сантехника — по расставленным точкам и трубам.
/// Цены свои у каждого мастера: правятся в строке и запоминаются в телефоне.
enum Estimate {
    enum Section: String, CaseIterable {
        case materials = "Материалы"
        case works = "Работы"
        case electric = "Электрика"
        case plumbing = "Сантехника"
    }

    struct Row: Identifiable {
        let id: String
        let section: Section
        let title: String
        let qty: Double
        let unit: String
        let price: Double
        var on = true
    }

    static let wetRooms = ["ванн", "санузел", "туалет", "душ"]

    static func rows(for r: RoomResult) -> [Row] {
        let floor = r.floorArea, walls = r.wallArea, perimeter = r.perimeter
        let height = r.height > 0 ? r.height : 2.7
        let wet = wetRooms.contains { r.room.lowercased().contains($0) }
        let up = { (v: Double) in v.rounded(.up) }
        var out: [Row] = []
        let m = { (id: String, title: String, qty: Double, unit: String, price: Double, on: Bool) in
            out.append(Row(id: "m." + id, section: .materials, title: title, qty: qty, unit: unit, price: price, on: on))
        }
        let w = { (id: String, title: String, qty: Double, unit: String, price: Double) in
            out.append(Row(id: "w." + id, section: .works, title: title, qty: qty, unit: unit, price: price))
        }

        if wet {
            m("tile_wall", "Плитка на стены (+10%)", walls * 1.1, "м²", 1500, true)
            m("tile_floor", "Плитка на пол (+10%)", floor * 1.1, "м²", 1500, true)
            m("tile_glue", "Клей для плитки, 25 кг", up((walls + floor) * 5 / 25), "меш.", 600, true)
            m("grout", "Затирка", (walls + floor) * 1.1 * 0.5, "кг", 350, true)
            m("hydro", "Гидроизоляция (пол и стены на 20 см)", (floor + perimeter * 0.2) * 1.5, "кг", 400, true)
            w("tile_wall", "Укладка плитки на стены", walls, "м²", 1800)
            w("tile_floor", "Укладка плитки на пол", floor, "м²", 1600)
            w("hydro", "Гидроизоляция", floor + perimeter * 0.2, "м²", 500)
        } else {
            let strips = max(0, r.walls.reduce(0) { $0 + up($1.length / 1.06) }
                - r.openings.filter { $0.kind != "window" }.reduce(0) { $0 + ($1.width / 1.06).rounded(.down) })
            let perRoll = max(1, (10.05 / (height + 0.1)).rounded(.down))
            m("plaster", "Штукатурка (слой 10 мм), 30 кг", up(walls * 9 / 30), "меш.", 550, true)
            m("putty", "Шпаклёвка финишная, 20 кг", up(walls * 1.2 / 20), "меш.", 750, true)
            m("paint", "Краска для стен, 2 слоя, банка 9 л", up(walls * 0.24 / 9), "банк.", 4500, true)
            m("wallpaper", "Или обои 1,06×10,05 м", up(strips / perRoll), "рул.", 2500, false)
            m("laminate", "Ламинат, упаковка 2,13 м²", up(floor * 1.07 / 2.13), "уп.", 1800, true)
            m("underlay", "Подложка", up(floor * 1.05), "м²", 120, true)
            m("skirting", "Плинтус 2,5 м", up(r.skirting * 1.05 / 2.5), "шт", 450, true)
            w("plaster", "Штукатурка стен", walls, "м²", 650)
            w("putty", "Шпаклёвка стен", walls, "м²", 400)
            w("paint", "Покраска стен", walls, "м²", 350)
            w("laminate", "Укладка ламината с подложкой", floor, "м²", 450)
            w("skirting", "Монтаж плинтуса", r.skirting, "м", 300)
        }
        m("ceiling_paint", "Краска для потолка", floor * 0.24, "л", 500, true)
        w("ceiling", "Покраска потолка", floor, "м²", 400)
        if r.slopes > 0 { w("slopes", "Откосы окон", r.slopes, "м", 1200) }

        // электрика
        let e = r.engineering
        let wallPoints = e.points.filter { EngKind.find($0.kind).map { $0.group == .electric && $0.place == .wall && $0.id != "panel" } ?? false }.count
        let lights = e.points.filter { $0.kind == "ceiling_light" }.count
        let panels = e.points.filter { $0.kind == "panel" }.count
        if e.count(.electric) > 0 || !e.wires.isEmpty {
            let cable = e.cableMeters(ceiling: height, wallLines: r.wallLines)
            let el = { (id: String, title: String, qty: Double, unit: String, price: Double) in
                out.append(Row(id: "e." + id, section: .electric, title: title, qty: qty, unit: unit, price: price))
            }
            if wallPoints > 0 {
                el("point", "Монтаж точки: подрозетник, механизм", Double(wallPoints), "шт", 600)
                el("mech", "Розетки и выключатели (сами)", Double(wallPoints), "шт", 400)
            }
            if lights > 0 { el("light", "Вывод под свет на потолке", Double(lights), "шт", 800) }
            if panels > 0 { el("panel", "Сборка щитка", Double(panels), "шт", 6000) }
            el("chase", "Штроба и прокладка кабеля", cable, "м", 350)
            if e.wires.isEmpty {
                el("cable", "Кабель ВВГнг 3×2,5", up(cable), "м", 120)
            } else {
                let prices = ["sockets": 120.0, "light": 80, "power": 320, "lan": 40]
                for (k, m) in e.wireMeters {
                    el("cable_\(k.id)", "Кабель \(k.cable) (\(k.title.lowercased()))", up(m), "м", prices[k.id] ?? 120)
                }
            }
        }

        // сантехника
        let outlets = e.count(.plumbing)
        if outlets > 0 || !e.pipes.isEmpty {
            let pl = { (id: String, title: String, qty: Double, unit: String, price: Double) in
                out.append(Row(id: "p." + id, section: .plumbing, title: title, qty: qty, unit: unit, price: price))
            }
            if outlets > 0 { pl("outlet", "Вывод воды или канализации", Double(outlets), "шт", 2500) }
            for (k, meters) in e.pipeMeters {
                let price: Double = k.id == "sewer" ? 300 : 150
                pl("pipe_\(k.id)", "Труба: \(k.title.lowercased())", meters, "м", price)
                pl("lay_\(k.id)", "Прокладка: \(k.title.lowercased())", meters, "м", 500)
            }
        }
        return out
    }

    // MARK: Свои цены

    static func price(_ row: Row) -> Double {
        let v = UserDefaults.standard.double(forKey: "price." + row.id)
        return v > 0 ? v : row.price
    }

    static func setPrice(_ row: Row, _ v: Double) {
        UserDefaults.standard.set(v, forKey: "price." + row.id)
    }

    static func isOn(_ row: Row) -> Bool {
        UserDefaults.standard.object(forKey: "on." + row.id) as? Bool ?? row.on
    }

    static func setOn(_ row: Row, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "on." + row.id)
    }

    static func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        f.maximumFractionDigits = 0
        return (f.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v))") + " ₽"
    }

    /// Количество, как его покупают: штуки — целыми, метры — до десятых, вверх
    static func amount(_ v: Double, _ unit: String) -> Double {
        ["шт", "меш.", "банк.", "рул.", "уп."].contains(unit) ? v.rounded(.up) : (v * 10).rounded(.up) / 10
    }

    static func qty(_ v: Double, _ unit: String) -> String {
        let a = amount(v, unit)
        return a == a.rounded() ? "\(Int(a))" : fmt(a)
    }

    static func cost(_ row: Row, _ price: Double) -> Double { amount(row.qty, row.unit) * price }
}

struct EstimateView: View {
    let result: RoomResult
    @State private var rows: [Estimate.Row] = []
    @State private var prices: [String: Double] = [:]
    @State private var on: [String: Bool] = [:]
    @State private var editing: Estimate.Row?
    @State private var priceText = ""
    @State private var shownTotal = 0.0

    private func total(_ s: Estimate.Section? = nil) -> Double {
        rows.filter { (s == nil || $0.section == s) && (on[$0.id] ?? true) }
            .reduce(0) { $0 + Estimate.cost($1, prices[$1.id] ?? $1.price) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Итого по смете").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    CountUp(value: shownTotal, money: true)
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .foregroundStyle(Palette.signal)
                    HStack(spacing: 14) {
                        ForEach(Estimate.Section.allCases, id: \.self) { s in
                            let t = total(s)
                            if t > 0 {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.rawValue).font(.caption2).foregroundStyle(.white.opacity(0.6))
                                    Text(Estimate.money(t)).font(.caption.bold()).foregroundStyle(.white)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Palette.ink, in: RoundedRectangle(cornerRadius: 20))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text("Цены примерные — нажмите на строку и поставьте свои, телефон их запомнит. Выключатель слева убирает строку из сметы.")
            }

            ForEach(Estimate.Section.allCases, id: \.self) { s in
                let list = rows.filter { $0.section == s }
                if !list.isEmpty {
                    Section(s.rawValue) {
                        ForEach(list) { row in rowView(row) }
                    }
                }
            }

            Section {
                ShareLink(item: text) { Label("Отправить смету клиенту", systemImage: "square.and.arrow.up") }
            } footer: {
                Text("Объёмы — по скану: стены уже без окон и дверей. Электрика и сантехника — по точкам, расставленным в 3D.")
            }
        }
        .navigationTitle("Смета · \(result.room)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: prices) { _ in animateTotal() }
        .onChange(of: on) { _ in animateTotal() }
        .alert("Цена за \(editing?.unit ?? "")", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Цена, ₽", text: $priceText).keyboardType(.decimalPad)
            Button("Сохранить") {
                if let row = editing, let v = Double(priceText.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")), v >= 0 {
                    Estimate.setPrice(row, v)
                    prices[row.id] = v
                }
            }
            Button("Как было") {
                if let row = editing {
                    UserDefaults.standard.removeObject(forKey: "price." + row.id)
                    prices[row.id] = row.price
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(editing?.title ?? "")
        }
    }

    private func rowView(_ row: Estimate.Row) -> some View {
        let isOn = on[row.id] ?? true
        let price = prices[row.id] ?? row.price
        let q = Estimate.qty(row.qty, row.unit)
        return HStack(spacing: 10) {
            Button {
                on[row.id] = !isOn
                Estimate.setOn(row, !isOn)
            } label: {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(isOn ? Palette.draft : Color.secondary)
            }
            .buttonStyle(.plain)
            Button {
                editing = row
                priceText = price.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(price))" : "\(price)"
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.subheadline)
                        Text("\(q) \(row.unit) × \(Estimate.money(price))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Estimate.money(Estimate.cost(row, price)))
                        .font(.subheadline.bold()).monospacedDigit()
                }
            }
            .buttonStyle(.plain)
        }
        .opacity(isOn ? 1 : 0.45)
    }

    private func load() {
        guard rows.isEmpty else { return }
        rows = Estimate.rows(for: result)
        for r in rows {
            prices[r.id] = Estimate.price(r)
            on[r.id] = Estimate.isOn(r)
        }
        animateTotal()
    }

    private func animateTotal() {
        withAnimation(.easeOut(duration: 0.8)) { shownTotal = total() }
    }

    /// Смета текстом — в мессенджер клиенту
    private var text: String {
        let brand = Brand.current
        var lines = ["Смета: \(result.room)", "Пол \(fmt(result.floorArea)) м², стены без проёмов \(fmt(result.wallArea)) м², высота \(fmt(result.height)) м", ""]
        for s in Estimate.Section.allCases {
            let list = rows.filter { $0.section == s && (on[$0.id] ?? true) }
            guard !list.isEmpty else { continue }
            lines.append("— \(s.rawValue) —")
            for r in list {
                let q = Estimate.qty(r.qty, r.unit)
                let p = prices[r.id] ?? r.price
                lines.append("\(r.title): \(q) \(r.unit) × \(Estimate.money(p)) = \(Estimate.money(Estimate.cost(r, p)))")
            }
            lines.append("Итого \(s.rawValue.lowercased()): \(Estimate.money(total(s)))")
            lines.append("")
        }
        lines.append("ИТОГО: \(Estimate.money(total()))")
        let contacts = [brand.name, brand.phone, brand.note].filter { !$0.isEmpty }
        if !contacts.isEmpty { lines += [""] + contacts }
        lines.append("Размеры сняты лидаром iPhone (СтройСкан).")
        return lines.joined(separator: "\n")
    }
}
