import SwiftUI
import UIKit

// MARK: - Стили

/// Стиль ремонта. Ключи совпадают с bot/prompts.py → DESIGN_STYLES.
enum RenoStyle: String, CaseIterable, Identifiable {
    case scandi, loft, modern, classic, japandi, budget

    var id: String { rawValue }
    var title: String { designStyles.first { $0.key == rawValue }?.title ?? rawValue }

    /// Отделка и свет стиля по умолчанию
    var finishes: Look {
        var l = Look()
        l.style = rawValue
        switch self {
        case .scandi:
            l.wall = .init(finish: "paint", color: "#f2efe9")
            l.floor = .init(finish: "laminate", color: "#d0b38c")
            l.ceiling = .init(light: "pendant", color: "#ffffff")
            l.curtains = "curtains"
        case .loft:
            l.wall = .init(finish: "brick", color: "#8e4a36")
            l.floor = .init(finish: "concrete", color: "#8e8c88")
            l.ceiling = .init(light: "track", color: "#dad8d4")
            l.curtains = "blinds"
        case .modern:
            l.wall = .init(finish: "paint", color: "#e4e0da")
            l.floor = .init(finish: "parquet", color: "#a98260")
            l.ceiling = .init(light: "spots", color: "#ffffff")
            l.curtains = "curtains"
        case .classic:
            l.wall = .init(finish: "wallpaper", color: "#e6d9c2", pattern: "damask")
            l.floor = .init(finish: "parquet", color: "#7a5234")
            l.ceiling = .init(light: "chandelier_classic", color: "#ffffff")
            l.curtains = "curtains"
        case .japandi:
            l.wall = .init(finish: "plaster", color: "#d9d0c1")
            l.floor = .init(finish: "laminate", color: "#b8946e")
            l.ceiling = .init(light: "pendant", color: "#f4f1ea")
            l.curtains = "roman"
        case .budget:
            l.wall = .init(finish: "wallpaper", color: "#ede8df", pattern: "linen")
            l.floor = .init(finish: "laminate", color: "#c4a480")
            l.ceiling = .init(light: "chandelier_modern", color: "#ffffff")
            l.curtains = "curtains"
        }
        return l
    }

    /// Цвета мебели, дверей и мелочей
    var palette: Palette3D {
        switch self {
        case .scandi:
            return Palette3D(fabric: "#bfb8ac", wood: "#d9be96", metal: rgb(0.12, 0.12, 0.13), accent: "#c9a66b",
                             appliance: "#f2f2f0", trim: rgb(0.97, 0.97, 0.96), door: "#f4f2ee",
                             bedding: rgb(0.96, 0.95, 0.93), curtain: "#efebe3", leather: false)
        case .loft:
            return Palette3D(fabric: "#6b4a35", wood: "#5a3e2b", metal: rgb(0.08, 0.08, 0.09), accent: "#2e3a4a",
                             appliance: "#3a3b3d", trim: rgb(0.12, 0.12, 0.13), door: "#3b2f28",
                             bedding: rgb(0.86, 0.85, 0.83), curtain: "#9a968f", leather: true)
        case .modern:
            return Palette3D(fabric: "#8c8c88", wood: "#8a6546", metal: rgb(0.10, 0.10, 0.11), accent: "#4f6250",
                             appliance: "#dadbdd", trim: rgb(0.98, 0.98, 0.98), door: "#edebe7",
                             bedding: rgb(0.97, 0.97, 0.96), curtain: "#9a968f", leather: false)
        case .classic:
            return Palette3D(fabric: "#d9cbb0", wood: "#6e4a2e", metal: rgb(0.78, 0.62, 0.33), accent: "#2f4f3e",
                             appliance: "#eeeae2", trim: rgb(0.98, 0.97, 0.94), door: "#f2eee6",
                             bedding: rgb(0.97, 0.95, 0.90), curtain: "#c9b48a", leather: false)
        case .japandi:
            return Palette3D(fabric: "#cfc6b6", wood: "#b08d68", metal: rgb(0.10, 0.10, 0.10), accent: "#6f7f63",
                             appliance: "#3a3936", trim: rgb(0.45, 0.36, 0.27), door: "#b08d68",
                             bedding: rgb(0.91, 0.88, 0.83), curtain: "#d8cdbb", leather: false)
        case .budget:
            return Palette3D(fabric: "#9a9a94", wood: "#c9a57a", metal: rgb(0.72, 0.73, 0.75), accent: "#5b7fa6",
                             appliance: "#f2f2f0", trim: rgb(0.97, 0.97, 0.96), door: "#e9e4da",
                             bedding: rgb(0.97, 0.97, 0.96), curtain: "#dad3c6", leather: false)
        }
    }
}

