import CoreImage
import PhotosUI
import SceneKit
import SwiftUI
import simd

// MARK: - Своя плитка

/// Отделка из библиотеки: плитка, обои, краска или ламинат/паркет. Картинка — одна плитка, доска или раппорт обоев
struct TileItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case tile, wallpaper, paint, board
        var id: String { rawValue }
        var title: String {
            switch self {
            case .tile: return "Плитка"
            case .wallpaper: return "Обои"
            case .paint: return "Краска"
            case .board: return "Пол"
            }
        }
        var onWalls: Bool { self != .board }
        var onFloor: Bool { self == .tile || self == .board }
    }

    var id = UUID()
    var kind: Kind = .tile
    var name: String
    /// Плитка: размер, см. Доска: длина × ширина, см. Обои: ширина рулона × раппорт (0 — без раппорта), см
    var width: Double
    var height: Double
    /// Плитка и пол: м² в коробке или пачке (0 — не знаем)
    var perBox: Double = 0
    /// Плитка и пол: ₽ за м². Обои: ₽ за рулон. Краска: ₽ за банку
    var price: Double = 0
    var link: String?
    /// Обои: длина рулона, м
    var rollLength: Double = 10.05
    /// Краска: цвет и литров в банке
    var color: String = "#e8e4dc"
    var can: Double = 2.5

    init(kind: Kind = .tile, name: String, width: Double, height: Double) {
        self.kind = kind
        self.name = name
        self.width = width
        self.height = height
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .tile
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Плитка"
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 30
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 30
        perBox = try c.decodeIfPresent(Double.self, forKey: .perBox) ?? 0
        price = try c.decodeIfPresent(Double.self, forKey: .price) ?? 0
        link = try c.decodeIfPresent(String.self, forKey: .link)
        rollLength = try c.decodeIfPresent(Double.self, forKey: .rollLength) ?? 10.05
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#e8e4dc"
        can = try c.decodeIfPresent(Double.self, forKey: .can) ?? 2.5
    }

    /// Размер в метрах
    var w: Double { width / 100 }
    var h: Double { height / 100 }
    /// Обои без раппорта: картинку повторяем квадратом по ширине рулона
    var repeatH: Double { kind == .wallpaper && height <= 0 ? w : h }

    var sizeText: String {
        switch kind {
        case .tile: return "\(fmt(width))×\(fmt(height)) см"
        case .board: return "доска \(fmt(width))×\(fmt(height)) см"
        case .wallpaper: return "рулон \(fmt(width / 100)) м" + (height > 0 ? ", раппорт \(fmt(height)) см" : "")
        case .paint: return "банка \(fmt(can)) л"
        }
    }
}

/// Картинки плиток на диске: Documents/StroyScan/tiles/<id>.jpg и <id>.json. Копия в боте их тоже берёт
enum TileFiles {
    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("StroyScan", isDirectory: true).appendingPathComponent("tiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ id: UUID) -> UIImage? {
        let key = id.uuidString as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(id.uuidString).jpg")),
              let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    static func forget(_ id: UUID) { cache.removeObject(forKey: id.uuidString as NSString) }

    /// Из копии: плитки, которых нет в телефоне
    static func importFrom(_ dir: URL) {
        let src = dir.appendingPathComponent("tiles", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else { return }
        for f in files where !fm.fileExists(atPath: folder.appendingPathComponent(f.lastPathComponent).path) {
            try? fm.copyItem(at: f, to: folder.appendingPathComponent(f.lastPathComponent))
        }
    }
}

@MainActor
final class TileLibrary: ObservableObject {
    @Published private(set) var tiles: [TileItem] = []

    init() { load() }

    func load() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: TileFiles.folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        var list: [(Date, TileItem)] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), let t = try? JSONDecoder().decode(TileItem.self, from: data) else { continue }
            let date = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            list.append((date, t))
        }
        tiles = list.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func item(_ id: UUID) -> TileItem? { tiles.first { $0.id == id } }

    func save(_ t: TileItem, image: UIImage? = nil) {
        let dir = TileFiles.folder
        if let image, let jpeg = image.jpegData(compressionQuality: 0.85) {
            try? jpeg.write(to: dir.appendingPathComponent("\(t.id.uuidString).jpg"), options: .atomic)
            TileFiles.forget(t.id)
        }
        if let data = try? JSONEncoder().encode(t) {
            try? data.write(to: dir.appendingPathComponent("\(t.id.uuidString).json"), options: .atomic)
        }
        if let i = tiles.firstIndex(where: { $0.id == t.id }) { tiles[i] = t } else { tiles.append(t) }
    }

    func remove(_ id: UUID) {
        let dir = TileFiles.folder
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id.uuidString).json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id.uuidString).jpg"))
        TileFiles.forget(id)
        tiles.removeAll { $0.id == id }
    }
}

// MARK: - Где лежит плитка в комнате

/// Плитка в комнате: на полу и на стенах (по высоте от и до), раскладка и шов
struct Tiling: Equatable {
    enum Pattern: String, CaseIterable, Identifiable {
        case straight, offset, diagonal
        var id: String { rawValue }
        var title: String {
            switch self {
            case .straight: return "Прямо"
            case .offset: return "Вразбежку"
            case .diagonal: return "По диагонали"
            }
        }
        /// Запас на подрезку и бой
        var waste: Double {
            switch self {
            case .straight: return 0.10
            case .offset: return 0.12
            case .diagonal: return 0.15
            }
        }
    }

    struct Zone: Equatable, Identifiable {
        var id = UUID()
        /// −1 — пол, иначе номер стены (как в wallLines)
        var wall: Int
        var tile: UUID
        /// Высота от пола, м (у пола не важны)
        var from: Double = 0
        var to: Double = 0
        var pattern: Pattern = .straight
        /// Шов, мм
        var joint: Double = 2
        var grout: String = "#d9d6cf"

        var isFloor: Bool { wall < 0 }
    }

    var zones: [Zone] = []
    /// Своя мебель по ссылке или фото (Pieces.swift)
    var pieces: [CustomPiece] = []
    var isEmpty: Bool { zones.isEmpty }

    static let maxZones = 60

    var json: [String: Any] {
        let r = { (v: Double) in (v * 1000).rounded() / 1000 }
        return ["zones": zones.map { z in
            ["wall": z.wall, "tile": z.tile.uuidString, "from": r(z.from), "to": r(z.to), "pattern": z.pattern.rawValue,
             "joint": z.joint, "grout": z.grout] as [String: Any]
        }, "pieces": pieces.map(\.json)]
    }

    init() {}

    init(json: [String: Any]) {
        let num = { (v: Any?) -> Double? in (v as? NSNumber)?.doubleValue }
        zones = (json["zones"] as? [[String: Any]] ?? []).prefix(Tiling.maxZones).compactMap { d in
            guard let w = (d["wall"] as? NSNumber)?.intValue, let s = d["tile"] as? String, let id = UUID(uuidString: s) else { return nil }
            var z = Zone(wall: w, tile: id)
            z.from = num(d["from"]) ?? 0
            z.to = num(d["to"]) ?? 0
            z.pattern = Pattern(rawValue: d["pattern"] as? String ?? "") ?? .straight
            z.joint = min(max(num(d["joint"]) ?? 2, 0.5), 10)
            z.grout = d["grout"] as? String ?? "#d9d6cf"
            return z
        }
        pieces = (json["pieces"] as? [[String: Any]] ?? []).prefix(CustomPiece.max).compactMap(CustomPiece.init(json:))
    }
}

// MARK: - Расчёт

