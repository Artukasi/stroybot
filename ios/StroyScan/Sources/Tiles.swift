import CoreImage
import PhotosUI
import SceneKit
import SwiftUI
import simd

// MARK: - Своя плитка

/// Плитка из библиотеки: картинка одной плитки, размер и что известно о покупке
struct TileItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Размер одной плитки, см
    var width: Double
    var height: Double
    /// м² в коробке (0 — не знаем)
    var perBox: Double = 0
    /// Цена за м², ₽ (0 — не знаем)
    var price: Double = 0
    var link: String?

    /// Размер в метрах
    var w: Double { width / 100 }
    var h: Double { height / 100 }
    var sizeText: String { "\(fmt(width))×\(fmt(height)) см" }
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
    var isEmpty: Bool { zones.isEmpty }

    static let maxZones = 60

    var json: [String: Any] {
        let r = { (v: Double) in (v * 1000).rounded() / 1000 }
        return ["zones": zones.map { z in
            ["wall": z.wall, "tile": z.tile.uuidString, "from": r(z.from), "to": r(z.to), "pattern": z.pattern.rawValue,
             "joint": z.joint, "grout": z.grout] as [String: Any]
        }]
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
        var area: Double
        var pieces: Int
        var buyArea: Double
        var boxes: Int?
        var cost: Double?
        var surfaces: [String]
    }

    struct Total {
        var lines: [Line] = []
        var area: Double = 0
        var glueBags = 0
        var groutKg: Double = 0
        var crosses = 0
        var cost: Double = 0
    }

    static func surfaceName(_ z: Tiling.Zone, _ room: Room3D) -> String {
        if z.isFloor { return "пол" }
        let (a, b) = span(z, room)
        let full = a < 0.01 && b > room.height - 0.01
        return "стена \(z.wall + 1)" + (full ? "" : " (\(Int((a * 100).rounded()))–\(Int((b * 100).rounded())) см)")
    }

    static func total(_ tiling: Tiling, items: [UUID: TileItem], room: Room3D) -> Total {
        var t = Total()
        var byTile: [UUID: Line] = [:]
        var order: [UUID] = []
        var glueKg = 0.0
        for z in tiling.zones {
            guard let tile = items[z.tile], tile.w > 0.01, tile.h > 0.01 else { continue }
            let a = area(z, room)
            guard a > 0.001 else { continue }
            let one = tile.w * tile.h
            let pieces = Int((a / one * (1 + z.pattern.waste)).rounded(.up))
            var line = byTile[tile.id] ?? Line(id: tile.id, tile: tile, area: 0, pieces: 0, buyArea: 0, boxes: nil, cost: nil, surfaces: [])
            if byTile[tile.id] == nil { order.append(tile.id) }
            line.area += a
            line.pieces += pieces
            line.surfaces.append(surfaceName(z, room))
            byTile[tile.id] = line
            // клей: крупная плитка — больше; затирка: (A+B)/(A·B) · шов · глубина · 1,6
            let side = max(tile.width, tile.height)
            glueKg += a * (side >= 60 ? 6.5 : side >= 30 ? 5 : 3.5)
            let wmm = tile.width * 10, hmm = tile.height * 10
            t.groutKg += a * (wmm + hmm) / (wmm * hmm) * z.joint * 8 * 1.6
            t.crosses += Int((Double(pieces) * 1.1).rounded(.up))
            t.area += a
        }
        for id in order {
            guard var line = byTile[id] else { continue }
            line.buyArea = Double(line.pieces) * line.tile.w * line.tile.h
            if line.tile.perBox > 0 {
                let boxes = Int((line.buyArea / line.tile.perBox).rounded(.up))
                line.boxes = boxes
                line.buyArea = max(line.buyArea, Double(boxes) * line.tile.perBox)
            }
            if line.tile.price > 0 {
                line.cost = line.buyArea * line.tile.price
                t.cost += line.cost ?? 0
            }
            t.lines.append(line)
        }
        t.glueBags = Int((glueKg / 25).rounded(.up))
        return t
    }

    /// Список для магазина — текстом
    static func text(_ t: Total, room: String) -> String {
        var out = ["Плитка · \(room)"]
        for l in t.lines {
            var s = "• \(l.tile.name) \(l.tile.sizeText): \(l.pieces) шт ≈ \(fmt((l.buyArea * 100).rounded() / 100)) м²"
            if let b = l.boxes { s += ", коробок: \(b)" }
            if let c = l.cost { s += ", ≈ \(money(c))" }
            out.append(s + " (\(l.surfaces.joined(separator: ", ")))")
            if let link = l.tile.link, !link.isEmpty { out.append("  \(link)") }
        }
        out.append("• Клей для плитки: \(t.glueBags) меш. по 25 кг")
        out.append("• Затирка: ≈ \(fmt((t.groutKg * 10).rounded(.up) / 10)) кг")
        out.append("• Крестики: ≈ \(t.crosses) шт")
        if t.cost > 0 { out.append("Плитка всего ≈ \(money(t.cost))") }
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
        let jointM = z.joint / 1000
        let cellW = tile.w + jointM, cellH = tile.h + jointM
        let rows = z.pattern == .offset ? 2 : 1
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = image(tile, z, rows: rows) ?? UIColor(white: 0.9, alpha: 1)
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        m.roughness.contents = NSNumber(value: 0.32)
        m.metalness.contents = NSNumber(value: 0)
        var t = SCNMatrix4MakeScale(Float(1 / cellW), Float(1 / (cellH * Double(rows))), 1)
        if z.pattern == .diagonal { t = SCNMatrix4Mult(SCNMatrix4MakeRotation(.pi / 4, 0, 0, 1), t) }
        m.diffuse.contentsTransform = t
        return m
    }

    /// Одна клетка (или две строки вразбежку): плитка и шов вокруг
    static func image(_ tile: TileItem, _ z: Tiling.Zone, rows: Int) -> UIImage? {
        guard let src = TileFiles.image(tile.id) else { return nil }
        let jointM = z.joint / 1000
        let cellW = tile.w + jointM, cellH = tile.h + jointM
        let k = 512 / max(cellW, cellH)
        let pw = max(8, (cellW * k).rounded()), ph = max(8, (cellH * k).rounded())
        let j = max(1, jointM * k)
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
        engHint = id == nil ? nil : "Нажмите на стену или пол — плитка ляжет туда"
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
        if let tool = tileTool, tileItems[tool] != nil {
            if let i = tiling.zones.firstIndex(where: { $0.wall == s }) {
                tiling.zones[i].tile = tool
                tileSelected = tiling.zones[i].id
            } else if tiling.zones.count < Tiling.maxZones {
                let z = Tiling.Zone(wall: s, tile: tool, from: 0, to: 0)
                tiling.zones.append(z)
                tileSelected = z.id
            }
            engHint = "Плитка легла. Нажмите на другую стену или пол — положу туда же"
            buildTiles()
        } else {
            tileSelected = tiling.zones.first { $0.wall == s }?.id
            engHint = tileSelected == nil ? "Выберите плитку внизу, потом нажмите сюда" : nil
        }
    }

    private func tileMaterial(_ tile: TileItem, _ z: Tiling.Zone) -> SCNMaterial {
        let key = "\(tile.id)-\(z.pattern.rawValue)-\(z.joint)-\(z.grout)"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    ForEach(library.tiles) { t in thumb(t) }
                }
                .padding(.vertical, 2)
            }
            if library.tiles.isEmpty {
                Text("Добавьте свою плитку: сфотографируйте её или вставьте ссылку с сайта магазина.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { auto = true } label: {
                    Label("Подобрать сам", systemImage: "wand.and.stars").font(.subheadline.bold())
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(library.tiles.isEmpty)
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
            TileAddView { t, img in
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
            ForEach(library.tiles.prefix(6)) { t in
                Button("Основная: \(t.name)") {
                    let floor = library.tiles.first { $0.id != t.id }?.id
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
                    if let img = TileFiles.image(t.id) {
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

    @ViewBuilder private func zonePanel(_ z: Tiling.Zone) -> some View {
        let room = editor.room
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
            Picker("Раскладка", selection: Binding(get: { z.pattern }, set: { p in editor.editZone { $0.pattern = p } })) {
                ForEach(Tiling.Pattern.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
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
                Spacer()
                Button(role: .destructive) { editor.removeZone() } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Убрать плитку")
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
                            if let img = TileFiles.image(l.tile.id) {
                                Image(uiImage: img).resizable().scaledToFill().frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            VStack(alignment: .leading) {
                                Text(l.tile.name).font(.headline)
                                Text("\(l.tile.sizeText) · \(l.surfaces.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        row("Площадь укладки", "\(fmt((l.area * 100).rounded() / 100)) м²")
                        row("Плиток с запасом", "\(l.pieces) шт")
                        row("Купить", "\(fmt((l.buyArea * 100).rounded() / 100)) м²")
                        if let b = l.boxes { row("Коробок", "\(b)") }
                        if let c = l.cost { row("Стоимость", TileCalc.money(c)) }
                        if let link = l.tile.link, let url = URL(string: link) {
                            Link(destination: url) { Label("Открыть в магазине", systemImage: "cart") }
                        }
                    }
                }
                Section("Ещё понадобится") {
                    row("Клей для плитки", "\(total.glueBags) меш. по 25 кг")
                    row("Затирка", "≈ \(fmt((total.groutKg * 10).rounded(.up) / 10)) кг")
                    row("Крестики", "≈ \(total.crosses) шт")
                    if total.cost > 0 { row("Плитка всего", TileCalc.money(total.cost)) }
                }
                Section {
                    Text("Запас на подрезку и бой: прямо — 10%, вразбежку — 12%, по диагонали — 15%. Окна и двери вычтены. Коробки и цена — если вы их указали у плитки.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Плитка · \(room)")
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
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // из «поделиться» часто приходит текст со ссылкой внутри
        if let r = s.range(of: #"https?://\S+"#, options: .regularExpression) { s = String(s[r]) }
        guard let url = URL(string: s), url.scheme?.hasPrefix("http") == true else { throw Problem.badURL }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        req.setValue("ru-RU,ru;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { throw Problem.download }
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) ?? ""
        guard var found = parse(html, base: url) else { throw Problem.noImage }
        var imgReq = URLRequest(url: found.image, timeoutInterval: 20)
        imgReq.setValue(agent, forHTTPHeaderField: "User-Agent")
        imgReq.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        guard let (imgData, _) = try? await URLSession.shared.data(for: imgReq), let img = UIImage(data: imgData) else {
            throw Problem.noImage
        }
        if found.name.isEmpty { found.name = url.host ?? "Плитка" }
        return (found, img)
    }

    /// og:image, twitter:image или картинка из описания товара; название и размер «60×60 см» / «600x600 мм»
    static func parse(_ html: String, base: URL) -> TileLinkFound? {
        let metas = meta(html)
        let raw = metas["og:image"] ?? metas["og:image:secure_url"] ?? metas["twitter:image"] ?? jsonImage(html)
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
        guard let re = try? NSRegularExpression(pattern: #""image"\s*:\s*\[?\s*"(https?:[^"]+)""#),
              let m = re.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) else { return nil }
        return (html as NSString).substring(with: m.range(at: 1)).replacingOccurrences(of: "\\/", with: "/")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
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

/// Новая плитка: фото (камера или галерея) или ссылка, рамка по размеру плитки, цвет, размеры и коробка
struct TileAddView: View {
    var editing: TileItem? = nil
    let onSave: (TileItem, UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable { case photo = "Фото", link = "Ссылка" }

    @State private var source = Source.photo
    @State private var picked: PhotosPickerItem?
    @State private var camera = false
    @State private var linkText = ""
    @State private var loading = false
    @State private var problem: String?
    @State private var photo: UIImage?
    @State private var name = ""
    @State private var width = "30"
    @State private var height = "60"
    @State private var perBox = ""
    @State private var price = ""
    @State private var link: String?
    @State private var fixColor = true
    @State private var zoom: CGFloat = 1
    @State private var zoomStart: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var offsetStart: CGSize = .zero
    /// Размер окна с рамкой на экране — по нему считаем, что вырезать
    @State private var cropView = CGSize(width: 360, height: 300)

    init(editing: TileItem? = nil, onSave: @escaping (TileItem, UIImage?) -> Void) {
        self.editing = editing
        self.onSave = onSave
        if let t = editing {
            _name = State(initialValue: t.name)
            _width = State(initialValue: fmt(t.width))
            _height = State(initialValue: fmt(t.height))
            _perBox = State(initialValue: t.perBox > 0 ? fmt(t.perBox) : "")
            _price = State(initialValue: t.price > 0 ? fmt(t.price) : "")
            _link = State(initialValue: t.link)
        }
    }

    private func number(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
    private var tileW: Double { min(max(number(width) ?? 30, 2), 320) }
    private var tileH: Double { min(max(number(height) ?? 30, 2), 320) }

    var body: some View {
        NavigationStack {
            Form {
                if editing == nil {
                    Section {
                        Picker("Откуда", selection: $source) {
                            ForEach(Source.allCases, id: \.self) { Text($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        if source == .photo {
                            Button { camera = true } label: { Label("Сфотографировать плитку", systemImage: "camera") }
                            PhotosPicker(selection: $picked, matching: .images) { Label("Выбрать из галереи", systemImage: "photo") }
                            Text("Снимайте плитку прямо, без бликов, при дневном свете — лучше целиком.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            TextField("Ссылка на плитку в магазине", text: $linkText, axis: .vertical)
                                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button { Task { await loadLink() } } label: {
                                HStack {
                                    if loading { ProgressView() }
                                    Text(loading ? "Загружаю…" : "Взять плитку со страницы")
                                }
                            }
                            .disabled(linkText.isEmpty || loading)
                            Text("Любой сайт: Леруа Мерлен, Петрович, ОБИ, Керамин, Kerama Marazzi и другие. Возьму картинку, название и размер.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                    }
                }
                if let photo {
                    Section {
                        cropper(photo)
                            .frame(height: 300)
                            .listRowInsets(EdgeInsets())
                        Toggle("Подогнать цвет и яркость", isOn: $fixColor)
                    } header: {
                        Text("Двигайте и приближайте фото — в рамке одна плитка")
                    }
                } else if let t = editing, let img = TileFiles.image(t.id) {
                    Section {
                        Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 200).frame(maxWidth: .infinity)
                    }
                }
                Section("Плитка") {
                    TextField("Название", text: $name)
                    HStack {
                        TextField("Ширина", text: $width).keyboardType(.decimalPad)
                        Text("×")
                        TextField("Высота", text: $height).keyboardType(.decimalPad)
                        Text("см").foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("м² в коробке (если знаете)", text: $perBox).keyboardType(.decimalPad)
                        Text("м²").foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("Цена за м² (если знаете)", text: $price).keyboardType(.decimalPad)
                        Text("₽").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(editing == nil ? "Своя плитка" : "Плитка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }.disabled(photo == nil && editing == nil)
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
        }
    }

    private func use(_ img: UIImage) {
        photo = TileImage.upright(img)
        zoom = 1
        offset = .zero
        offsetStart = .zero
        problem = nil
    }

    private func loadLink() async {
        loading = true
        problem = nil
        defer { loading = false }
        do {
            let (found, img) = try await TileLink.fetch(linkText)
            use(img)
            name = found.name
            if let w = found.width, let h = found.height {
                width = fmt(w)
                height = fmt(h)
            }
            link = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
            fixColor = false   // фото из магазина уже обработано
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Рамка по пропорциям плитки; фото под ней двигают и приближают
    private func cropper(_ img: UIImage) -> some View {
        GeometryReader { geo in
            let frame = TileImage.frame(in: geo.size, aspect: tileW / tileH)
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
        var t = editing ?? TileItem(name: "", width: 30, height: 30)
        t.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Плитка \(fmt(tileW))×\(fmt(tileH))" : name
        t.width = tileW
        t.height = tileH
        t.perBox = max(0, number(perBox) ?? 0)
        t.price = max(0, number(price) ?? 0)
        t.link = link ?? t.link
        var out: UIImage?
        if let photo {
            // какую часть фото видно в рамке — та и плитка. Размер рамки на экране не важен: считаем в долях
            let view = cropView
            let frame = TileImage.frame(in: view, aspect: tileW / tileH)
            let scale = TileImage.fill(photo.size, frame.size) * zoom
            let originX = view.width / 2 + offset.width - photo.size.width * scale / 2
            let originY = view.height / 2 + offset.height - photo.size.height * scale / 2
            let crop = CGRect(x: (frame.minX - originX) / scale, y: (frame.minY - originY) / scale,
                              width: frame.width / scale, height: frame.height / scale)
            let src = fixColor ? (TileImage.enhanced(photo) ?? photo) : photo
            out = TileImage.crop(src, crop, aspect: tileW / tileH)
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
