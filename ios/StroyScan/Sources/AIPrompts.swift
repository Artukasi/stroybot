import Foundation
import UIKit

// MARK: - Промпты — те же, что у бота (bot/prompts.py, bot/scan_ai.py, bot/look.py)

enum AIPrompts {
    /// Стиль → (по-русски, для картинки по-английски)
    static let styles: [(id: String, name: String, en: String)] = [
        ("scandi", "Скандинавский", "Scandinavian style: light oak wood, white walls, soft textiles, minimal decor, lots of natural light"),
        ("loft", "Лофт", "industrial loft style: exposed brick, concrete textures, black metal accents, Edison bulbs, leather furniture"),
        ("modern", "Современный", "modern contemporary style: clean lines, neutral warm palette, hidden storage, designer lighting"),
        ("classic", "Неоклассика", "neoclassical style: moldings on walls, elegant furniture, marble accents, brass details, warm beige tones"),
        ("japandi", "Джапанди", "japandi style: natural wood, muted earthy tones, low furniture, linen, ceramic decor, calm minimalism"),
        ("budget", "Бюджетный ремонт", "affordable renovation with inexpensive materials available in Russian DIY stores: painted walls, laminate floor, simple furniture, tidy and cozy"),
    ]

    static func styleEn(_ id: String) -> String { styles.first { $0.id == id }?.en ?? styles[0].en }

    static let design = "Redesign this room photo as a finished interior renovation in {style}. Keep the exact same room geometry, camera angle, walls, windows and doors positions. Replace finishes, furniture and lighting only. Photorealistic interior photography, high detail. {extra}"

    static let scanDesign = "Renovate the room in this photo in {style}. The result must look like a real photograph of a finished room, not a render. Keep the camera position, lens and perspective, the room geometry, walls, windows and doors exactly where they are. Real size from a LiDAR scan: {facts}. Keep every piece of furniture in its place and at its real size, restyled. {look} Real materials with natural texture (wood grain, fabric weave, matte paint), soft daylight from the windows, realistic shadows and reflections, correct scale. No CGI look, no people, no text, no watermarks."

    static let scanT2I = "Real photograph of a finished room renovation in {style}, taken at eye level from the doorway with a 24 mm lens. The room was measured with a LiDAR scan, keep these exact proportions and placement: {facts}. {look} Real materials with natural texture, soft daylight from the windows, realistic shadows, tidy and lived-in. Looks like a real estate photo, not a 3D render. No people, no text, no watermarks."

    static let scanRender = "This image is a simple 3D model of a real room built from a LiDAR scan. Turn it into a real photograph of the same room after renovation in {style}. Keep exactly: camera position and angle, perspective, room geometry, wall lengths, ceiling height, positions and sizes of windows, doors and every piece of furniture. Do not add, remove or move walls, windows, doors or furniture; keep each item's type, shape and colour from the model (small decor like cushions, plants and books is fine). Room facts: {facts}. {look} Replace flat 3D surfaces with real materials and textures, natural daylight from the windows, soft shadows, true-to-scale details, subtle real-life imperfections. Photorealistic, like a real estate photo shot on a full-frame camera. No CGI or 3D-render look, no people, no text, no watermarks."

    static let estimate = """
    Ты — опытный сметчик в России. По описанию задачи ремонта составь ориентировочную смету.
    Формат ответа (Telegram HTML, без Markdown, без таблиц):
    <b>Смета: краткое название</b>
    <b>Работы:</b> список «название — объём — цена за ед. — сумма ₽»
    <b>Материалы:</b> список «название — количество — сумма ₽»
    <b>Итого:</b> работы, материалы, всего (диапазон «от–до»)
    Коротко: 2–3 совета, как сэкономить или что учесть.
    Используй средние цены по России на текущий год, если регион не указан; если указан — по региону.
    Если данных не хватает, сделай разумные допущения и перечисли их одной строкой в начале.
    В конце одной строкой: «Смета ориентировочная, точную цену даст замер.»
    """