enum TileCalc {
    /// Куски стены под плитку: от и до по высоте, без окон и дверей. x — вдоль стены от её начала, y — высота
    static func wallRects(_ room: Room3D, pos: Int, from: Float, to: Float) -> [(Float, Float, Float, Float)] {
        guard pos >= 0, pos < room.walls.count, to - from > 0.01 else { return [] }
        let len = room.walls[pos].length
        var out: [(Float, Float, Float, Float)] = []
        var cursor: Float = 0
        for o in room.openings[pos] {
            let l = max(o.left, cursor), r = min(o.right, len)
            guard r - l > 0.2 else { continue }
            if l > cursor + 0.001 { out.append((cursor, l, from, to)) }
            let below = min(o.bottom, to)
            if below > from + 0.001 { out.append((l, r, from, below)) }
            let above = max(o.top, from)
            if to > above + 0.001 { out.append((l, r, above, to)) }
            cursor = r
        }
        if cursor < len - 0.001 { out.append((cursor, len, from, to)) }
        return out
    }

    /// Высота зоны на стене: «до» = 0 — до потолка
    static func span(_ z: Tiling.Zone, _ room: Room3D) -> (Float, Float) {
        let top = room.height
        let from = min(max(Float(z.from), 0), top)
        let to = z.to <= 0 ? top : min(Float(z.to), top)
        return (from, max(from, to))
    }

    static func area(_ z: Tiling.Zone, _ room: Room3D) -> Double {
        if z.isFloor { return Double(abs(Room3D.area(room.polygon))) }
        guard let pos = room.walls.firstIndex(where: { $0.index == z.wall }) else { return 0 }
        let (a, b) = span(z, room)
        return wallRects(room, pos: pos, from: a, to: b).reduce(0) { $0 + Double(($1.1 - $1.0) * ($1.3 - $1.2)) }
    }

    struct Line: Identifiable {
        let id: UUID
        let tile: TileItem
        var area: Double = 0
        var surfaces: [String] = []
        /// Что купить: строки «Плиток с запасом — 120 шт»
        var rows: [(String, String)] = []
        /// Сколько штук, рулонов или банок — для копии в магазин
        var short = ""
        var cost: Double?
        // накопители
        var pieces = 0
        var strips = 0
        var rolls = 0
        var liters = 0.0
    }

    struct Total {
        var lines: [Line] = []
        var area: Double = 0
        /// Расходники: клей, затирка, грунт и т.п.
        var extras: [(String, String)] = []
        var cost: Double = 0
    }

    static func surfaceName(_ z: Tiling.Zone, _ room: Room3D) -> String {
        if z.isFloor { return "пол" }
        let (a, b) = span(z, room)
        let full = a < 0.01 && b > room.height - 0.01
        return "стена \(z.wall + 1)" + (full ? "" : " (\(Int((a * 100).rounded()))–\(Int((b * 100).rounded())) см)")
    }

    static func m2(_ v: Double) -> String { "\(fmt((v * 100).rounded() / 100)) м²" }

    static func total(_ tiling: Tiling, items: [UUID: TileItem], room: Room3D) -> Total {
        var t = Total()
        var byTile: [UUID: Line] = [:]
        var order: [UUID] = []
        var glueKg = 0.0, groutKg = 0.0, crosses = 0
        var wallArea = 0.0, paintArea = 0.0, floorBoards = 0.0, wallpaperRolls = 0
        for z in tiling.zones {
            guard let tile = items[z.tile] else { continue }
            let a = area(z, room)
            guard a > 0.001 else { continue }
            var line = byTile[tile.id] ?? Line(id: tile.id, tile: tile)
            if byTile[tile.id] == nil { order.append(tile.id) }
            line.area += a
            line.surfaces.append(surfaceName(z, room))
            switch tile.kind {
            case .tile, .board:
                guard tile.w > 0.01, tile.h > 0.01 else { break }
                let waste = tile.kind == .board ? 0.07 : z.pattern.waste
                let pieces = Int((a / (tile.w * tile.h) * (1 + waste)).rounded(.up))
                line.pieces += pieces
                if tile.kind == .tile {
                    // клей: крупная плитка — больше; затирка: (A+B)/(A·B) · шов · глубина · 1,6
                    let side = max(tile.width, tile.height)
                    glueKg += a * (side >= 60 ? 6.5 : side >= 30 ? 5 : 3.5)
                    let wmm = tile.width * 10, hmm = tile.height * 10
                    groutKg += a * (wmm + hmm) / (wmm * hmm) * z.joint * 8 * 1.6
                    crosses += Int((Double(pieces) * 1.1).rounded(.up))
                } else {
                    floorBoards += a
                }
            case .wallpaper:
                // полосы: ширина стены / ширина рулона; длина полосы — высота + 10 см, кратно раппорту
                guard let pos = room.walls.firstIndex(where: { $0.index == z.wall }), tile.w > 0.1 else { break }
                let (lo, hi) = span(z, room)
                let width = Double(room.walls[pos].length)
                var strip = Double(hi - lo) + 0.1
                if tile.height > 0 { strip = (strip / tile.h).rounded(.up) * tile.h }
                let strips = Int((width / tile.w).rounded(.up))
                let perRoll = max(1, Int((tile.rollLength / max(strip, 0.3)).rounded(.down)))
                line.strips += strips
                line.rolls += Int((Double(strips) / Double(perRoll)).rounded(.up))
                wallArea += a
            case .paint:
                // два слоя по 0,12 л/м² + 10% запас
                line.liters += a * 2 * 0.12 * 1.1
                paintArea += a
            }
            byTile[tile.id] = line
            t.area += a
        }
        for id in order {
            guard var line = byTile[id] else { continue }
            let tile = line.tile
            line.rows.append(("Площадь", m2(line.area)))
            switch tile.kind {
            case .tile, .board:
                var buy = Double(line.pieces) * tile.w * tile.h
                line.rows.append((tile.kind == .tile ? "Плиток с запасом" : "Досок с запасом", "\(line.pieces) шт"))
                line.short = "\(line.pieces) шт"
                if tile.perBox > 0 {
                    let boxes = Int((buy / tile.perBox).rounded(.up))
                    buy = max(buy, Double(boxes) * tile.perBox)
                    line.rows.append((tile.kind == .tile ? "Коробок" : "Пачек", "\(boxes)"))
                    line.short += ", \(tile.kind == .tile ? "коробок" : "пачек"): \(boxes)"
                }
                line.rows.append(("Купить", m2(buy)))
                if tile.price > 0 { line.cost = buy * tile.price }
            case .wallpaper:
                line.rows.append(("Полос", "\(line.strips)"))
                line.rows.append(("Рулонов (+1 запасной)", "\(line.rolls + 1)"))
                line.short = "рулонов: \(line.rolls + 1)"
                wallpaperRolls += line.rolls + 1
                if tile.price > 0 { line.cost = Double(line.rolls + 1) * tile.price }
            case .paint:
                let cans = Int((line.liters / max(tile.can, 0.5)).rounded(.up))
                line.rows.append(("Краски, 2 слоя", "≈ \(fmt((line.liters * 10).rounded(.up) / 10)) л"))
                line.rows.append(("Банок по \(fmt(tile.can)) л", "\(cans)"))
                line.short = "банок по \(fmt(tile.can)) л: \(cans)"
                if tile.price > 0 { line.cost = Double(cans) * tile.price }
            }
            if let c = line.cost {
                line.rows.append(("Стоимость", money(c)))
                t.cost += c
            }
            t.lines.append(line)
        }
        if glueKg > 0 {
            t.extras.append(("Клей для плитки", "\(Int((glueKg / 25).rounded(.up))) меш. по 25 кг"))
            t.extras.append(("Затирка", "≈ \(fmt((groutKg * 10).rounded(.up) / 10)) кг"))
            t.extras.append(("Крестики", "≈ \(crosses) шт"))
        }
        if wallpaperRolls > 0 {
            t.extras.append(("Клей для обоев", "\(max(1, Int((Double(wallpaperRolls) / 5).rounded(.up)))) уп."))
        }
        if wallArea + paintArea > 0 {
            t.extras.append(("Грунт для стен", "≈ \(Int(((wallArea + paintArea) * 0.15).rounded(.up))) л"))
        }
        if floorBoards > 0 {
            t.extras.append(("Подложка", m2(floorBoards * 1.05)))
            t.extras.append(("Плинтус", "≈ \(Int((Double(room.walls.reduce(0) { $0 + $1.length }) * 1.05).rounded(.up))) м"))
        }
        return t
    }