/// Цвета мебели и деталей в стиле (#rrggbb — то, что можно поменять в редакторе)
struct Palette3D {
    let fabric: String
    let wood: String
    let metal: UIColor
    let accent: String
    let appliance: String
    /// Плинтус, наличники, рамы окон
    let trim: UIColor
    let door: String
    let bedding: UIColor
    let curtain: String
    /// Мягкая мебель в коже
    let leather: Bool
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
    UIColor(red: r, green: g, blue: b, alpha: 1)
}

extension UIColor {
    /// "#rrggbb" → цвет
    convenience init(hex: String) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0xCCCCCC
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Яркость 0…1 (для выбора: лак или дерево, светлая или тёмная подсветка)
    var luma: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

// MARK: - Ремонт, собранный в 3D

/// Правки ремонта в 3D: отделка, свет, шторы, замена и расстановка мебели.
/// Те же ключи, что у Mini App и бота (см. bot/look.py).
struct Look: Equatable {
    struct Finish: Equatable {
        var finish: String
        var color: String
        var pattern: String = "plain"
    }
    struct Accent: Equatable {
        var wall: Int
        var finish: String
        var color: String
        var pattern: String = "plain"
    }
    struct Floor: Equatable {
        var finish: String
        var color: String
    }
    struct Ceiling: Equatable {
        var light: String
        var color: String
    }
    /// Правка отсканированного предмета
    struct Item: Equatable {
        var variant: String?
        var color: String?
        var hidden = false
    }
    /// Добавленная мебель: координаты плана, метры
    struct Added: Equatable, Identifiable {
        var id = UUID()
        var kind: String
        var variant: String
        var color: String
        var width: Double
        var depth: Double
        var height: Double
        var x: Double
        var y: Double
        var angle: Double

        static func == (a: Added, b: Added) -> Bool {
            a.kind == b.kind && a.variant == b.variant && a.color == b.color && a.width == b.width
                && a.depth == b.depth && a.height == b.height && a.x == b.x && a.y == b.y && a.angle == b.angle
        }
    }

    var style = "scandi"
    var wall = Finish(finish: "paint", color: "#f2efe9")
    var accent: Accent?
    var floor = Floor(finish: "laminate", color: "#d0b38c")
    var ceiling = Ceiling(light: "pendant", color: "#ffffff")
    var curtains = "curtains"
    var objects: [String: Item] = [:]
    var added: [Added] = []

    static let maxAdded = 30

    /// Новый стиль: отделка и свет из стиля, выбранные варианты мебели остаются, цвета — из стиля
    func withStyle(_ s: RenoStyle) -> Look {
        var l = s.finishes
        l.objects = objects.mapValues { o in
            var o = o
            o.color = nil
            return o
        }
        l.added = added.map { a in
            var a = a
            a.color = LookOptions.defaultColor(kind: a.kind, variant: a.variant, palette: s.palette)
            return a
        }
        return l
    }

    var palette: Palette3D { (RenoStyle(rawValue: style) ?? .scandi).palette }

    /// JSON как в контракте (для бота и файла скана)
    var json: [String: Any] {
        let r = { (v: Double) in (v * 1000).rounded() / 1000 }
        var out: [String: Any] = [:]
        out["style"] = style
        out["wall"] = ["finish": wall.finish, "color": wall.color, "pattern": wall.pattern]
        if let accent {
            let a: [String: Any] = ["wall": accent.wall, "finish": accent.finish, "color": accent.color,
                                    "pattern": accent.pattern]
            out["accent"] = a
        }
        out["floor"] = ["finish": floor.finish, "color": floor.color]
        out["ceiling"] = ["light": ceiling.light, "color": ceiling.color]
        out["curtains"] = curtains
        var objs: [String: Any] = [:]
        for (key, o) in objects {
            var d: [String: Any] = ["hidden": o.hidden]
            if let v = o.variant { d["variant"] = v }
            if let c = o.color { d["color"] = c }
            objs[key] = d
        }
        out["objects"] = objs
        out["added"] = added.prefix(Look.maxAdded).map { a -> [String: Any] in
            ["kind": a.kind, "variant": a.variant, "color": a.color,
             "width": r(a.width), "depth": r(a.depth), "height": r(a.height),
             "x": r(a.x), "y": r(a.y), "angle": r(a.angle)]
        }
        return out
    }

