import SwiftUI

/// Purchase-oriented takeoff. Quantities are editable assumptions, NOT merchant stock or quotes.
/// Petrovich checkout requires official authenticated website/app; no unsupported cart endpoint.
enum PurchasePlanner {
    enum Trade: String, CaseIterable, Identifiable {
        case drywall = "ГКЛ и каркас"
        case putty = "Шпаклёвка стен"
        case paint = "Покраска"
        case wallTile = "Плитка на стены"
        case floorTile = "Плитка на пол"
        case screed = "Стяжка пола"
        case waterproof = "Гидроизоляция"
        case vinyl = "Кварц-винил"
        case plaster = "Штукатурка"
        var id: String { rawValue }
    }
    struct Material: Identifiable {
        let id: String
        let trade: Trade
        let name: String
        let amount: Double
        let unit: String
        let package: String
        let packages: Int
        let note: String
        var orderText: String {
            "\(name) — \(packages) \(package) (расчёт \(format(amount)) \(unit))"
        }
    }
    static func format(_ number: Double) -> String {
        String(format: "%.1f", number).replacingOccurrences(of: ".", with: ",")
    }
    private static func item(_ trade: Trade, _ key: String, _ name: String,
                             _ amount: Double, _ unit: String, _ packSize: Double,
                             _ packLabel: String, _ note: String) -> Material {
        Material(id: trade.rawValue + "/" + key, trade: trade, name: name,
                 amount: max(0, amount), unit: unit, package: packLabel,
                 packages: Int(ceil(max(0, amount) / packSize)), note: note)
    }

    static func calculate(trades: Set<Trade>, wall: Double, floor: Double,
                          drywallLayers: Int, tileReserve: Double,
                          puttyThickness: Double, screedThickness: Double) -> [Material] {
        let a = max(0, min(10000, wall))
        let f = max(0, min(10000, floor))
        let reserve = max(1, min(1.30, tileReserve))
        var items: [Material] = []
        for trade in Trade.allCases where trades.contains(trade) {
            switch trade {
            case .drywall:
                let layers = Double(max(1, min(3, drywallLayers)))
                items += [
                    item(trade, "sheet", "Гипсокартон 1200×2500 мм", a * layers * 1.12,
                         "м²", 3, "лист.", "Запас 12%; раскрой, влажность помещения, число сторон и система должны быть уточнены"),
                    item(trade, "joint", "Шпаклёвка для швов ГКЛ", a * layers * 0.25 * 1.1,
                         "кг", 20, "меш. 20 кг", "0,25 кг/м² обшивки — пример, уточнить по технической карте"),
                    item(trade, "tape", "Армирующая лента швов", a * layers * 1.3 * 1.1,
                         "м", 50, "рул. 50 м", "Ориентир, зависит от раскладки листов")
                ]
                // Profiles intentionally excluded: wall area alone cannot determine geometry and fixings.
            case .putty:
                items += [
                    item(trade, "mix", "Шпаклёвка финишная", a * max(0.5, min(5, puttyThickness)) * 1.2 * 1.1,
                         "кг", 20, "меш. 20 кг", "Принят расход 1,2 кг/м² на каждый 1 мм +10%; по производителю"),
                    item(trade, "primer", "Грунтовка для стен", a * 0.12 * 1.1,
                         "л", 10, "кан. 10 л", "Пример 0,12 л/м² на один слой, проверить совместимость")
                ]
            case .paint:
                items += [
                    item(trade, "paint", "Краска интерьерная (2 слоя)", a * 0.24 * 1.10,
                         "л", 9, "вед. 9 л", "Расход 0,12 л/м² на слой условный; цвет и укрывистость влияют"),
                    item(trade, "primer", "Грунтовка под покраску", a * 0.12,
                         "л", 10, "кан. 10 л", "Может не требоваться для прочного загрунтованного основания")
                ]
            case .wallTile, .floorTile:
                let area = trade == .wallTile ? a : f
                items += [
                    item(trade, "tile", "Плитка / керамогранит", area * reserve,
                         "м²", 1, "уп. ~1 м²", "Размер упаковки условный! Замените количеством м² из карточки выбранной плитки"),
                    item(trade, "glue", "Клей для плитки", area * 5 * 1.1,
                         "кг", 25, "меш. 25 кг", "5 кг/м² пример: фактический расход зависит от гребёнки, формата и основания"),
                    item(trade, "grout", "Затирка швов", area * 0.5 * 1.1,
                         "кг", 2, "уп. 2 кг", "Очень грубо; нужен размер плитки, толщина и ширина шва")
                ]
            case .screed:
                items.append(item(trade, "mix", "Сухая смесь для стяжки", f * max(10, min(150, screedThickness)) * 1.8 * 1.1,
                                  "кг", 25, "меш. 25 кг", "Допущение 1,8 кг/м² на 1 мм; толщину и нагрузку перекрытия проверить"))
            case .waterproof:
                items += [
                    item(trade, "waterproof", "Обмазочная гидроизоляция", f * 1.5 * 1.1,
                         "кг", 5, "вед. 5 кг", "Только площадь пола. Примыкания и стены рассчитывать отдельно по системе"),
                    item(trade, "tape", "Гидроизоляционная лента", sqrt(f) * 4 * 1.1,
                         "м", 10, "рул. 10 м", "Периметр условно квадратного помещения; при сложной геометрии нужен реальный периметр")
                ]
            case .vinyl:
                items.append(item(trade, "vinyl", "Кварц-винил", f * reserve,
                                  "м²", 2, "уп. ~2 м²", "Количество м² в упаковке условно, замени по фактическому товару; клеевой/замковый отличаются"))
            case .plaster:
                items += [
                    item(trade, "mix", "Штукатурная смесь (10 мм)", a * 10 * 0.9 * 1.1,
                         "кг", 30, "меш. 30 кг", "0,9 кг/м² на 1 мм — условно; проверь допустимую толщину и расход"),
                    item(trade, "primer", "Грунт для основания", a * 0.12,
                         "л", 10, "кан. 10 л", "Тип грунта зависит от основания")
                ]
            }
        }
        return items
    }
}

