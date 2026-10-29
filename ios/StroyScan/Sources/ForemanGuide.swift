import SwiftUI

/// Офлайн-помощник по типовым ремонтным работам.
/// Расходы предварительные: конкретные нормы и узлы сверяются с техническими картами производителей.
enum ForemanGuide {
    enum Job: String, CaseIterable, Identifiable {
        case ceiling = "Потолок из ГКЛ"
        case tile = "Укладка плитки"
        case paint = "Покраска стен"
        case putty = "Шпаклёвка"
        case vinyl = "Кварц-винил"
        case plumbing = "Сантехника и водоснабжение"
        case sewer = "Канализация"
        case electric = "Электромонтаж"
        case heating = "Отопление и радиаторы"
        case partition = "Перегородка из ГКЛ"
        case floor = "Стяжка пола"
        case waterproof = "Гидроизоляция"
        case demolition = "Демонтаж"
        case ventilation = "Вентиляция"
        case bathroom = "Ремонт санузла комплексно"
        var id: String { rawValue }
        var unit: String { "м²" }
        var icon: String {
            switch self {
            case .ceiling: return "square.dashed"
            case .tile: return "square.grid.3x3"
            case .paint: return "paintbrush"
            case .putty: return "rectangle.on.rectangle"
            case .vinyl: return "square.grid.4x3.fill"
            case .plumbing, .sewer: return "drop"
            case .electric: return "bolt.fill"
            case .heating: return "thermometer"
            case .partition: return "rectangle.split.2x1"
            case .floor: return "square.stack"
            case .waterproof: return "drop.triangle"
            case .demolition: return "hammer"
            case .ventilation: return "wind"
            case .bathroom: return "bathtub"
            }
        }
        static func detect(_ text: String) -> Job? {
            let value = text.lowercased()
            if ["перегород", "фальшстен", "короб из гкл"].contains(where: value.contains) { return .partition }
            if ["потол", "гкл", "гипсокартон"].contains(where: value.contains) { return .ceiling }
            if ["санузел под ключ", "ванную под ключ", "ремонт ванной", "ремонт санузла"].contains(where: value.contains) { return .bathroom }
            if ["канализ", "слив", "фанов", "трап"].contains(where: value.contains) { return .sewer }
            if ["водопровод", "сантех", "труб", "смесител", "унитаз", "раковин"].contains(where: value.contains) { return .plumbing }
            if ["электр", "розет", "выключател", "провод", "кабел", "щиток"].contains(where: value.contains) { return .electric }
            if ["отоплен", "радиатор", "батаре"].contains(where: value.contains) { return .heating }
            if ["вентиляц", "вытяжк", "воздуховод"].contains(where: value.contains) { return .ventilation }
            if ["гидроизоляц", "гидроизол"].contains(where: value.contains) { return .waterproof }
            if ["демонтаж", "разобрат", "снести"].contains(where: value.contains) { return .demolition }
            if ["стяжк", "наливной пол", "выравнивание пола"].contains(where: value.contains) { return .floor }
            if ["плитк", "керамогранит", "кафель"].contains(where: value.contains) { return .tile }
            if ["кварц", "винил", "ламинат"].contains(where: value.contains) { return .vinyl }
            if ["шпак", "шпатл", "выравниван"].contains(where: value.contains) { return .putty }
            if ["крас", "покрас", "окрас"].contains(where: value.contains) { return .paint }
            return nil
        }
    }

    struct Supply: Identifiable {
        let name: String
        let quantity: String
        let details: String
        var id: String { name }
    }
    struct Plan {
        let title: String
        let questions: [String]
        let supplies: [Supply]
        let tools: [String]
        let steps: [String]
        let checks: [String]
        let caveat: String
    }
    static func rounded(_ number: Double, _ digits: Int = 1) -> String {
        String(format: "%.*f", digits, number).replacingOccurrences(of: ".", with: ",")
    }
    static func up(_ value: Double) -> Int { Int(ceil(value)) }