    /// Разбор ответа бота: незнакомое отбрасываем, недостающее берём из `base`
    init(json: [String: Any], base: Look) {
        self = base
        if let s = json["style"] as? String, let st = RenoStyle(rawValue: s) {
            self = st.finishes
            objects = base.objects
            added = base.added
        }
        if let w = json["wall"] as? [String: Any] {
            wall = Look.surface(w, base: wall)
        }
        accent = nil
        if let a = json["accent"] as? [String: Any], let i = (a["wall"] as? NSNumber)?.intValue, i >= 0 {
            let f = Look.surface(a, base: wall)
            accent = Accent(wall: i, finish: f.finish, color: f.color, pattern: f.pattern)
        }
        if let f = json["floor"] as? [String: Any] {
            if let v = f["finish"] as? String, LookOptions.floorFinishes.contains(where: { $0.id == v }) { floor.finish = v }
            if let c = Look.hex(f["color"]) { floor.color = c }
        }
        if let c = json["ceiling"] as? [String: Any] {
            if let v = c["light"] as? String, LookOptions.lights.contains(where: { $0.id == v }) { ceiling.light = v }
            if let col = Look.hex(c["color"]) { ceiling.color = col }
        }
        if let v = json["curtains"] as? String, LookOptions.curtains.contains(where: { $0.id == v }) { curtains = v }
        if let objs = json["objects"] as? [String: Any] {
            var parsed: [String: Item] = [:]
            for (key, raw) in objs {
                guard Int(key) != nil, let d = raw as? [String: Any] else { continue }
                var item = Item()
                item.variant = d["variant"] as? String
                item.color = Look.hex(d["color"])
                item.hidden = (d["hidden"] as? Bool) ?? false
                parsed[key] = item
            }
            objects = parsed
        }
        if let list = json["added"] as? [[String: Any]] {
            let palette = self.palette
            added = list.prefix(Look.maxAdded).compactMap { d in
                guard let kind = d["kind"] as? String, LookOptions.addable.contains(where: { $0.id == kind }) else { return nil }
                let num = { (k: String) in (d[k] as? NSNumber)?.doubleValue }
                guard let w = num("width"), let dp = num("depth"), let h = num("height"),
                      let x = num("x"), let y = num("y") else { return nil }
                var variant = d["variant"] as? String ?? "default"
                let known = LookOptions.variants(kind)
                if !known.isEmpty, !known.contains(where: { $0.id == variant }) { variant = known[0].id }
                if known.isEmpty { variant = "default" }
                let color = Look.hex(d["color"]) ?? LookOptions.defaultColor(kind: kind, variant: variant, palette: palette)
                return Added(kind: kind, variant: variant, color: color, width: w, depth: dp, height: h,
                             x: x, y: y, angle: num("angle") ?? 0)
            }
        }
    }

    init() {}

    private static func surface(_ d: [String: Any], base: Finish) -> Finish {
        var f = base
        if let v = d["finish"] as? String, LookOptions.wallFinishes.contains(where: { $0.id == v }) { f.finish = v }
        if let c = hex(d["color"]) { f.color = c }
        if let p = d["pattern"] as? String, LookOptions.patterns.contains(where: { $0.id == p }) { f.pattern = p }
        return f
    }

    /// Цвет строго как #rrggbb
    static func hex(_ v: Any?) -> String? {
        guard let s = v as? String, s.count == 7, s.first == "#", s.dropFirst().allSatisfy(\.isHexDigit) else { return nil }
        return s.lowercased()
    }
}

// MARK: - Что можно выбрать

struct Choice: Identifiable, Hashable {
    let id: String
    let title: String
}

enum LookOptions {
    static let wallFinishes = [
        Choice(id: "paint", title: "Краска"), Choice(id: "wallpaper", title: "Обои"),
        Choice(id: "plaster", title: "Штукатурка"), Choice(id: "panels", title: "Панели"),
        Choice(id: "tile", title: "Плитка"), Choice(id: "brick", title: "Кирпич"),
    ]
    static let patterns = [
        Choice(id: "plain", title: "Однотонные"), Choice(id: "stripes", title: "Полоска"),
        Choice(id: "geometric", title: "Геометрия"), Choice(id: "floral", title: "Цветы"),
        Choice(id: "damask", title: "Дамаск"), Choice(id: "linen", title: "Под лён"),
    ]
    static let floorFinishes = [
        Choice(id: "laminate", title: "Ламинат"), Choice(id: "parquet", title: "Паркет ёлочкой"),
        Choice(id: "tile", title: "Плитка"), Choice(id: "stone", title: "Под камень"),
        Choice(id: "carpet", title: "Ковролин"), Choice(id: "concrete", title: "Микроцемент"),
    ]
    static let lights = [
        Choice(id: "chandelier_classic", title: "Люстра классика"), Choice(id: "chandelier_modern", title: "Люстра современная"),
        Choice(id: "pendant", title: "Подвесы"), Choice(id: "spots", title: "Споты"),
        Choice(id: "track", title: "Трек"), Choice(id: "ring", title: "Кольцо"), Choice(id: "none", title: "Без люстры"),
    ]
    static let curtains = [
        Choice(id: "curtains", title: "Шторы"), Choice(id: "blinds", title: "Жалюзи"),
        Choice(id: "roman", title: "Римские"), Choice(id: "none", title: "Без штор"),
    ]