    /// Список для магазина — текстом
    static func text(_ t: Total, room: String) -> String {
        var out = ["Отделка · \(room)"]
        for l in t.lines {
            var s = "• \(l.tile.kind.title): \(l.tile.name) (\(l.tile.sizeText)) — \(l.short), \(m2(l.area))"
            if let c = l.cost { s += ", ≈ \(money(c))" }
            out.append(s + " — \(l.surfaces.joined(separator: ", "))")
            if let link = l.tile.link, !link.isEmpty { out.append("  \(link)") }
        }
        for (k, v) in t.extras { out.append("• \(k): \(v)") }
        if t.cost > 0 { out.append("Всего ≈ \(money(t.cost))") }
        return out.joined(separator: "\n")
    }

    static func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        f.maximumFractionDigits = 0
        return (f.string(from: NSNumber(value: v.rounded())) ?? "\(Int(v))") + " ₽"
    }
}

// MARK: - Картинка плитки для 3D: плитка со швом, рядом повторяется

enum TileTexture {
    static func material(_ tile: TileItem, _ z: Tiling.Zone) -> SCNMaterial {
        if tile.kind == .paint {
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = UIColor(hex: tile.color)
            m.roughness.contents = NSNumber(value: 0.85)
            return m
        }
        let jointM = tile.kind == .wallpaper ? 0 : z.joint / 1000
        let cellW = tile.w + jointM, cellH = tile.repeatH + jointM
        let rows = z.pattern == .offset ? 2 : 1
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = image(tile, z, rows: rows) ?? UIColor(white: 0.9, alpha: 1)
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        m.roughness.contents = NSNumber(value: tile.kind == .wallpaper ? 0.8 : tile.kind == .board ? 0.45 : 0.32)
        m.metalness.contents = NSNumber(value: 0)
        var t = SCNMatrix4MakeScale(Float(1 / cellW), Float(1 / (cellH * Double(rows))), 1)
        if z.pattern == .diagonal { t = SCNMatrix4Mult(SCNMatrix4MakeRotation(.pi / 4, 0, 0, 1), t) }
        m.diffuse.contentsTransform = t
        return m
    }

    /// Одна клетка (или две строки вразбежку): плитка и шов вокруг
    static func image(_ tile: TileItem, _ z: Tiling.Zone, rows: Int) -> UIImage? {
        guard let src = TileFiles.image(tile.id) else { return nil }
        let jointM = tile.kind == .wallpaper ? 0 : z.joint / 1000
        let cellW = tile.w + jointM, cellH = tile.repeatH + jointM
        let k = 512 / max(cellW, cellH)
        let pw = max(8, (cellW * k).rounded()), ph = max(8, (cellH * k).rounded())
        let j = jointM > 0 ? max(1, jointM * k) : 0
        let size = CGSize(width: pw, height: ph * Double(rows))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let grout = UIColor(hex: z.grout)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            grout.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let w = pw - j, h = ph - j
            src.draw(in: CGRect(x: j / 2, y: j / 2, width: w, height: h))
            if rows == 2 {
                // вторая строка сдвинута на полплитки
                src.draw(in: CGRect(x: j / 2 - pw / 2, y: ph + j / 2, width: w, height: h))
                src.draw(in: CGRect(x: j / 2 + pw / 2, y: ph + j / 2, width: w, height: h))
            }
        }
    }
}

// MARK: - Плитка в 3D-редакторе

extension RenoEditor {
    func setTileItems(_ list: [TileItem]) {
        let dict = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard dict != tileItems else { return }
        tileItems = dict
        tileMats = [:]
        if let t = tileTool, dict[t] == nil { tileTool = nil }
        buildTiles()
    }

    var selectedZone: Tiling.Zone? { tiling.zones.first { $0.id == tileSelected } }

    func setTileTool(_ id: UUID?) {
        tileTool = id
        tileSelected = nil
        let kind = id.flatMap { tileItems[$0]?.kind }
        engHint = kind == nil ? nil : kind == .board ? "Нажмите на пол" : kind!.onFloor ? "Нажмите на стену или пол" : "Нажмите на стену"
    }

    func editZone(_ change: (inout Tiling.Zone) -> Void) {
        guard let i = tiling.zones.firstIndex(where: { $0.id == tileSelected }) else { return }
        change(&tiling.zones[i])
        buildTiles()
    }

    func removeZone() {
        tiling.zones.removeAll { $0.id == tileSelected }
        tileSelected = nil
        buildTiles()
    }