    static let kp = """
    Ты помогаешь прорабу составить коммерческое предложение заказчику по ремонту.
    По описанию объекта напиши КП (Telegram HTML, без Markdown и таблиц):
    <b>Коммерческое предложение</b>, объект, состав работ по этапам со сроками,
    стоимость по этапам и итог (диапазон, если данных мало), условия оплаты (предложи поэтапную),
    гарантия, почему выбрать нас (3 пункта, без пафоса). Пиши вежливо и конкретно.
    """

    static let check = """
    Ты — строительный технадзор. Тебе присылают фото выполненной работы (плитка, штукатурка,
    стяжка, электрика, сантехника, покраска и т.д.). Оцени качество по видимым признакам.
    Формат (Telegram HTML, без Markdown):
    <b>Что на фото:</b> одной строкой
    <b>Замечания:</b> список конкретных видимых дефектов с объяснением, почему это плохо (или «видимых дефектов нет»)
    <b>Что спросить у мастера:</b> 2–4 вопроса
    <b>Что проверить самому:</b> простые проверки (уровень, правило 2 м, простукивание и т.п.)
    Честно указывай, что по фото нельзя оценить (скрытые работы, основание). Не выдумывай дефекты.
    """

    static let foreman = """
    Ты — внимательный и опытный прораб-наставник. Пользователь может ничего не знать о стройке.
    На русском языке разложи описанную задачу на практический безопасный план.
    Пиши простыми словами, объясняй строительные термины при первом упоминании.
    Формат Telegram HTML (только <b>, списки обычным текстом, без Markdown и таблиц):
    <b>Что собираемся делать</b> — короткая формулировка.
    <b>Что нужно уточнить</b> — до 5 конкретных вопросов, которые влияют на технологию и объёмы.
    Для задачи из нескольких видов работ (например электрика + ГКЛ + шпаклёвка + покраска)
    разбей работу на связанные этапы в правильном технологическом порядке.
    Уточни измеряемые величины: м² пола, стен, потолка, длины трасс и число приборов.
    <b>Когда закупать</b> — раздели черновую и чистовую закупку, учитывай уточняемые позиции.
    <b>Материалы и сколько купить</b> — единицы, ориентировочный расход, коэффициенты запаса, упаковки.
    Если площади, толщины, размеры, тип основания или производитель неизвестны — не выдумывай точные количества;
    покажи формулу и пример с явно подписанными допущениями.
    <b>Инструменты</b> — минимально необходимый набор и средства защиты.
    <b>Этапы работ</b> — нумерованные пункты, каждый содержит «что делать», «как проверить», «перед следующим этапом».
    <b>Зачем выполняем каждый этап</b> — объясняй смысл и проверки понятными словами.
    <b>Ошибки новичка</b> — 3–5 предупреждений.
    <b>Что нельзя выполнять без специалиста</b> — отдельно назови опасные и проектные работы.
    Для ГКЛ, грунтовки, шпаклёвки, гидроизоляции и окраски не придумывай сроки высыхания
    без марки продукта, температуры и условий.
    <b>Приёмка</b> — понятный чек-лист по результату.
    <b>Что зависит от производителя</b> — время высыхания, совместимость, расход, требуемые зазоры.
    Для несущих конструкций, газа, электрики под напряжением, опасных высот и перепланировки
    не давай рискованных пошаговых инструкций; предложи лицензированного специалиста и проект.
    Не обещай соответствие конкретным СП или ГОСТ без проверенной ссылки.
    Не называй ориентировочную оценку гарантированной сметой и не выдумывай цены.
    """