    static func make(_ job: Job, area: Double, description: String) -> Plan {
        let a = max(0.1, min(area, 10000))
        switch job {
        case .plumbing, .sewer, .electric, .heating, .partition, .floor, .waterproof, .demolition, .ventilation, .bathroom:
            return AdvancedForeman.make(job, area: a, description: description)
        case .ceiling:
            return Plan(
                title: "Подвесной потолок из гипсокартона",
                questions: ["Уточнить размеры и конфигурацию помещения, высоту опуска и наличие коробов.",
                            "Уточнить тип листов, количество слоёв, шаг каркаса, светильники и нагрузки.",
                            "Проверить основание перекрытия, коммуникации, влажность и требования к огнестойкости."],
                supplies: [
                    Supply(name: "ГКЛ, ориентир 1 слой", quantity: "\(rounded(a * 1.1)) м²", details: "10% на подрезку; второй слой увеличит объём листов"),
                    Supply(name: "Листы 1200×2500 мм", quantity: "≈ \(up(a * 1.1 / 3)) шт.", details: "Уточнить фактический размер и раскрой"),
                    Supply(name: "Профили и подвесы", quantity: "По схеме каркаса", details: "Нельзя надёжно посчитать только по площади; нужны габариты, тип узлов и нагрузки"),
                    Supply(name: "Крепёж, лента, шпаклёвка швов, грунт", quantity: "По спецификации", details: "Подобрать под выбранную систему ГКЛ")
                ],
                tools: ["Лазерный уровень", "Шуруповёрт", "Нож для ГКЛ", "Ножницы по металлу", "Шпатели", "Защита глаз и органов дыхания"],
                steps: ["Проверить проект, электрику и скрытые коммуникации, разметить уровень.",
                        "Разметить подвесы и каркас по технической карте выбранной системы.",
                        "Закрепить направляющие и подвесы в подходящем основании; собрать и выровнять каркас.",
                        "Провести и проверить коммуникации, подготовить закладные для тяжёлых приборов.",
                        "Закрепить листы с предусмотренным смещением швов и правильным шагом крепежа.",
                        "Армировать стыки, зашпаклевать швы и места крепления, высушить, отшлифовать.",
                        "Загрунтовать и выполнить выбранную финишную отделку."],
                checks: ["Ровность по уровню, отсутствие провисаний", "Соответствие шагов и креплений проектной системе", "Нет трещин и видимых стыков", "Светильники и ревизии доступны"],
                caveat: "Если под «Сапфир» имеется в виду специальный лист ГКЛ, уточните марку и число слоёв. Не путайте его с отдельным отделочным слоем. Конструктив и крепёж выбираются по технической документации производителя."
            )
        case .tile:
            return Plan(
                title: "Укладка плитки",
                questions: ["Это пол или стены? Какая плитка и её формат?", "Есть ли тёплый пол, душ, мокрая зона и гидроизоляция?", "Нужна ли подготовка основания и какой рисунок раскладки?"],
                supplies: [
                    Supply(name: "Плитка с запасом 10%", quantity: "\(rounded(a * 1.1)) м²", details: "Для диагонали, сложной раскладки и крупного формата запас может быть больше"),
                    Supply(name: "Плиточный клей", quantity: "≈ \(rounded(a * 4))–\(rounded(a * 6)) кг", details: "Пример для обычных условий; зависит от формата, основания, гребёнки и клея"),
                    Supply(name: "Затирка", quantity: "По размеру плитки и шва", details: "Нужны длина, ширина, толщина плитки и ширина швов"),
                    Supply(name: "Грунтовка, гидроизоляция, СВП", quantity: "По проекту", details: "Гидроизоляция обязательна в предусмотренных мокрых зонах")
                ],
                tools: ["Плиткорез", "Уровень и правило", "Зубчатый шпатель", "Миксер", "Крестики/СВП", "Губки", "СИЗ"],
                steps: ["Проверить прочность, влажность и ровность основания.", "Выполнить необходимую подготовку, грунтование и гидроизоляцию с просушкой каждого слоя.",
                        "Сделать раскладку с учётом подрезок, углов и деформационных швов.",
                        "Замешать клей по инструкции и нанести на рабочую площадь.",
                        "Уложить плитку с контролем плоскости, контакта клея и ширины швов.",
                        "Выдержать сроки набора прочности, затем затереть швы и выполнить эластичные примыкания."],
                checks: ["Отсутствие пустот и отслоений", "Швы ровные, соблюдены деформационные зазоры", "Уклоны и герметизация мокрых зон выполнены"],
                caveat: "Расход клея указан только как диапазон для первоначальной закупки, не норматив. Сроки и совместимость материалов — строго по упаковке и техническим картам."
            )
        case .paint:
            return Plan(
                title: "Покраска стен",
                questions: ["Какой цвет сейчас и какой нужен?", "Основание прочное? Есть пятна, глянец, трещины?", "Тип и укрывистость выбранной краски?"],
                supplies: [
                    Supply(name: "Краска, 2 слоя", quantity: "≈ \(rounded(a * 0.20))–\(rounded(a * 0.30)) л", details: "Ориентир 0,10–0,15 л/м² на слой; сверить с этикеткой"),
                    Supply(name: "Грунтовка", quantity: "≈ \(rounded(a * 0.1)) л", details: "Только если требуется по состоянию основания"),
                    Supply(name: "Малярная лента, укрывная плёнка", quantity: "По периметру", details: "Учитывать окна, двери и мебель")
                ],
                tools: ["Валик и кисть", "Малярная ванночка", "Шпатель", "Шлифовальный брусок", "Средства защиты"],
                steps: ["Укрыть пол, мебель и примыкания; проверить прочность старой краски.",
                        "Вымыть и обезжирить загрязнения, убрать отслоения; заматировать глянцевые участки.",
                        "Заделать дефекты, высушить и отшлифовать; загрунтовать при необходимости.",
                        "Сделать пробный выкрас и убедиться в совместимости покрытий.",
                        "Нанести первый слой, выдержать время межслойной сушки по инструкции.",
                        "Нанести второй слой и проверить равномерность освещения и цвета."],
                checks: ["Нет полос, пропусков и пятен", "Покрытие держится без отслоений", "Переходы и примыкания аккуратны"],
                caveat: "При перекраске чёрной стены в светло-серую двух слоёв может быть недостаточно. Реальный расход и укрывистость зависят от конкретной краски и основания."
            )
        case .putty:
            return Plan(
                title: "Шпаклёвка стен",
                questions: ["Под обои или под покраску?", "Есть ли перепады, трещины и непрочные участки?", "Какой допустимый слой у выбранной смеси?"],
                supplies: [
                    Supply(name: "Финишная шпаклёвка, 1 мм", quantity: "≈ \(rounded(a * 1.0))–\(rounded(a * 1.5)) кг", details: "Примерный диапазон; расход и толщину проверять по продукту"),
                    Supply(name: "Грунтовка", quantity: "≈ \(rounded(a * 0.1)) л", details: "По впитываемости и типу основания"),
                    Supply(name: "Абразив и армирующая лента", quantity: "По дефектам", details: "Крупные перепады устраняют подходящей штукатурной системой")
                ],
                tools: ["Шпатели", "Правило", "Шлифовальная тёрка", "Прожектор бокового света", "Респиратор"],
                steps: ["Осмотреть основание, удалить слабые слои и пыль.", "Заделать трещины по системе ремонта; при необходимости выровнять штукатуркой.",
                        "Нанести совместимую грунтовку и высушить.", "Нанести шпаклёвку в пределах допустимой толщины.",
                        "После высыхания проверить боковым светом, локально доработать и отшлифовать.",
                        "Удалить пыль, загрунтовать под выбранную финишную отделку."],
                checks: ["Нет наплывов и рисок", "Основание прочное и сухое", "Качество поверхности соответствует виду финишного покрытия"],
                caveat: "Финишная шпаклёвка не заменяет штукатурку при больших перепадах. Толщина слоя и условия высыхания зависят от состава."
            )
        case .vinyl:
            return Plan(
                title: "Укладка кварц-винила",
                questions: ["Материал клеевой или замковый?", "Какое основание, влажность и ровность?", "Есть ли тёплый пол, радиусные зоны и пороги?"],
                supplies: [
                    Supply(name: "Кварц-винил с запасом", quantity: "\(rounded(a * 1.1)) м²", details: "10% запас; при радиусах и сложном рисунке закладывать больше"),
                    Supply(name: "Клей или подложка", quantity: "По инструкции покрытия", details: "Некоторые замковые системы запрещают дополнительную подложку"),
                    Supply(name: "Грунтовка / ровнитель", quantity: "После проверки основания", details: "Считается по фактическим перепадам")
                ],
                tools: ["Нож и угольник", "Рулетка", "Правило", "Прижимной валик для клеевого покрытия", "СИЗ"],
                steps: ["Определить тип покрытия, требования производителя и допустимую влажность основания.",
                        "Проверить ровность, прочность и чистоту основания; устранить дефекты.",
                        "Выдержать материал в условиях помещения согласно инструкции.",
                        "Разметить направление укладки, рисунок и радиусные участки.",
                        "Уложить с нужными зазорами или клеем по выбранной системе.",
                        "Оформить примыкания, пороги и плинтусы; соблюдать время допуска нагрузки."],
                checks: ["Нет вздутий и щелей", "Соблюдены зазоры и рисунок", "Радиусные подрезки аккуратны", "Нет скрипов и подвижности"],
                caveat: "Клеевой и замковый кварц-винил требуют разной подготовки и технологии. Не использовать универсальную схему без инструкции производителя."
            )
        }
    }
}