    func tileTap(at p: CGPoint) {
        let hits = view.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.all.rawValue, .ignoreHiddenNodes: true])
        var surface: Int?
        outer: for h in hits {
            var n: SCNNode? = h.node
            while let cur = n {
                if let name = cur.name {
                    if name.hasPrefix("wall:"), let i = Int(name.dropFirst(5)) { surface = i; break outer }
                    if name == "floor" { surface = -1; break outer }
                    if name.hasPrefix("win:") || name.hasPrefix("door:") { break }
                }
                n = cur.parent
            }
        }
        guard let s = surface else {
            tileSelected = nil
            engHint = tileTool == nil ? nil : "Не попали — нажмите на стену или пол"
            return
        }
        if let tool = tileTool, let item = tileItems[tool] {
            if s < 0 && !item.kind.onFloor {
                engHint = "\(item.kind.title) — на стены. Нажмите на стену"
                return
            }
            if s >= 0 && !item.kind.onWalls {
                engHint = "Ламинат и паркет — на пол. Нажмите на пол"
                return
            }
            if let i = tiling.zones.firstIndex(where: { $0.wall == s }) {
                let oldKind = tileItems[tiling.zones[i].tile]?.kind
                tiling.zones[i].tile = tool
                if oldKind != item.kind { Self.defaults(&tiling.zones[i], item.kind) }
                tileSelected = tiling.zones[i].id
            } else if tiling.zones.count < Tiling.maxZones {
                var z = Tiling.Zone(wall: s, tile: tool, from: 0, to: 0)
                Self.defaults(&z, item.kind)
                tiling.zones.append(z)
                tileSelected = z.id
            }
            engHint = "Готово. Нажмите на другую стену или пол — положу туда же"
            buildTiles()
        } else {
            tileSelected = tiling.zones.first { $0.wall == s }?.id
            engHint = tileSelected == nil ? "Выберите плитку внизу, потом нажмите сюда" : nil
        }
    }

    /// Шов и раскладка по виду отделки: доски — вразбежку с тонким тёмным швом, обои и краска — без шва
    static func defaults(_ z: inout Tiling.Zone, _ kind: TileItem.Kind) {
        switch kind {
        case .tile:
            z.pattern = .straight
            z.joint = 2
            z.grout = "#d9d6cf"
        case .board:
            z.pattern = .offset
            z.joint = 0.5
            z.grout = "#3a3530"
        case .wallpaper, .paint:
            z.pattern = .straight
            z.joint = 0.5
        }
    }

    private func tileMaterial(_ tile: TileItem, _ z: Tiling.Zone) -> SCNMaterial {
        let key = "\(tile.id)-\(tile.color)-\(z.pattern.rawValue)-\(z.joint)-\(z.grout)"
        if let m = tileMats[key] { return m }
        let m = TileTexture.material(tile, z)
        tileMats[key] = m
        return m
    }

    /// Плитка поверх пола и стен. Плитка на стене — внутри узла стены: прячется вместе с ней
    func buildTiles() {
        tileHolder.childNodes.forEach { $0.removeFromParentNode() }
        for w in wallNodes { w.childNodes.filter { $0.name == "tiles" }.forEach { $0.removeFromParentNode() } }
        for z in tiling.zones {
            guard let tile = tileItems[z.tile] else { continue }
            let m = tileMaterial(tile, z)
            if z.isFloor {
                guard room.polygon.count > 2 else { continue }
                let n = SCNNode(geometry: Mesh.polygon(room.polygon, y: 0.004, up: true, m))
                n.name = "floor"
                tileHolder.addChildNode(n)
                continue
            }
            guard let pos = room.walls.firstIndex(where: { $0.index == z.wall }), pos < wallNodes.count else { continue }
            let (a, b) = TileCalc.span(z, room)
            let group = SCNNode()
            group.name = "tiles"
            for (x0, x1, y0, y1) in TileCalc.wallRects(room, pos: pos, from: a, to: b) {
                let q = SCNNode(geometry: Mesh.quad(x0, x1, y0, y1, top: 0, m))
                q.simdPosition.z = 0.004
                group.addChildNode(q)
            }
            if z.id == tileSelected {
                // рамка выбранной зоны
                let k = Kit(group)
                let len = room.walls[pos].length
                for (p, q) in [(SIMD3(0, a, 0.01), SIMD3(len, a, 0.01)), (SIMD3(0, b, 0.01), SIMD3(len, b, 0.01)),
                               (SIMD3(0, a, 0.01), SIMD3(0, b, 0.01)), (SIMD3(len, a, 0.01), SIMD3(len, b, 0.01))] as [(SIMD3<Float>, SIMD3<Float>)] {
                    k.rod(p, q, 0.01, Mat.selection).castsShadow = false
                }
            }
            wallNodes[pos].addChildNode(group)
        }
    }

    /// Подобрать раскладку самому по комнате: ванная — стены и пол, кухня — фартук у плиты и мойки, остальное — пол.
    /// main — плитка на стены, floorTile — на пол (если не выбрана — та же)
    func autoTile(main: UUID, floorTile: UUID?) {
        let name = result.room.lowercased()
        var zones: [Tiling.Zone] = []
        let floorID = floorTile ?? main
        if ["ванн", "санузел", "туалет", "душ"].contains(where: { name.contains($0) }) {
            for g in room.walls { zones.append(Tiling.Zone(wall: g.index, tile: main, from: 0, to: 0)) }
            zones.append(Tiling.Zone(wall: -1, tile: floorID, pattern: .straight))
        } else if name.contains("кухн") {
            // фартук — на стене у плиты, мойки или посудомойки; нет их — на самой длинной стене без окна
            let kitchen = result.items.filter { ["stove", "sink", "dishwasher", "oven"].contains($0.kind) }
            var best: Int?
            if let it = kitchen.first, let w = result.nearestWall(SIMD2(it.x, it.y)) { best = w.wall }
            if best == nil {
                best = room.walls.enumerated()
                    .filter { !room.openings[$0.offset].contains { $0.kind == "window" } }
                    .max { $0.element.length < $1.element.length }?.element.index
            }
            if let w = best { zones.append(Tiling.Zone(wall: w, tile: main, from: 0.85, to: 1.45, pattern: .offset)) }
            zones.append(Tiling.Zone(wall: -1, tile: floorID))
        } else {
            zones.append(Tiling.Zone(wall: -1, tile: floorID))
        }
        tiling.zones = zones
        tileSelected = nil
        buildTiles()
    }
}

// MARK: - Панель плитки на экране 3D

struct TilePanel: View {
    @ObservedObject var editor: RenoEditor
    @EnvironmentObject var library: TileLibrary
    @State private var adding = false
    @State private var editing: TileItem?
    @State private var calc = false
    @State private var auto = false
    @State private var kind: TileItem.Kind = .tile