    static func variants(_ kind: String) -> [Choice] {
        switch kind {
        case "sofa":
            return [Choice(id: "straight", title: "Прямой"), Choice(id: "corner", title: "Угловой"),
                    Choice(id: "chesterfield", title: "Честерфилд"), Choice(id: "modular", title: "Модульный")]
        case "bed":
            return [Choice(id: "upholstered", title: "Мягкое изголовье"), Choice(id: "platform", title: "Низкая"),
                    Choice(id: "classic", title: "Классика")]
        case "chair":
            return [Choice(id: "dining", title: "Стул"), Choice(id: "armchair", title: "Кресло"),
                    Choice(id: "stool", title: "Табурет")]
        case "table":
            return [Choice(id: "dining_rect", title: "Обеденный"), Choice(id: "dining_round", title: "Круглый"),
                    Choice(id: "coffee", title: "Журнальный"), Choice(id: "desk", title: "Письменный")]
        case "storage":
            return [Choice(id: "wardrobe", title: "Шкаф"), Choice(id: "dresser", title: "Комод"),
                    Choice(id: "shelving", title: "Стеллаж"), Choice(id: "tv_stand", title: "Тумба ТВ")]
        default:
            return []
        }
    }

    /// Что можно добавить в комнату
    static let addable = [
        Choice(id: "sofa", title: "Диван"), Choice(id: "bed", title: "Кровать"), Choice(id: "chair", title: "Стул / кресло"),
        Choice(id: "table", title: "Стол"), Choice(id: "storage", title: "Шкаф / комод"),
        Choice(id: "television", title: "Телевизор"), Choice(id: "refrigerator", title: "Холодильник"),
        Choice(id: "stove", title: "Плита"), Choice(id: "sink", title: "Раковина"),
        Choice(id: "dishwasher", title: "Посудомойка"), Choice(id: "washerDryer", title: "Стиральная машина"),
        Choice(id: "toilet", title: "Унитаз"), Choice(id: "bathtub", title: "Ванна"),
        Choice(id: "fireplace", title: "Камин"),
    ]

    static let wallColors = ["#f4f1ea", "#e9e4da", "#dcd3c4", "#c9c2b6", "#b8bfb4", "#a7b6c2",
                             "#e3c9b8", "#7c8b7a", "#4a5a6a", "#8e4a36", "#3a3b3d"]
    static let fabricColors = ["#ece8e1", "#cfc6b6", "#a9a195", "#8c8c88", "#5b5f66", "#2f3a4a",
                               "#4f6250", "#8a5a44", "#c49a5a", "#7a2e35", "#1f1f21"]
    static let woodColors = ["#f2f0eb", "#e3cba4", "#d9be96", "#b08d68", "#8a6546", "#6e4a2e",
                             "#4e3526", "#2b211c", "#1e1e1f"]
    static let floorColors = ["#e2cfaf", "#d0b38c", "#b8946e", "#a07a55", "#7a5234", "#4e3526",
                              "#c9c6bf", "#8e8c88", "#edeae4", "#3a3a3c"]
    static let applianceColors = ["#f4f4f2", "#d6d7d9", "#8e9094", "#2b2c2e", "#e8dcc6"]
    static let ceramicColors = ["#f7f7f5", "#eceae4", "#d9d6cf", "#2b2c2e"]
    static let ceilingColors = ["#ffffff", "#f4f1ea", "#e9e4da", "#d5d3cf", "#3a3b3d"]