    static let consult = """
    Ты — дружелюбный консультант по ремонту и строительству в России.
    Отвечай кратко и по делу (до 1200 символов), простым языком, Telegram HTML без Markdown.
    Учитывай российские материалы, нормы и реалии. Если вопрос касается несущих конструкций,
    газа, электрики под напряжением или перепланировки — обязательно предупреди о рисках,
    согласованиях и необходимости специалиста. Не выдумывай номера пунктов СП/ГОСТ, если не уверен.
    """

    static let report = """
    Ты помогаешь прорабу подготовить фотоотчёт для заказчика о ходе ремонта.
    Тебе дают название объекта и подписи к фото (часто надиктованные голосом, с ошибками распознавания).
    Напиши короткое резюме для заказчика: 3–6 предложений, что сделано, что дальше, есть ли вопросы к заказчику.
    Пиши вежливо, по-деловому, простым языком. Только обычный текст: без HTML, Markdown, списков и эмодзи.
    Не выдумывай работы, которых нет в подписях.
    """

    static func fill(_ t: String, _ values: [String: String]) -> String {
        values.reduce(t) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }

    // MARK: Цвет словами — модель не понимает #rrggbb

    private static func hsl(_ hex: String) -> (h: Double, s: Double, l: Double) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        let r = Double((v >> 16) & 255) / 255, g = Double((v >> 8) & 255) / 255, b = Double(v & 255) / 255
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        return (h * 60, s, l)
    }

    static func colorEn(_ hex: String) -> String {
        let (h, s, l) = hsl(hex)
        if l > 0.92 { return "white" }
        if s < 0.12 || l < 0.1 { return l > 0.75 ? "light grey" : l > 0.45 ? "grey" : l > 0.2 ? "charcoal" : "black" }
        if h < 15 || h >= 345 { return l > 0.75 ? "pink" : l < 0.3 ? "burgundy" : "red" }
        if h < 45 {
            if l > 0.75 || (s < 0.45 && l > 0.6) { return "beige" }
            if l < 0.42 || s < 0.45 { return "brown" }
            return h < 25 ? "terracotta" : "orange"
        }
        if h < 70 { return l > 0.8 ? "cream" : s < 0.35 ? (l > 0.55 ? "sand" : "olive") : (l < 0.45 ? "mustard" : "yellow") }
        if h < 165 { return l < 0.3 ? "dark green" : s < 0.3 ? (l > 0.45 ? "sage green" : "olive") : (l > 0.75 ? "mint" : "green") }
        if h < 200 { return "teal" }
        if h < 255 { return l < 0.3 ? "navy blue" : l > 0.72 ? "light blue" : s < 0.3 ? "grey-blue" : "blue" }
        if h < 290 { return l > 0.72 ? "lavender" : "purple" }
        return l > 0.72 ? "pink" : l < 0.35 ? "plum" : "magenta"
    }

    static func woodEn(_ hex: String) -> String {
        let (h, s, l) = hsl(hex)
        if s >= 0.12 && !(10..<60).contains(h) { return colorEn(hex) }
        if s < 0.12 { return l > 0.8 ? "whitewashed oak" : l > 0.35 ? "grey-washed oak" : "dark stained wood" }
        return l > 0.72 ? "light bleached oak" : l > 0.5 ? "natural oak" : l > 0.32 ? "walnut" : "dark wenge wood"
    }

    private static let furnitureEn = [
        "sofa": "sofa", "bed": "bed", "chair": "chair", "table": "table", "storage": "cabinet", "refrigerator": "refrigerator",
        "stove": "stove", "oven": "oven", "sink": "sink", "toilet": "toilet", "bathtub": "bathtub", "washerDryer": "washing machine",
        "television": "TV", "dishwasher": "dishwasher", "fireplace": "fireplace", "stairs": "stairs",
    ]
    private static let variantEn = [
        "straight": "straight sofa", "corner": "L-shaped corner sofa", "chesterfield": "chesterfield sofa", "modular": "modular sofa",
        "platform": "low platform bed", "upholstered": "upholstered bed with a soft headboard", "classic": "classic wooden bed",
        "dining": "dining chair", "armchair": "armchair", "stool": "stool", "dining_rect": "rectangular dining table",
        "dining_round": "round dining table", "coffee": "coffee table", "desk": "desk", "wardrobe": "wardrobe",
        "dresser": "chest of drawers", "shelving": "open shelving unit", "tv_stand": "TV stand",
    ]
    private static let wallFinishes = ["paint": "matte paint", "wallpaper": "wallpaper", "plaster": "decorative Venetian plaster",
                                       "panels": "wooden wall panels", "tile": "ceramic tiles", "brick": "exposed brick"]
    private static let patterns = ["stripes": "with vertical stripes", "geometric": "with a geometric pattern",
                                   "floral": "with a floral pattern", "damask": "with a damask pattern", "linen": "with linen texture"]
    private static let floors = ["laminate": "laminate flooring", "parquet": "parquet flooring", "tile": "large-format floor tiles",
                                 "stone": "stone-look porcelain tiles", "carpet": "wall-to-wall carpet", "concrete": "microcement floor"]
    private static let lights = ["none": "no ceiling light", "chandelier_classic": "a classic crystal chandelier",
                                 "chandelier_modern": "a modern designer chandelier", "pendant": "pendant lamps",
                                 "spots": "recessed ceiling spotlights", "track": "black track lights", "ring": "a ring LED chandelier"]
    private static let curtains = ["none": "bare windows", "curtains": "floor-length curtains", "blinds": "window blinds", "roman": "roman blinds"]

    static func itemEn(_ kind: String, _ variant: String?, _ color: String?) -> String {
        let name = variant.flatMap { variantEn[$0] } ?? furnitureEn[kind] ?? "furniture item"
        return [color.map { "\(colorEn($0)) (\($0))" }, name].compactMap { $0 }.joined(separator: " ")
    }

    private static func m(_ v: Double) -> String {
        let s = String(format: "%.2f", v)
        return s.hasSuffix("00") ? String(s.dropLast(3)) : s.hasSuffix("0") ? String(s.dropLast()) : s
    }

    /// Размеры, проёмы и мебель — с ремонтом из 3D (убранного нет, добавленное есть) или «как есть»
    static func facts(_ r: RoomResult, look: Look?) -> String {
        let windows = r.openings.filter { $0.kind == "window" }, doors = r.openings.filter { $0.kind == "door" }
        var parts = ["\(m(r.length)) m × \(m(r.width)) m floor, ceiling height \(m(r.height)) m",
                     "floor area \(m(r.floorArea)) m2", "\(windows.count) window(s), \(doors.count) door(s)"]
        let ops = r.openings.prefix(8).map { o -> String in
            var t = "\(o.kind) \(m(o.width))×\(m(o.height)) m" + (o.wall.map { " on wall \($0 + 1)" } ?? "")
            if o.kind == "window", let b = o.bottom, b > 0 { t += ", sill at \(m(b)) m" }
            return t
        }
        if !ops.isEmpty { parts.append(ops.joined(separator: "; ")) }
        var items: [String] = []
        for (i, it) in r.items.enumerated() {
            let ch = look?.objects[String(i)]
            if ch?.hidden == true { continue }
            items.append("\(itemEn(it.kind, ch?.variant, ch?.color)) \(Int(it.width * 100))×\(Int(it.depth * 100))×\(Int(it.height * 100)) cm")
        }
        for a in look?.added ?? [] {
            items.append("\(itemEn(a.kind, a.variant == "default" ? nil : a.variant, a.color)) \(Int(a.width * 100))×\(Int(a.depth * 100))×\(Int(a.height * 100)) cm")
        }
        if !items.isEmpty { parts.append("furniture: " + items.prefix(15).joined(separator: ", ")) }
        return parts.joined(separator: "; ")
    }

    /// Отделка из 3D словами. edited — мебель уже описана в facts такой, как в 3D
    static func lookText(_ l: Look?, edited: Bool) -> String {
        guard let l else {
            return edited ? "Pick finishes and lighting that suit the style." : "Pick finishes, furniture and lighting that suit the style."
        }
        var parts: [String] = []
        let wall = [colorEn(l.wall.color) + " (\(l.wall.color))", wallFinishes[l.wall.finish] ?? "",
                    l.wall.finish == "wallpaper" ? patterns[l.wall.pattern] ?? "" : ""].filter { !$0.isEmpty }
        parts.append("walls: " + wall.joined(separator: " "))
        if let a = l.accent {
            parts.append("one accent wall (wall \(a.wall + 1)): " + [colorEn(a.color) + " (\(a.color))", wallFinishes[a.finish] ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " "))
        }
        let wood = l.floor.finish == "laminate" || l.floor.finish == "parquet"
        parts.append("floor: " + [(wood ? woodEn(l.floor.color) : colorEn(l.floor.color)) + " (\(l.floor.color))", floors[l.floor.finish] ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " "))
        parts.append("ceiling: " + [colorEn(l.ceiling.color), lights[l.ceiling.light] ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
        if let c = curtains[l.curtains] { parts.append("windows: " + c) }
        return "The client chose these finishes\(edited ? "" : " and furniture"), show exactly them: \(parts.joined(separator: "; "))."
    }

    /// Задание сметчику по скану: точные размеры и объёмы из сметы приложения
    static func estimateRequest(_ r: RoomResult) -> String {
        var s = "Помещение: \(r.room). Размеры измерены лидаром iPhone, считай по ним, не выдумывай.\n"
        s += "Длина \(m(r.length)) м, ширина \(m(r.width)) м, высота \(m(r.height)) м, периметр \(m(r.perimeter)) м, "
        s += "пол \(m(r.floorArea)) м², стены без проёмов \(m(r.wallArea)) м², проёмы \(m(r.openingsArea)) м².\n"
        let rows = Estimate.rows(for: r).filter { Estimate.isOn($0) && $0.section == .materials }
        if !rows.isEmpty {
            s += "Объёмы материалов уже посчитаны:\n" + rows.map { "• \($0.title): \(Estimate.qty($0.qty, $0.unit)) \($0.unit)" }.joined(separator: "\n")
        }
        return s + "\nСоставь смету на полный косметический ремонт по этим объёмам."
    }
}

/// Нейросеть для комнаты: сначала напрямую (свой ключ kie.ai), иначе через бота, если он подключён
enum RoomAI {
    /// Ремонт на фото комнаты
    static func design(_ r: RoomResult, style: String, look: Look?) async throws -> URL {
        let changed = look.map { $0 != (RenoStyle(rawValue: $0.style) ?? .scandi).finishes } ?? false
        if let photo = r.photo {
            return try await Kie.editImage(photo, prompt: AIPrompts.fill(AIPrompts.scanDesign, [
                "style": AIPrompts.styleEn(style), "facts": AIPrompts.facts(r, look: nil),
                "look": AIPrompts.lookText(changed ? look : nil, edited: false)]))
        }
        return try await Kie.generateImage(prompt: AIPrompts.fill(AIPrompts.scanT2I, [
            "style": AIPrompts.styleEn(style), "facts": AIPrompts.facts(r, look: look),
            "look": AIPrompts.lookText(changed ? look : nil, edited: true)]))
    }

    /// Снимок 3D → фото «как в жизни»
    static func render(_ r: RoomResult, snapshot: Data, look: Look) async throws -> URL {
        try await Kie.editImage(snapshot, prompt: AIPrompts.fill(AIPrompts.scanRender, [
            "style": AIPrompts.styleEn(look.style), "facts": AIPrompts.facts(r, look: look),
            "look": AIPrompts.lookText(look, edited: true)]))
    }
}