    private var shown: [TileItem] { library.tiles.filter { $0.kind == kind } }
    private var tilesOnly: [TileItem] { library.tiles.filter { $0.kind == .tile } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Что", selection: $kind) {
                ForEach(TileItem.Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Button {
                let on = !editor.furnitureHidden
                editor.setFurnitureHidden(on)
                UserDefaults.standard.set(on, forKey: "tile.hideFurniture")
            } label: {
                Label(editor.furnitureHidden ? "Показать мебель" : "Убрать мебель",
                      systemImage: editor.furnitureHidden ? "sofa" : "sofa.fill")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(editor.furnitureHidden ? AnyShapeStyle(Palette.signal) : AnyShapeStyle(Color(.tertiarySystemFill)),
                                in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(Palette.ink)
            }
            .buttonStyle(.plain)
            if let hint = editor.engHint {
                Label(hint, systemImage: "hand.tap").font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let z = editor.selectedZone { zonePanel(z) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button { adding = true } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "plus").font(.title2.bold())
                                .frame(width: 58, height: 58)
                                .background(Palette.signal, in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(Palette.ink)
                            Text("Своя").font(.caption2.bold())
                        }
                    }
                    .buttonStyle(.plain)
                    ForEach(shown) { t in thumb(t) }
                }
                .padding(.vertical, 2)
            }
            if shown.isEmpty {
                Text(emptyText).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { auto = true } label: {
                    Label("Подобрать сам", systemImage: "wand.and.stars").font(.subheadline.bold())
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(tilesOnly.isEmpty)
                Button { calc = true } label: {
                    Label("Сколько купить", systemImage: "list.number").font(.subheadline.bold())
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Palette.signal, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(Palette.ink)
                }
                .disabled(editor.tiling.isEmpty)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .sheet(isPresented: $adding) {
            TileAddView(kind: kind) { t, img in
                library.save(t, image: img)
                editor.setTileItems(library.tiles)
                editor.setTileTool(t.id)
            }
        }
        .sheet(item: $editing) { t in
            TileAddView(editing: t) { t, img in
                library.save(t, image: img)
                editor.setTileItems(library.tiles)
            }
        }
        .sheet(isPresented: $calc) {
            TileCalcView(total: TileCalc.total(editor.tiling, items: editor.tileItems, room: editor.room), room: editor.result.room)
        }
        .confirmationDialog("Подобрать раскладку", isPresented: $auto, titleVisibility: .visible) {
            ForEach(tilesOnly.prefix(6)) { t in
                Button("Основная: \(t.name)") {
                    let floor = tilesOnly.first { $0.id != t.id }?.id
                    editor.autoTile(main: t.id, floorTile: floor)
                }
            }
        } message: {
            Text("Ванная и санузел — плитка на стены и пол, кухня — фартук у плиты и мойки, другие комнаты — пол. Для пола возьму вторую плитку из списка, если она есть. Потом всё можно поменять нажатием.")
        }
    }

    private func thumb(_ t: TileItem) -> some View {
        let on = editor.tileTool == t.id
        return Button { editor.setTileTool(on ? nil : t.id) } label: {
            VStack(spacing: 4) {
                Group {
                    if t.kind == .paint {
                        Color(UIColor(hex: t.color))
                    } else if let img = TileFiles.image(t.id) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Color.gray
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Palette.signal : Color.primary.opacity(0.12), lineWidth: on ? 3 : 1))
                Text(t.sizeText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 70)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { editing = t } label: { Label("Изменить", systemImage: "pencil") }
            Button(role: .destructive) {
                editor.tiling.zones.removeAll { $0.tile == t.id }
                library.remove(t.id)
                editor.setTileItems(library.tiles)
            } label: { Label("Удалить", systemImage: "trash") }
        }
    }

    private var emptyText: String {
        switch kind {
        case .tile: return "Добавьте свою плитку: сфотографируйте её или вставьте ссылку с сайта магазина."
        case .wallpaper: return "Добавьте обои: фото рисунка или ссылка на рулон в магазине."
        case .paint: return "Добавьте краску: выберите цвет или возьмите его с фото стены, образца, картинки."
        case .board: return "Добавьте ламинат или паркет: фото доски или ссылка из магазина."
        }
    }

    @ViewBuilder private func zonePanel(_ z: Tiling.Zone) -> some View {
        let room = editor.room
        let itemKind = editor.tileItems[z.tile]?.kind ?? .tile
        let (a, b) = TileCalc.span(z, room)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(z.isFloor ? "Пол" : "Стена \(z.wall + 1)").font(.headline)
                Text(editor.tileItems[z.tile]?.name ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { editor.tileSelected = nil; editor.buildTiles() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
            }
            if itemKind == .tile || itemKind == .board {
                Picker("Раскладка", selection: Binding(get: { z.pattern }, set: { p in editor.editZone { $0.pattern = p } })) {
                    ForEach(Tiling.Pattern.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if !z.isFloor {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        preset("Вся стена", 0, 0)
                        preset("До 1,2 м", 0, 1.2)
                        preset("До 1,5 м", 0, 1.5)
                        preset("Фартук", 0.85, 1.45)
                    }
                }
                HStack {
                    Text("От пола \(Int((a * 100).rounded())) см").font(.subheadline)
                    Spacer()
                    Stepper("", onIncrement: { editor.editZone { $0.from = min(Double(b) - 0.1, Double(a) + 0.05) } },
                            onDecrement: { editor.editZone { $0.from = max(0, Double(a) - 0.05) } })
                        .labelsHidden()
                }
                HStack {
                    Text("До \(Int((b * 100).rounded())) см").font(.subheadline)
                    Spacer()
                    Stepper("", onIncrement: { editor.editZone { $0.to = min(Double(room.height), Double(b) + 0.05) } },
                            onDecrement: { editor.editZone { $0.to = max(Double(a) + 0.1, Double(b) - 0.05) } })
                        .labelsHidden()
                }
            }
            if itemKind == .tile {
            HStack(spacing: 8) {
                Text("Шов").font(.subheadline)
                ForEach([1.5, 2, 3, 5], id: \.self) { j in
                    chip("\(fmt(j)) мм", z.joint == j) { editor.editZone { $0.joint = j } }
                }
            }
            HStack(spacing: 10) {
                Text("Затирка").font(.subheadline)
                ForEach(["#f4f2ee", "#d9d6cf", "#9a958c", "#4a4743", "#1e1d1c"], id: \.self) { hex in
                    Button { editor.editZone { $0.grout = hex } } label: {
                        Circle().fill(Color(UIColor(hex: hex))).frame(width: 26, height: 26)
                            .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                            .overlay(Circle().stroke(Palette.signal, lineWidth: z.grout == hex ? 3 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                }
            }
            }
            HStack {
                Spacer()
                Button(role: .destructive) { editor.removeZone() } label: { Label("Убрать", systemImage: "trash") }
                    .font(.subheadline.bold())
            }
            Text("Площадь \(fmt((TileCalc.area(z, room) * 100).rounded() / 100)) м² без окон и дверей")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func preset(_ title: String, _ from: Double, _ to: Double) -> some View {
        chip(title, false) { editor.editZone { $0.from = from; $0.to = to } }
    }

    private func chip(_ title: String, _ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(on ? Palette.signal : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(on ? Palette.ink : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Сколько купить

struct TileCalcView: View {
    let total: TileCalc.Total
    let room: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(total.lines) { l in
                    Section {
                        HStack(spacing: 12) {
                            Group {
                                if l.tile.kind == .paint {
                                    Color(UIColor(hex: l.tile.color))
                                } else if let img = TileFiles.image(l.tile.id) {
                                    Image(uiImage: img).resizable().scaledToFill()
                                } else {
                                    Color.gray
                                }
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading) {
                                Text(l.tile.name).font(.headline)
                                Text("\(l.tile.kind.title) · \(l.tile.sizeText) · \(l.surfaces.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(Array(l.rows.enumerated()), id: \.offset) { _, r in row(r.0, r.1) }
                        if let link = l.tile.link, let url = URL(string: link) {
                            Link(destination: url) { Label("Открыть в магазине", systemImage: "cart") }
                        }
                    }
                }
                if !total.extras.isEmpty || total.cost > 0 {
                    Section("Ещё понадобится") {
                        ForEach(Array(total.extras.enumerated()), id: \.offset) { _, r in row(r.0, r.1) }
                        if total.cost > 0 { row("Всего по ценам", TileCalc.money(total.cost)) }
                    }
                }
                Section {
                    Text("Плитка: запас 10% прямо, 12% вразбежку, 15% по диагонали. Ламинат: +7%. Обои: полосы по высоте с раппортом и один рулон в запас. Краска: 2 слоя. Окна и двери вычтены. Коробки и цена — если вы их указали.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Отделка · \(room)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copied ? "Скопировано" : "Скопировать") {
                        UIPasteboard.general.string = TileCalc.text(total, room: room)
                        copied = true
                    }
                }
            }
        }
    }

    private func row(_ t: String, _ v: String) -> some View {
        HStack {
            Text(t)
            Spacer()
            Text(v).bold().monospacedDigit()
        }
    }
}

// MARK: - Добавить плитку: фото или ссылка

/// Что нашли на странице магазина
struct TileLinkFound {
    var image: URL
    var name: String
    var width: Double?
    var height: Double?
    /// Текст страницы без разметки — в нём ищем размеры мебели
    var text = ""
    /// Адрес страницы товара (после переходов)
    var page: URL?
}

enum TileLink {
    enum Problem: LocalizedError {
        case badURL, noImage, download
        var errorDescription: String? {
            switch self {
            case .badURL: return "Это не похоже на ссылку. Скопируйте адрес страницы плитки в магазине."
            case .noImage: return "На странице не нашлось картинки плитки. Сохраните фото плитки и добавьте его через «Фото»."
            case .download: return "Не получилось открыть страницу. Проверьте интернет или добавьте плитку по фото."
            }
        }
    }

    static let agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static func fetch(_ text: String) async throws -> (TileLinkFound, UIImage) {
        // из «поделиться» часто приходит текст со ссылкой внутри
        guard let url = linkIn(text) else { throw Problem.badURL }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        req.setValue("ru-RU,ru;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { throw Problem.download }
        // защита от ботов отдаёт 403/429 или пустую заглушку — тогда откроем страницу в браузере
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 { throw Problem.download }
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) ?? ""
        guard var found = parse(html, base: url) else { throw Problem.noImage }
        found.text = plain(html)
        found.page = resp.url ?? url
        if found.width == nil, let sz = tileSize(name: found.name, props: "", desc: "", text: found.text) {
            found.width = sz.0
            found.height = sz.1
        }
        var imgReq = URLRequest(url: found.image, timeoutInterval: 20)
        imgReq.setValue(agent, forHTTPHeaderField: "User-Agent")
        imgReq.setValue((found.page ?? url).absoluteString, forHTTPHeaderField: "Referer")
        imgReq.setValue("image/webp,image/jpeg,image/png,*/*", forHTTPHeaderField: "Accept")
        guard let (imgData, response) = try? await URLSession.shared.data(for: imgReq),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              !((response as? HTTPURLResponse)?.mimeType?.lowercased().contains("text/html") ?? false),
              let img = UIImage(data: imgData), img.size.width >= 50, img.size.height >= 50 else {
            throw Problem.noImage
        }
        if found.name.isEmpty { found.name = url.host ?? "Плитка" }
        return (found, img)
    }

    /// og:image, twitter:image или картинка из описания товара; название и размер «60×60 см» / «600x600 мм»
    static func parse(_ html: String, base: URL) -> TileLinkFound? {
        let metas = meta(html)
        let raw = jsonImage(html) ?? metas["og:image:secure_url"] ?? metas["og:image"] ?? metas["twitter:image"]
        guard let raw, let image = URL(string: unescape(raw), relativeTo: base)?.absoluteURL else { return nil }
        var name = unescape(metas["og:title"] ?? title(html) ?? "")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > 80 { name = String(name.prefix(80)) }
        let text = [name, unescape(metas["og:description"] ?? metas["description"] ?? "")].joined(separator: " ")
        let size = TileLink.size(in: text) ?? TileLink.size(in: String(html.prefix(400_000)))
        return TileLinkFound(image: image, name: name, width: size?.0, height: size?.1)
    }

    static func meta(_ html: String) -> [String: String] {
        var out: [String: String] = [:]
        guard let tag = try? NSRegularExpression(pattern: #"<meta\s[^>]*>"#, options: [.caseInsensitive]) else { return out }
        let ns = html as NSString
        for m in tag.matches(in: html, range: NSRange(location: 0, length: min(ns.length, 600_000))) {
            let t = ns.substring(with: m.range)
            guard let key = attr(t, "property") ?? attr(t, "name") ?? attr(t, "itemprop"), let value = attr(t, "content") else { continue }
            let k = key.lowercased()
            if out[k] == nil { out[k] = value }
        }
        return out
    }

    static func attr(_ tag: String, _ name: String) -> String? {
        let pattern = "\(name)\\s*=\\s*([\"'])(.*?)\\1"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        return (tag as NSString).substring(with: m.range(at: 2))
    }

    static func title(_ html: String) -> String? {
        guard let r = html.range(of: #"(?is)<title[^>]*>(.*?)</title>"#, options: .regularExpression) else { return nil }
        return String(html[r]).replacingOccurrences(of: #"(?is)</?title[^>]*>"#, with: "", options: .regularExpression)
    }

    static func jsonImage(_ html: String) -> String? {
        guard let scripts = try? NSRegularExpression(pattern: #"(?is)<script[^>]*type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>"#) else { return nil }
        let ns = html as NSString
        let range = NSRange(location: 0, length: min(ns.length, 600_000))
        for match in scripts.matches(in: html, range: range) {
            let json = ns.substring(with: match.range(at: 1))
            guard let data = json.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let url = productImage(in: value) { return unescape(url).replacingOccurrences(of: "\\/", with: "/") }
        }
        return nil
    }

    private static func productImage(in value: Any, depth: Int = 0) -> String? {
        guard depth < 6 else { return nil }
        if let list = value as? [Any] {
            for item in list { if let url = productImage(in: item, depth: depth + 1) { return url } }
            return nil
        }
        guard let object = value as? [String: Any] else { return nil }
        let rawType = object["@type"]
        let types = (rawType as? [String]) ?? [rawType as? String ?? ""]
        if types.contains(where: {
            let name = $0.split(whereSeparator: { $0 == "/" || $0 == "#" }).last.map(String.init) ?? $0
            return name.caseInsensitiveCompare("Product") == .orderedSame || name.caseInsensitiveCompare("ProductGroup") == .orderedSame
        }),
           let images = object["image"], let url = firstImageURL(in: images) {
            return url
        }
        for key in ["@graph", "mainEntity", "hasVariant", "itemListElement"] {
            if let child = object[key], let url = productImage(in: child, depth: depth + 1) { return url }
        }
        return nil
    }

    private static func firstImageURL(in value: Any) -> String? {
        if let string = value as? String { return string }
        if let list = value as? [Any] { for item in list { if let url = firstImageURL(in: item) { return url } } }
        if let object = value as? [String: Any] {
            return (object["url"] as? String) ?? (object["contentUrl"] as? String) ?? (object["@id"] as? String)
        }
        return nil
    }

    /// Страница без тегов и скриптов (первые 400 тыс. знаков)
    static func plain(_ html: String) -> String {
        var s = String(html.prefix(400_000))
        s = s.replacingOccurrences(of: #"(?is)<(script|style)[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        s = unescape(s).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// Размер плитки по странице: сначала название и характеристики, потом поля «Длина/Ширина», потом весь текст
    static func tileSize(name: String, props: String, desc: String, text: String) -> (Double, Double)? {
        if let s = size(in: name) { return s }
        if let s = fields(props) ?? size(in: props) { return s }
        if let s = size(in: desc) { return s }
        return fields(text) ?? size(in: String(text.prefix(200_000)))
    }

    /// «Ширина (мм): 300 … Длина, см 60» → сантиметры
    static func fields(_ text: String) -> (Double, Double)? {
        let pattern = #"(?i)(длина|ширина|высота)([^0-9\n]{0,40}?)(\d{1,4}(?:[.,]\d{1,2})?)\s*(мм|см|mm|cm)?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        var got: [String: Double] = [:]
        for m in re.matches(in: text, range: NSRange(location: 0, length: min(ns.length, 300_000))) {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            guard got[key] == nil,
                  var v = Double(ns.substring(with: m.range(at: 3)).replacingOccurrences(of: ",", with: ".")), v > 0 else { continue }
            let between = ns.substring(with: m.range(at: 2)).lowercased()
            let unit = m.range(at: 4).location != NSNotFound ? ns.substring(with: m.range(at: 4)).lowercased() : ""
            if unit == "мм" || unit == "mm" || between.contains("мм") || between.contains("mm") || (unit.isEmpty && !between.contains("см") && v > 160) {
                v /= 10
            }
            if v >= 2 && v <= 320 { got[key] = v }
            if got["ширина"] != nil && (got["длина"] != nil || got["высота"] != nil) { break }
        }
        guard let w = got["ширина"], let h = got["длина"] ?? got["высота"] else { return nil }
        return (w, h)
    }

    /// «60x120 см», «600×600 мм», «30 х 60» → сантиметры
    static func size(in text: String) -> (Double, Double)? {
        let pattern = #"(\d{1,4}(?:[.,]\d{1,2})?)\s*[xхXХ×*]\s*(\d{1,4}(?:[.,]\d{1,2})?)\s*(мм|mm|см|cm)?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let a = Double(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: ".")),
                  let b = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ",", with: ".")) else { continue }
            let unit = m.range(at: 3).location != NSNotFound ? ns.substring(with: m.range(at: 3)).lowercased() : ""
            var w = a, h = b
            if unit == "мм" || unit == "mm" || (unit.isEmpty && a >= 100 && b >= 100) {
                w /= 10
                h /= 10
            }
            if w >= 2 && w <= 320 && h >= 2 && h <= 320 { return (w, h) }
        }
        return nil
    }
}

struct BrowseURL: Identifiable {
    let id = UUID()
    let url: URL
}

/// Новая отделка: фото (камера или галерея) или ссылка, рамка по размеру плитки/раппорта, цвет, размеры и упаковка
struct TileAddView: View {
    var editing: TileItem? = nil
    let onSave: (TileItem, UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Source: String, CaseIterable { case photo = "Фото", link = "Ссылка" }

    @State private var kind: TileItem.Kind
    @State private var source = Source.photo
    @State private var picked: PhotosPickerItem?
    @State private var camera = false
    @State private var linkText = ""
    @State private var browse: BrowseURL?
    @State private var loading = false
    @State private var problem: String?
    @State private var importNote: String?
    @State private var photo: UIImage?
    @State private var name = ""
    @State private var width = "30"
    @State private var height = "60"
    @State private var perBox = ""
    @State private var price = ""
    @State private var roll = "10,05"
    @State private var can = "2,5"
    @State private var paint = Color(red: 0.91, green: 0.89, blue: 0.86)
    @State private var link: String?
    @State private var fixColor = true
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetStart: CGSize = .zero
    /// Размер окна с рамкой на экране — по нему считаем, что вырезать
    @State private var cropView = CGSize(width: 360, height: 300)

    init(kind: TileItem.Kind = .tile, editing: TileItem? = nil, onSave: @escaping (TileItem, UIImage?) -> Void) {
        self.editing = editing
        self.onSave = onSave
        let k = editing?.kind ?? kind
        _kind = State(initialValue: k)
        if let t = editing {
            _name = State(initialValue: t.name)
            _width = State(initialValue: fmt(t.width))
            _height = State(initialValue: fmt(t.height))
            _perBox = State(initialValue: t.perBox > 0 ? fmt(t.perBox) : "")
            _price = State(initialValue: t.price > 0 ? fmt(t.price) : "")
            _roll = State(initialValue: fmt(t.rollLength))
            _can = State(initialValue: fmt(t.can))
            _paint = State(initialValue: Color(UIColor(hex: t.color)))
            _link = State(initialValue: t.link)
        } else {
            let d = TileAddView.defaults(k)
            _width = State(initialValue: d.0)
            _height = State(initialValue: d.1)
        }
    }

    static func defaults(_ k: TileItem.Kind) -> (String, String) {
        switch k {
        case .tile: return ("30", "60")
        case .wallpaper: return ("106", "0")
        case .board: return ("138", "19,3")
        case .paint: return ("0", "0")
        }
    }

    private func number(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
    private var tileW: Double { min(max(number(width) ?? 30, 2), 320) }
    private var tileH: Double {
        let v = number(height) ?? 0
        if kind == .wallpaper { return min(max(v, 0), 320) }
        return min(max(v, 2), 320)
    }
    /// Рамка на фото: плитка, доска или кусок обоев на ширину рулона
    private var aspect: Double {
        if kind == .wallpaper { return tileW / (tileH > 0 ? tileH : tileW) }
        return tileW / tileH
    }

    var body: some View {
        NavigationStack {
            Form {
                if editing == nil {
                    Section {
                        Picker("Что", selection: $kind) {
                            ForEach(TileItem.Kind.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: kind) { k in
                            let d = TileAddView.defaults(k)
                            width = d.0
                            height = d.1
                        }
                    }
                }
                if kind == .paint {
                    paintSection
                } else {
                    if editing == nil { sourceSection }
                    if let photo {
                        Section {
                            cropper(photo)
                                .frame(height: 300)
                                .listRowInsets(EdgeInsets())
                            Toggle("Подогнать цвет и яркость", isOn: $fixColor)
                        } header: {
                            Text(kind == .wallpaper ? "Двигайте и приближайте фото — в рамке кусок обоев на ширину рулона"
                                                    : kind == .board ? "Двигайте и приближайте фото — в рамке одна доска"
                                                    : "Двигайте и приближайте фото — в рамке одна плитка")
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if let t = editing, let img = TileFiles.image(t.id) {
                        Section {
                            Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 200).frame(maxWidth: .infinity)
                        }
                    }
                }
                fieldsSection
            }
            .animation(AppMotion.adaptive(reduceMotion: reduceMotion, full: AppMotion.state), value: source)
            .animation(AppMotion.adaptive(reduceMotion: reduceMotion, full: AppMotion.fade), value: photo != nil)
            .navigationTitle(editing == nil ? "Своя отделка" : kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }.disabled(kind != .paint && photo == nil && editing == nil)
                }
            }
            .onChange(of: picked) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { use(img) }
                }
            }
            .fullScreenCover(isPresented: $camera) {
                PhotoCameraView { data in if let img = UIImage(data: data) { use(img) } }
            }
            .sheet(item: $browse) { b in
                ShopPageView(start: b.url, what: kindWord) { found, img in apply(found, img) }
            }
        }
    }

    @ViewBuilder private var sourceSection: some View {
        Section {
            Picker("Откуда", selection: $source) {
                ForEach(Source.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            if source == .photo {
                Button { camera = true } label: { Label("Сфотографировать", systemImage: "camera") }
                PhotosPicker(selection: $picked, matching: .images) { Label("Выбрать из галереи", systemImage: "photo") }
                Text("Снимайте прямо, без бликов, при дневном свете.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField("Вставьте ссылку на товар", text: $linkText, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button {
                        if let t = UIPasteboard.general.string { linkText = t; Task { await loadLink() } }
                    } label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(.borderless)
                }
                Button { Task { await loadLink() } } label: {
                    HStack {
                        if loading { ProgressView() }
                        Text(loading ? "Загружаю…" : "Взять со страницы").bold()
                    }
                }
                .disabled(linkText.isEmpty || loading)
                if let url = linkIn(linkText) {
                    Button { browse = BrowseURL(url: url) } label: {
                        Label("Открыть страницу и выбрать картинку самому", systemImage: "safari")
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Или найдите в магазине:").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ShopSearch.shops, id: \.name) { shop in
                                Button {
                                    if let u = ShopSearch.url(shop.base, searchWord) { browse = BrowseURL(url: u) }
                                } label: {
                                    Text(shop.name).font(.caption.bold())
                                        .padding(.horizontal, 10).padding(.vertical, 7)
                                        .background(Palette.signal.opacity(0.35), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Text("Как это работает: в магазине нажмите «Поделиться» → «Скопировать ссылку», здесь — значок вставки. Если сайт не отдаёт страницу напрямую, она откроется внутри приложения: нажмите «Взять \(kindWord)» и выберите картинку.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            if let importNote { Label(importNote, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var paintSection: some View {
        Section {
            ColorPicker("Цвет краски", selection: $paint, supportsOpacity: false)
            RoundedRectangle(cornerRadius: 14).fill(paint).frame(height: 70)
            Button { camera = true } label: { Label("Взять цвет с фото", systemImage: "eyedropper") }
            PhotosPicker(selection: $picked, matching: .images) { Label("Цвет с картинки из галереи", systemImage: "photo") }
            Text("С фото беру средний цвет середины кадра. Экран телефона показывает цвета чуть иначе, чем стена, — сверяйтесь с веером в магазине.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Цвет")
        }
    }

    @ViewBuilder private var fieldsSection: some View {
        Section(kind.title) {
            TextField("Название", text: $name)
            switch kind {
            case .tile, .board:
                HStack {
                    TextField(kind == .board ? "Длина" : "Ширина", text: $width).keyboardType(.decimalPad)
                    Text("×")
                    TextField(kind == .board ? "Ширина" : "Высота", text: $height).keyboardType(.decimalPad)
                    Text("см").foregroundStyle(.secondary)
                }
                HStack {
                    TextField(kind == .board ? "м² в пачке (если знаете)" : "м² в коробке (если знаете)", text: $perBox).keyboardType(.decimalPad)
                    Text("м²").foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Цена за м² (если знаете)", text: $price).keyboardType(.decimalPad)
                    Text("₽").foregroundStyle(.secondary)
                }
            case .wallpaper:
                HStack {
                    Text("Ширина рулона")
                    TextField("106", text: $width).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    Text("см").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Длина рулона")
                    TextField("10,05", text: $roll).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    Text("м").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Раппорт (0 — нет)")
                    TextField("0", text: $height).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    Text("см").foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Цена за рулон (если знаете)", text: $price).keyboardType(.decimalPad)
                    Text("₽").foregroundStyle(.secondary)
                }
            case .paint:
                HStack {
                    Text("Литров в банке")
                    TextField("2,5", text: $can).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    Text("л").foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Цена за банку (если знаете)", text: $price).keyboardType(.decimalPad)
                    Text("₽").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func use(_ img: UIImage) {
        let up = TileImage.upright(img)
        if kind == .paint {
            if let c = TileImage.average(up) { paint = Color(c) }
            return
        }
        photo = up
        importNote = nil
        zoom = 1
        zoomStart = 1
        offset = .zero
        offsetStart = .zero
        problem = nil
    }

    private var searchWord: String {
        switch kind {
        case .tile: return "керамическая плитка"
        case .wallpaper: return "обои"
        case .board: return "ламинат"
        case .paint: return "краска для стен"
        }
    }

    private var kindWord: String {
        switch kind {
        case .tile: return "плитку"
        case .wallpaper: return "обои"
        case .board: return "ламинат"
        case .paint: return "краску"
        }
    }

    private func loadLink() async {
        loading = true
        problem = nil
        defer { loading = false }
        do {
            let (found, img) = try await TileLink.fetch(linkText)
            apply(found, img)
        } catch TileLink.Problem.badURL {
            problem = TileLink.Problem.badURL.localizedDescription
        } catch {
            // сайт не отдал страницу или картинку «простому» запросу — открываем как в Safari
            if let url = linkIn(linkText) { browse = BrowseURL(url: url) } else { problem = error.localizedDescription }
        }
    }

    private func apply(_ found: TileLinkFound, _ img: UIImage) {
        use(img)
        name = found.name
        if kind == .tile || kind == .board, let w = found.width, let h = found.height {
            // доска: сначала длина, потом ширина
            width = fmt(kind == .board ? max(w, h) : w)
            height = fmt(kind == .board ? min(w, h) : h)
            problem = nil
            importNote = "Размер взят со страницы. Проверьте, что это размер одной плитки или доски, а не упаковки."
        } else if kind == .tile || kind == .board {
            problem = nil
            importNote = "Размер на странице не найден. Впишите формат одной плитки или доски из карточки товара."
        } else {
            importNote = "Фото взято со страницы. Перед раскладкой проверьте размеры и раппорт."
        }
        link = found.page?.absoluteString ?? linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        fixColor = false   // фото из магазина уже обработано
    }

    /// Рамка по пропорциям; фото под ней двигают и приближают
    private func cropper(_ img: UIImage) -> some View {
        GeometryReader { geo in
            let frame = TileImage.frame(in: geo.size, aspect: aspect)
            let base = TileImage.fill(img.size, frame.size)
            ZStack {
                Color.black
                Image(uiImage: fixColor ? (TileImage.enhanced(img) ?? img) : img)
                    .resizable()
                    .frame(width: img.size.width * base * zoom, height: img.size.height * base * zoom)
                    .position(x: geo.size.width / 2 + offset.width, y: geo.size.height / 2 + offset.height)
                // затемнение вокруг рамки
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRect(frame)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                Rectangle().stroke(Palette.signal, lineWidth: 2).frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
            .clipped()
            .contentShape(Rectangle())
            .onAppear { cropView = geo.size }
            .onChange(of: geo.size) { cropView = $0 }
            .gesture(DragGesture()
                .onChanged { v in offset = CGSize(width: offsetStart.width + v.translation.width, height: offsetStart.height + v.translation.height) }
                .onEnded { _ in offsetStart = offset })
            .simultaneousGesture(MagnificationGesture()
                .onChanged { s in zoom = max(1, min(8, zoomStart * s)) }
                .onEnded { _ in zoomStart = zoom })
        }
    }

    private func save() {
        var t = editing ?? TileItem(kind: kind, name: "", width: 30, height: 30)
        t.kind = kind
        let fallback: String
        switch kind {
        case .tile: fallback = "Плитка \(fmt(tileW))×\(fmt(tileH))"
        case .wallpaper: fallback = "Обои \(fmt(tileW / 100)) м"
        case .board: fallback = "Ламинат \(fmt(tileW))×\(fmt(tileH))"
        case .paint: fallback = "Краска"
        }
        t.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : name
        t.width = kind == .paint ? 0 : tileW
        t.height = kind == .paint ? 0 : tileH
        t.perBox = max(0, number(perBox) ?? 0)
        t.price = max(0, number(price) ?? 0)
        t.rollLength = min(max(number(roll) ?? 10.05, 1), 50)
        t.can = min(max(number(can) ?? 2.5, 0.5), 20)
        t.color = UIColor(paint).hexString
        t.link = link ?? t.link
        var out: UIImage?
        if let photo, kind != .paint {
            // какую часть фото видно в рамке — та и картинка
            let view = cropView
            let frame = TileImage.frame(in: view, aspect: aspect)
            let scale = TileImage.fill(photo.size, frame.size) * zoom
            let originX = view.width / 2 + offset.width - photo.size.width * scale / 2
            let originY = view.height / 2 + offset.height - photo.size.height * scale / 2
            let crop = CGRect(x: (frame.minX - originX) / scale, y: (frame.minY - originY) / scale,
                              width: frame.width / scale, height: frame.height / scale)
            let src = fixColor ? (TileImage.enhanced(photo) ?? photo) : photo
            out = TileImage.crop(src, crop, aspect: aspect)
        }
        onSave(t, out)
        dismiss()
    }
}

/// Работа с фото плитки
enum TileImage {
    /// Рамка плитки посередине: 80% меньшей стороны
    static func frame(in size: CGSize, aspect: Double) -> CGRect {
        let maxW = size.width * 0.8, maxH = size.height * 0.8
        var w = maxW, h = maxW / CGFloat(aspect)
        if h > maxH { h = maxH; w = maxH * CGFloat(aspect) }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Во сколько уменьшить фото, чтобы оно закрыло рамку целиком
    static func fill(_ image: CGSize, _ frame: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        return max(frame.width / image.width, frame.height / image.height)
    }

    /// Фото «как держали телефон» → обычная картинка без поворота в метаданных
    static func upright(_ img: UIImage) -> UIImage {
        let longSide = max(img.size.width, img.size.height)
        let k = min(1, 2000 / max(longSide, 1))
        let size = CGSize(width: (img.size.width * k).rounded(), height: (img.size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }

    private static let context = CIContext()
    private static var enhancedCache: (UIImage, UIImage)?

    /// Автоподгонка как в «Фото»: экспозиция, тени, контраст, насыщенность
    static func enhanced(_ img: UIImage) -> UIImage? {
        if let c = enhancedCache, c.0 === img { return c.1 }
        guard var ci = CIImage(image: img) else { return nil }
        for f in ci.autoAdjustmentFilters(options: [.redEye: false]) {
            f.setValue(ci, forKey: kCIInputImageKey)
            if let out = f.outputImage { ci = out }
        }
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        let out = UIImage(cgImage: cg)
        enhancedCache = (img, out)
        return out
    }

    /// Средний цвет середины кадра (40%) — для краски с фото
    static func average(_ img: UIImage) -> UIColor? {
        guard let ci = CIImage(image: img) else { return nil }
        let e = ci.extent
        let rect = CGRect(x: e.midX - e.width * 0.2, y: e.midY - e.height * 0.2, width: e.width * 0.4, height: e.height * 0.4)
        guard let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: rect)]),
              let out = f.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }

    /// Вырезать рамку и привести к размеру плитки (длинная сторона 512)
    static func crop(_ img: UIImage, _ rect: CGRect, aspect: Double) -> UIImage? {
        let longSide: CGFloat = 512
        let size = aspect >= 1 ? CGSize(width: longSide, height: (longSide / CGFloat(aspect)).rounded())
                               : CGSize(width: (longSide * CGFloat(aspect)).rounded(), height: longSide)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let kx = size.width / max(rect.width, 1), ky = size.height / max(rect.height, 1)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            img.draw(in: CGRect(x: -rect.minX * kx, y: -rect.minY * ky, width: img.size.width * kx, height: img.size.height * ky))
        }
    }
}