struct PetrovichPurchaseView: View {
    let room: RoomResult?
    @StateObject private var ai = AIState()
    var onAddToProject: (([PurchasePlanner.Material]) -> Void)? = nil
    @State private var counts: [String: Int] = [:]
    @State private var imported = false
    @State private var wallText: String
    @State private var floorText: String
    @State private var selected: Set<PurchasePlanner.Trade>
    @State private var drywallLayers = 1
    @State private var reservePercent = 10.0
    @State private var puttyThickness = 1.0
    @State private var screedThickness = 50.0
    @State private var excluded: Set<String> = []
    @State private var copied = false

    init(room: RoomResult? = nil, onAddToProject: (([PurchasePlanner.Material]) -> Void)? = nil) {
        self.room = room
        self.onAddToProject = onAddToProject
        _wallText = State(initialValue: room.map { PurchasePlanner.format($0.wallArea) } ?? "40")
        _floorText = State(initialValue: room.map { PurchasePlanner.format($0.floorArea) } ?? "20")
        _selected = State(initialValue: [.putty, .paint])
    }
    private func number(_ s: String) -> Double {
        max(0, Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0)
    }
    private var items: [PurchasePlanner.Material] {
        PurchasePlanner.calculate(trades: selected, wall: number(wallText), floor: number(floorText),
                                  drywallLayers: drywallLayers, tileReserve: 1 + reservePercent / 100,
                                  puttyThickness: puttyThickness, screedThickness: screedThickness)
    }
    private var active: [PurchasePlanner.Material] { items.filter { !excluded.contains($0.id) } }
    private func count(_ item: PurchasePlanner.Material) -> Int { counts[item.id] ?? item.packages }
    private var revised: [PurchasePlanner.Material] {
        active.map { item in
            PurchasePlanner.Material(id: item.id, trade: item.trade, name: item.name,
                                     amount: item.amount, unit: item.unit,
                                     package: item.package, packages: count(item), note: item.note)
        }
    }
    private var report: String {
        (["СТРОЙСКАН · ЗАКУПКА ДЛЯ ПЕТРОВИЧА",
          "Объект: \(room?.room ?? "Ручной расчёт")",
          "Стены \(wallText) м² · пол \(floorText) м²",
          "Виды работ: \(selected.map(\.rawValue).sorted().joined(separator: ", "))",
          "Это ориентировочный список, не корзина магазина.",
          "",
          "МАТЕРИАЛЫ:"] + revised.map { "• \($0.orderText). \($0.note)" } +
         ["", "ПЕРЕД ОПЛАТОЙ: проверь упаковки, реальные артикулы, запас, совместимость, наличие и доставку в Петровиче."])
        .joined(separator: "\n")
    }