    /// Мягкая мебель — ткань, остальное — дерево или техника
    static func isSoft(_ kind: String, _ variant: String) -> Bool {
        kind == "sofa" || kind == "bed" || (kind == "chair" && variant == "armchair")
    }

    static func colors(kind: String, variant: String) -> [String] {
        if isSoft(kind, variant) { return fabricColors }
        switch kind {
        case "table", "storage", "chair", "stairs": return woodColors
        case "sink", "toilet", "bathtub", "fireplace": return ceramicColors
        default: return applianceColors
        }
    }

    static func defaultColor(kind: String, variant: String, palette: Palette3D) -> String {
        if isSoft(kind, variant) { return palette.fabric }
        switch kind {
        case "table", "storage", "chair", "stairs": return palette.wood
        case "television": return "#2b2c2e"
        case "sink", "toilet", "bathtub": return "#f7f7f5"
        case "fireplace": return "#eceae4"
        default: return palette.appliance
        }
    }

    /// Вариант отсканированного предмета, если пользователь его не менял
    static func defaultVariant(_ item: RoomResult.Item) -> String {
        switch item.kind {
        case "sofa": return item.depth > 1.3 && item.width > 1.8 ? "corner" : "straight"
        case "bed": return "upholstered"
        case "chair": return item.width > 0.66 ? "armchair" : (item.height < 0.62 ? "stool" : "dining")
        case "table": return item.height < 0.56 ? "coffee" : "dining_rect"
        case "storage":
            if item.height > 1.35 { return item.depth < 0.45 ? "shelving" : "wardrobe" }
            return item.height < 0.62 && item.width > 1.0 ? "tv_stand" : "dresser"
        default: return "default"
        }
    }

    /// Обычный размер новой мебели: ширина, глубина, высота, метры
    static func size(kind: String, variant: String) -> SIMD3<Double> {
        switch (kind, variant) {
        case ("sofa", "corner"): return SIMD3(2.6, 1.65, 0.85)
        case ("sofa", "chesterfield"): return SIMD3(2.2, 0.95, 0.76)
        case ("sofa", "modular"): return SIMD3(2.8, 1.05, 0.72)
        case ("sofa", _): return SIMD3(2.1, 0.95, 0.85)
        case ("bed", "platform"): return SIMD3(1.7, 2.15, 0.75)
        case ("bed", "classic"): return SIMD3(1.7, 2.15, 1.15)
        case ("bed", _): return SIMD3(1.8, 2.2, 1.15)
        case ("chair", "armchair"): return SIMD3(0.8, 0.85, 0.85)
        case ("chair", "stool"): return SIMD3(0.4, 0.4, 0.65)
        case ("chair", _): return SIMD3(0.46, 0.52, 0.86)
        case ("table", "dining_round"): return SIMD3(1.1, 1.1, 0.75)
        case ("table", "coffee"): return SIMD3(1.1, 0.6, 0.42)
        case ("table", "desk"): return SIMD3(1.2, 0.6, 0.75)
        case ("table", _): return SIMD3(1.6, 0.9, 0.75)
        case ("storage", "dresser"): return SIMD3(1.2, 0.45, 0.85)
        case ("storage", "shelving"): return SIMD3(0.9, 0.35, 1.9)
        case ("storage", "tv_stand"): return SIMD3(1.8, 0.42, 0.5)
        case ("storage", _): return SIMD3(1.6, 0.6, 2.3)
        case ("television", _): return SIMD3(1.23, 0.08, 0.72)
        case ("refrigerator", _): return SIMD3(0.6, 0.66, 1.9)
        case ("stove", _): return SIMD3(0.6, 0.6, 0.85)
        case ("sink", _): return SIMD3(0.8, 0.48, 0.85)
        case ("dishwasher", _): return SIMD3(0.6, 0.57, 0.82)
        case ("washerDryer", _): return SIMD3(0.6, 0.55, 0.85)
        case ("toilet", _): return SIMD3(0.38, 0.66, 0.78)
        case ("bathtub", _): return SIMD3(1.7, 0.75, 0.58)
        case ("fireplace", _): return SIMD3(1.2, 0.4, 1.1)
        default: return SIMD3(0.8, 0.5, 0.8)
        }
    }

    /// Мебель, которую ставят спиной к стене
    static func againstWall(_ kind: String, _ variant: String) -> Bool {
        switch kind {
        case "sofa", "bed", "storage", "television", "refrigerator", "stove", "sink", "dishwasher",
             "washerDryer", "toilet", "bathtub", "fireplace": return true
        case "table": return variant == "desk"
        default: return false
        }
    }
}