/// Простая рабочая версия: офлайн-шаблоны, расчёт, отметки шагов и передача плана клиенту.
struct ForemanGuideView: View {
    var initialFloorArea: Double? = nil
    var initialWallArea: Double? = nil
    @State private var task = ""
    @State private var selected: ForemanGuide.Job = .ceiling
    @State private var areaText = "20"
    @State private var generated = false
    @State private var finished: Set<Int> = []
    @State private var message: String?

    private var area: Double? {
        guard let value = Double(areaText.replacingOccurrences(of: ",", with: ".")),
              value > 0, value <= 10000 else { return nil }
        return value
    }
    private var plan: ForemanGuide.Plan {
        ForemanGuide.make(selected, area: area ?? 20, description: task)
    }
    private var report: String {
        var lines = ["ПОМОЩНИК ПРОРАБА — СТРОЙСКАН",
                     "Задача: \(task.isEmpty ? selected.rawValue : task)",
                     "Работа: \(plan.title)", "Площадь: \(ForemanGuide.rounded(area ?? 20)) м²",
                     "", "ЧТО УТОЧНИТЬ:"]
        lines += plan.questions.map { "• " + $0 }
        lines += ["", "МАТЕРИАЛЫ (ПРЕДВАРИТЕЛЬНО):"]
        lines += plan.supplies.map { "• \($0.name): \($0.quantity). \($0.details)" }
        lines += ["", "ИНСТРУМЕНТЫ:", plan.tools.joined(separator: ", "), "", "ПО ПОРЯДКУ:"]
        lines += plan.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
        lines += ["", "ПРОВЕРКА КАЧЕСТВА:"]
        lines += plan.checks.map { "• " + $0 }
        lines += ["", "ВАЖНО: " + plan.caveat]
        return lines.joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Помощник прораба", systemImage: "hammer.fill")
                        .font(.title2.bold())
                    Text("Опиши задачу как новичок. Покажу типовой порядок работ, материалы, инструменты и контроль качества. Работает без интернета.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Что нужно сделать?").font(.headline)
                    TextEditor(text: $task)
                        .frame(height: 95)
                        .onChange(of: task) { value in
                            generated = false
                            if let detected = ForemanGuide.Job.detect(value) { selected = detected }
                        }
                        .padding(6)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Описание строительной работы")
                    Text("Примеры задач").font(.caption.bold()).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            example("ГКЛ", text: "Потолок из ГКЛ, два слоя под покраску", job: .ceiling)
                            example("Электрика", text: "Провести электрику, розетки и освещение", job: .electric)
                            example("Санузел", text: "Ремонт санузла под ключ с сантехникой, плиткой и электрикой", job: .bathroom)
                            example("Шпаклёвка", text: "Шпаклёвка стен под покраску", job: .putty)
                            example("Плитка", text: "Укладка плитки в ванной", job: .tile)
                        }
                    }
                    Picker("Вид работы", selection: $selected) {
                        ForEach(ForemanGuide.Job.allCases) { job in
                            Text(job.rawValue).tag(job)
                        }
                    }.pickerStyle(.menu)
                    .onChange(of: selected) { _ in generated = false }
                    if let floor = initialFloorArea, let walls = initialWallArea {
                        HStack {
                            Button("Пол / потолок · \(ForemanGuide.rounded(floor)) м²") {
                                areaText = ForemanGuide.rounded(floor)
                                generated = false
                            }
                            Button("Стены · \(ForemanGuide.rounded(walls)) м²") {
                                areaText = ForemanGuide.rounded(walls)
                                generated = false
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                    Text("Площадь работ, м²").font(.subheadline)
                    TextField("Например, 50", text: $areaText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        guard area != nil else { message = "Укажи площадь больше нуля и до 10 000 м²."; return }
                        finished = []
                        generated = true
                    } label: {
                        Label("Составить план работ", systemImage: "list.bullet.clipboard")
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.signal)
                    Text("15 видов работ офлайн. Если приложение выбрало не тот вид работы, измени его вручную. Сложные задачи можно разобрать в «Нейросети → План работ ИИ».")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))

                if generated {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(plan.title).font(.title3.bold())
                        section("Перед началом уточни", icon: "questionmark.circle", items: plan.questions)
                        Text("Материалы · приблизительно").font(.headline)
                        ForEach(plan.supplies) { supply in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .top) {
                                    Text(supply.name).font(.subheadline.bold())
                                    Spacer(minLength: 10)
                                    Text(supply.quantity).font(.subheadline.bold()).multilineTextAlignment(.trailing)
                                }
                                Text(supply.details).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(11)
                            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                        section("Инструменты", icon: "wrench.and.screwdriver", items: plan.tools)
                        Text("Выполнение · \(finished.count) из \(plan.steps.count)").font(.headline)
                        ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                            Button {
                                if finished.contains(index) { finished.remove(index) }
                                else { finished.insert(index) }
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: finished.contains(index) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(finished.contains(index) ? Color.green : Palette.signal)
                                    Text("\(index + 1). \(step)").multilineTextAlignment(.leading)
                                        .foregroundStyle(.primary)
                                }
                            }.buttonStyle(.plain).padding(.vertical, 5)
                        }
                        section("Приёмка работы", icon: "checkmark.seal", items: plan.checks)
                        Text(plan.caveat).font(.caption).foregroundStyle(.secondary)
                            .padding(12).background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        ShareLink(item: report) {
                            Label("Отправить план и закупку", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(Palette.signal)
                        Button("Скопировать текст плана") {
                            UIPasteboard.general.string = report
                            message = "План скопирован"
                        }
                        .frame(maxWidth: .infinity)
                    }.padding().background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .padding()
        }
.onAppear {
            if let floor = initialFloorArea, !generated {
                areaText = ForemanGuide.rounded(floor)
            }
        }
                .navigationTitle("Помощник прораба")
        .navigationBarTitleDisplayMode(.inline)
        .alert("СтройСкан", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("Понятно", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func example(_ title: String, text: String, job: ForemanGuide.Job) -> some View {
        Button(title) {
            task = text
            selected = job
            generated = false
        }
        .buttonStyle(.bordered)
        .font(.caption)
    }

    private func section(_ heading: String, icon: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(heading, systemImage: icon).font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(Palette.signal)
                    Text(item).font(.subheadline)
                }
            }
        }
    }
}