    var body: some View {
        Form {
            Section("Замер") {
                Text("Введи площади вручную или открой закупку из LiDAR-комнаты. Площади стен и пола различаются.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Text("Стены, м²")
                    Spacer()
                    TextField("40", text: $wallText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Пол / потолок, м²")
                    Spacer()
                    TextField("20", text: $floorText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
            }
            if let room, selected.contains(.drywall), !room.wallLines.isEmpty {
                Section("Профили ГКЛ по LiDAR") {
                    NavigationLink {
                        GKLFrameView(result: room)
                    } label: {
                        Label("Посчитать профили по выбранным стенам в 3D", systemImage: "square.grid.3x3")
                    }
                    Text("Нужны стены, проёмы и схема каркаса. По одним м² закупать профили нельзя.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Какие работы?") {
                ForEach(PurchasePlanner.Trade.allCases) { trade in
                    Toggle(trade.rawValue, isOn: Binding(
                        get: { selected.contains(trade) },
                        set: { on in
                            if on { selected.insert(trade) } else { selected.remove(trade) }
                        }
                    )).tint(Palette.signal)
                }
            }
            Section("Уточнить расход") {
                if selected.contains(.drywall) {
                    Picker("Слоёв ГКЛ", selection: $drywallLayers) {
                        ForEach(1...3, id: \.self) { count in Text("\(count)").tag(count) }
                    }
                }
                if selected.contains(.putty) {
                    Text("Шпаклёвка: \(PurchasePlanner.format(puttyThickness)) мм")
                    Slider(value: $puttyThickness, in: 0.5...5, step: 0.5)
                }
                if selected.contains(.screed) {
                    Text("Стяжка: \(Int(screedThickness)) мм")
                    Slider(value: $screedThickness, in: 10...150, step: 5)
                }
                Text("Запас покрытия: \(Int(reservePercent))%")
                Slider(value: $reservePercent, in: 5...25, step: 5)
                Text("По площади нельзя определить стоечные профили, крепления, электрокабель, трубы и фитинги. Для них используй 3D-каркас / инженерные схемы и уточни проект.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Список материалов · \(active.count) позиций") {
                if items.isEmpty {
                    Text("Выбери хотя бы один вид работы.")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Button {
                            if excluded.contains(item.id) { excluded.remove(item.id) }
                            else { excluded.insert(item.id) }
                        } label: {
                            Image(systemName: excluded.contains(item.id) ? "circle" : "checkmark.circle.fill")
                                .foregroundStyle(excluded.contains(item.id) ? .secondary : Palette.signal)
                        }
                        .buttonStyle(.borderless)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.subheadline.bold()).foregroundStyle(.primary)
                                Text("\(count(item)) \(item.package) · \(PurchasePlanner.format(item.amount)) \(item.unit)")
                                    .font(.subheadline).foregroundStyle(.primary)
                                Text(item.note).font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 12) {
                                    Button {
                                        counts[item.id] = max(0, count(item) - 1)
                                    } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                                    Text("\(count(item)) уп.").monospacedDigit()
                                    Button {
                                        counts[item.id] = min(100000, count(item) + 1)
                                    } label: { Image(systemName: "plus.circle") }
                                    .buttonStyle(.borderless)
                                    Text("Уточни размер упаковки").font(.caption2)
                                }
                                .foregroundStyle(.secondary)
                            }
                    }
                }
            }
            if let onAddToProject {
                Section("Проект ремонта") {
                    Button {
                        onAddToProject(revised)
                        imported = true
                    } label: {
                        Label("Добавить выбранные материалы в проект", systemImage: "tray.and.arrow.down")
                    }
                }
            }
            Section("ИИ-проверка закупки") {
                NavigationLink {
                    AITextView(kind: .foreman, state: ai,
                               prefill: "Я начинающий строитель. Проверь предварительную закупку, не выдумывай цены и артикулы Петровича. Уточни, какие материалы, инструменты и подготовительные работы пропущены, совместимость, количество и что нельзя рассчитать без данных. Отдельно перечисли вопросы, от которых зависит заказ. Список:\n" + report,
                               placeholder: "Уточни основание, материалы, марку смеси, формат плитки и особые условия")
                } label: {
                    Label("ИИ: проверить, чего не хватает", systemImage: "sparkles")
                }
                Text("ИИ работает только с интернетом и ключом kie.ai; не видит актуальные цены, остатки и корзину Петровича.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Передать список в Петрович") {
                Button {
                    UIPasteboard.general.string = report
                    copied = true
                } label: {
                    Label("Скопировать весь список", systemImage: "doc.on.doc")
                }
                ShareLink(item: report) {
                    Label("Отправить список закупки", systemImage: "square.and.arrow.up")
                }
                Link(destination: URL(string: "https://petrovich.ru/")!) {
                    Label("Открыть Петрович и подобрать артикулы", systemImage: "cart")
                }
                Link(destination: URL(string: "https://moscow.petrovich.ru/kalkulyator-remonta/raschet-stoimosti/")!) {
                    Label("Калькулятор Петровича (пример: Москва)", systemImage: "calculator")
                }
                Text("Пока нет подтверждённого публичного интерфейса для заполнения сторонней корзины Петровича. Приложение не добавляет позиции и не оформляет заказ от твоего имени. Артикулы, наличие, цены и доставка проверяются на сайте.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Закупка · Петрович")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Сохранено в проект", isPresented: $imported) {
            Button("Хорошо", role: .cancel) {}
        }
        .alert("Список скопирован", isPresented: $copied) {
            Button("Хорошо", role: .cancel) {}
        }
    }
}
