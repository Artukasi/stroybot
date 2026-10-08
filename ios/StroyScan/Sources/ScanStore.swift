import Foundation
import Network
import SwiftUI
import simd

/// Скан в истории «Мои комнаты». Сам скан, фото и 3D-модель лежат в папке записи.
struct SavedScan: Identifiable, Codable, Equatable {
    var id = UUID()
    var created = Date()
    var updated = Date()
    var room: String
    var floorArea: Double
    var wallArea: Double
    var score: Int
    /// Квартира, в которую входит комната
    var flat: UUID?
    /// Номер скана в боте и адрес бота, куда он ушёл (после переподключения номер другой)
    var botScanId: Int?
    var botServer: String?
    /// Ждёт отправки: не было связи с ботом
    var pending = false
    /// Ремонт, собранный в 3D (JSON как для бота)
    var look: Data?
    /// Растёт при пересъёмке и досъёмке: экран комнаты открывается заново
    var revision = 0
}

/// Квартира: комнаты, снятые подряд. Если снимали за один раз (iOS 17), у комнат общие координаты
struct SavedFlat: Identifiable, Codable, Equatable {
    var id = UUID()
    var created = Date()
    var name: String
    var rooms: [UUID] = []
    /// Контур пола каждой комнаты в общих координатах квартиры, метры (пусто — комнаты снимали по отдельности)
    var outlines: [UUID: [[Double]]] = [:]
}

/// История сканов и очередь отправки в бот. Всё хранится в телефоне, в папке приложения.
@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var scans: [SavedScan] = []
    @Published private(set) var flats: [SavedFlat] = []
    /// Идёт отправка из очереди
    @Published private(set) var flushing = false

    private let root: URL
    private var monitor: NWPathMonitor?
    private var timer: Timer?

    private struct Index: Codable {
        var scans: [SavedScan]
        var flats: [SavedFlat]
    }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("StroyScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: root.appendingPathComponent("index.json")),
           let index = try? JSONDecoder().decode(Index.self, from: data) {
            scans = index.scans
            flats = index.flats
        }
    }

    var pendingCount: Int { scans.filter(\.pending).count }

    /// Комнаты без квартиры, новые сверху
    var singles: [SavedScan] { scans.filter { $0.flat == nil }.sorted { $0.updated > $1.updated } }

    func scan(_ id: UUID) -> SavedScan? { scans.first { $0.id == id } }
    func flat(_ id: UUID) -> SavedFlat? { flats.first { $0.id == id } }
    func rooms(of flat: SavedFlat) -> [SavedScan] { flat.rooms.compactMap { scan($0) } }

    // MARK: - Запись

    /// Новый скан в историю. Возвращает его запись
    @discardableResult
    func add(_ result: RoomResult, flat: UUID? = nil) -> SavedScan {
        var s = SavedScan(room: result.room, floorArea: result.floorArea, wallArea: result.wallArea,
                          score: result.quality.score, flat: flat)
        write(result, to: s.id)
        s.updated = Date()
        scans.append(s)
        persist()
        return s
    }

    /// Скан изменился (название, фото, пересъёмка). Отправленный в бот надо будет отправить заново
    func update(_ id: UUID, result: RoomResult, resend: Bool = false, archive: Bool = false) {
        guard let i = scans.firstIndex(where: { $0.id == id }) else { return }
        if archive { keepVersion(id) }
        write(result, to: id)
        scans[i].room = result.room
        scans[i].floorArea = result.floorArea
        scans[i].wallArea = result.wallArea
        scans[i].score = result.quality.score
        scans[i].updated = Date()
        if resend {
            scans[i].botScanId = nil
            scans[i].botServer = nil
            scans[i].revision += 1
        }
        persist()
    }

    func setLook(_ id: UUID, _ look: Look) {
        guard let i = scans.firstIndex(where: { $0.id == id }) else { return }
        scans[i].look = try? JSONSerialization.data(withJSONObject: look.json)
        persist()
    }

    func look(_ id: UUID) -> Look? {
        guard let data = scan(id)?.look,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let base = (json["style"] as? String).flatMap(RenoStyle.init(rawValue:))?.finishes ?? RenoStyle.scandi.finishes
        return Look(json: json, base: base)
    }

    /// Скан ушёл в бот
    func setSent(_ id: UUID, botScanId: Int, server: String) {
        guard let i = scans.firstIndex(where: { $0.id == id }) else { return }
        scans[i].botScanId = botScanId
        scans[i].botServer = server
        scans[i].pending = false
        persist()
    }

    /// Номер скана в боте, если он отправлен в тот же бот, что подключён сейчас
    func botScanId(_ id: UUID, server: String) -> Int? {
        guard let s = scan(id), s.botServer == server else { return nil }
        return s.botScanId
    }

    func setPending(_ id: UUID, _ on: Bool) {
        guard let i = scans.firstIndex(where: { $0.id == id }) else { return }
        scans[i].pending = on
        persist()
    }

    func delete(_ id: UUID) {
        scans.removeAll { $0.id == id }
        for i in flats.indices {
            flats[i].rooms.removeAll { $0 == id }
            flats[i].outlines[id] = nil
        }
        flats.removeAll { $0.rooms.isEmpty }
        try? FileManager.default.removeItem(at: folder(id))
        persist()
    }

    func addFlat(name: String, rooms: [(RoomResult, [[Double]]?)]) -> SavedFlat {
        var f = SavedFlat(name: name)
        for (result, outline) in rooms {
            let s = add(result, flat: f.id)
            f.rooms.append(s.id)
            if let outline { f.outlines[s.id] = outline }
        }
        flats.append(f)
        persist()
        return f
    }

    func renameFlat(_ id: UUID, _ name: String) {
        guard let i = flats.firstIndex(where: { $0.id == id }) else { return }
        flats[i].name = name
        persist()
    }

    /// Общая 3D-модель квартиры (iOS 17, если комнаты снимали за один раз)
    func flatModel(_ id: UUID) -> URL? {
        let url = flatModelURL(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func flatModelURL(_ id: UUID) -> URL { root.appendingPathComponent("Квартира-\(id.uuidString.prefix(8)).usdz") }

    func deleteFlat(_ id: UUID) {
        guard let f = flat(id) else { return }
        try? FileManager.default.removeItem(at: flatModelURL(id))
        for r in f.rooms { try? FileManager.default.removeItem(at: folder(r)) }
        scans.removeAll { $0.flat == id }
        flats.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Чтение

    func result(_ id: UUID) -> RoomResult? {
        let dir = folder(id)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("scan.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var r = RoomResult(stored: json) else { return nil }
        r.photo = try? Data(contentsOf: dir.appendingPathComponent("photo.jpg"))
        let usdz = dir.appendingPathComponent("Комната.usdz")
        if FileManager.default.fileExists(atPath: usdz.path) { r.usdz = usdz }
        return r
    }

    func photo(_ id: UUID) -> UIImage? {
        UIImage(contentsOfFile: folder(id).appendingPathComponent("photo.jpg").path)
    }

    // MARK: - Прошлые съёмки (прогресс стройки)

    /// Прошлая съёмка комнаты: когда снята и что было
    struct Version: Identifiable {
        let id: String
        let date: Date
        let result: RoomResult
    }

    static let maxVersions = 10

    /// Пересъёмка: прежний скан и фото уходят в «versions/<время>», чтобы сравнить «было — стало»
    private func keepVersion(_ id: UUID) {
        let dir = folder(id)
        let scan = dir.appendingPathComponent("scan.json")
        guard FileManager.default.fileExists(atPath: scan.path) else { return }
        let date = scans.first { $0.id == id }?.updated ?? Date()
        let v = dir.appendingPathComponent("versions/\(Int(date.timeIntervalSince1970))", isDirectory: true)
        try? FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: v.appendingPathComponent("scan.json"))
        try? FileManager.default.copyItem(at: scan, to: v.appendingPathComponent("scan.json"))
        let photo = dir.appendingPathComponent("photo.jpg")
        if FileManager.default.fileExists(atPath: photo.path) {
            try? FileManager.default.removeItem(at: v.appendingPathComponent("photo.jpg"))
            try? FileManager.default.copyItem(at: photo, to: v.appendingPathComponent("photo.jpg"))
        }
        // старые съёмки сверх десяти — удаляем
        let all = versionFolders(id)
        for old in all.dropLast(Self.maxVersions) { try? FileManager.default.removeItem(at: old) }
    }

    private func versionFolders(_ id: UUID) -> [URL] {
        let dir = folder(id).appendingPathComponent("versions", isDirectory: true)
        let list = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return list.filter { Int($0.lastPathComponent) != nil }.sorted { Int($0.lastPathComponent)! < Int($1.lastPathComponent)! }
    }

    /// Прошлые съёмки, старые сначала
    func versions(_ id: UUID) -> [Version] {
        versionFolders(id).compactMap { v in
            guard let data = try? Data(contentsOf: v.appendingPathComponent("scan.json")),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  var r = RoomResult(stored: json), let t = Int(v.lastPathComponent) else { return nil }
            r.photo = try? Data(contentsOf: v.appendingPathComponent("photo.jpg"))
            return Version(id: v.lastPathComponent, date: Date(timeIntervalSince1970: TimeInterval(t)), result: r)
        }
    }

    func versionCount(_ id: UUID) -> Int { versionFolders(id).count }

    // MARK: - Очередь отправки

    /// Следим за сетью и раз в минуту пробуем отправить то, что ждёт
    func startQueue(_ link: BotLink) {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.flush(link) }
        }
        m.start(queue: DispatchQueue(label: "stroyscan.net"))
        monitor = m
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.flush(link) }
        }
    }

    /// Отправляет сканы из очереди. Нет связи — оставляет до следующего раза
    func flush(_ link: BotLink) async {
        guard !flushing, link.connected, pendingCount > 0 else { return }
        flushing = true
        defer { flushing = false }
        var sent: [String] = []
        for s in scans where s.pending {
            guard let result = result(s.id) else { setPending(s.id, false); continue }
            do {
                guard let id = try await link.sendScan(result) else { continue }
                setSent(s.id, botScanId: id, server: link.server)
                if let l = look(s.id) { try? await link.saveLook(scanId: id, look: l.json) }
                sent.append(s.room)
            } catch {
                // нет связи — попробуем позже; бот отказал по делу (код устарел) — скажет кнопка отправки
                break
            }
        }
        if !sent.isEmpty {
            link.message = sent.count == 1 ? "Скан «\(sent[0])» ушёл в бот." : "Сканы ушли в бот: \(sent.joined(separator: ", "))."
        }
    }

    // MARK: - Файлы

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func write(_ r: RoomResult, to id: UUID) {
        let dir = folder(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: r.stored) {
            try? data.write(to: dir.appendingPathComponent("scan.json"), options: .atomic)
        }
        let photo = dir.appendingPathComponent("photo.jpg")
        if let p = r.photo { try? p.write(to: photo, options: .atomic) } else { try? FileManager.default.removeItem(at: photo) }
        let usdz = dir.appendingPathComponent("Комната.usdz")
        if let src = r.usdz, src != usdz {
            try? FileManager.default.removeItem(at: usdz)
            try? FileManager.default.copyItem(at: src, to: usdz)
        }
    }

    // MARK: - Резервная копия

    /// Папка со всеми сканами (её и копируем в бот)
    nonisolated var folderURL: URL { root }

    /// Растёт при каждом изменении истории — по нему видно, что копию пора обновить
    var changes: Int { UserDefaults.standard.integer(forKey: "store.changes") }

    /// Сканы и квартиры из копии, которых нет в телефоне. Те, что уже есть, не трогаем
    func importBackup(from dir: URL) -> (rooms: Int, flats: Int)? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return nil }
        let fm = FileManager.default
        var rooms = 0, addedFlats = 0
        for scan in index.scans where self.scan(scan.id) == nil {
            let src = dir.appendingPathComponent(scan.id.uuidString, isDirectory: true)
            guard fm.fileExists(atPath: src.appendingPathComponent("scan.json").path) else { continue }
            try? fm.removeItem(at: folder(scan.id))
            guard (try? fm.copyItem(at: src, to: folder(scan.id))) != nil else { continue }
            var s = scan
            s.pending = false
            scans.append(s)
            rooms += 1
        }
        for f in index.flats where flat(f.id) == nil {
            var f = f
            f.rooms = f.rooms.filter { scan($0) != nil }
            guard !f.rooms.isEmpty else { continue }
            flats.append(f)
            addedFlats += 1
        }
        persist()
        return (rooms, addedFlats)
    }

    private func persist() {
        UserDefaults.standard.set(changes + 1, forKey: "store.changes")
        let index = Index(scans: scans, flats: flats)
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
        }
    }
}

// MARK: - Скан в файл и обратно

extension RoomResult {
    /// Всё для истории: то же, что уходит в бот (без фото), плюс то, чего бот не знает
    var stored: [String: Any] {
        var d = payload
        d["photo"] = nil
        d["item_bottoms"] = items.map { ($0.bottom * 1000).rounded() / 1000 }
        d["weak_walls"] = Array(quality.weakWalls).sorted()
        d["engineering"] = engineering.json
        d["defects"] = defects.map(\.json)
        if let f = worldFrame { d["world_frame"] = [f.x, f.y, f.z, f.w] }
        return d
    }

    /// Скан из истории или из файла «.stroyscan.json»
    init?(stored d: [String: Any]) {
        self.init()
        let num = { (v: Any?) -> Double? in (v as? NSNumber)?.doubleValue }
        guard let walls = d["walls"] as? [[String: Any]] else { return nil }
        room = d["room"] as? String ?? "Комната"
        let sizes = d["sizes"] as? [String: Any] ?? [:]
        height = num(sizes["height"]) ?? 0
        length = num(sizes["length"]) ?? 0
        width = num(sizes["width"]) ?? 0
        self.walls = walls.map { w in
            Wall(length: num(w["length"]) ?? 0, height: num(w["height"]) ?? 0, openingsArea: num(w["openings_area"]) ?? 0)
        }
        wallLines = (d["wall_lines"] as? [[Any]] ?? []).compactMap { l in
            let v = l.compactMap(num)
            return v.count == 4 ? SIMD4(v[0], v[1], v[2], v[3]) : nil
        }
        plan = (d["plan"] as? [[Any]] ?? []).compactMap { p in
            let v = p.compactMap(num)
            return v.count == 2 ? SIMD2(v[0], v[1]) : nil
        }
        openings = (d["openings"] as? [[String: Any]] ?? []).map { o in
            Opening(kind: o["kind"] as? String ?? "opening", width: num(o["width"]) ?? 0, height: num(o["height"]) ?? 0,
                    wall: (o["wall"] as? NSNumber)?.intValue, offset: num(o["offset"]), bottom: num(o["bottom"]))
        }
        let bottoms = (d["item_bottoms"] as? [Any] ?? []).map { num($0) ?? 0 }
        items = (d["objects"] as? [[String: Any]] ?? []).enumerated().map { i, o in
            Item(kind: o["kind"] as? String ?? "object", width: num(o["width"]) ?? 0, height: num(o["height"]) ?? 0,
                 depth: num(o["depth"]) ?? 0, x: num(o["x"]) ?? 0, y: num(o["y"]) ?? 0, angle: num(o["angle"]) ?? 0,
                 bottom: i < bottoms.count ? bottoms[i] : 0)
        }
        if let q = d["quality"] as? [String: Any] {
            quality.score = (q["score"] as? NSNumber)?.intValue ?? 100
            quality.issues = q["issues"] as? [String] ?? []
        }
        quality.weakWalls = Set((d["weak_walls"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue })
        if let p = d["photo"] as? String { photo = Data(base64Encoded: p) }
        if let e = d["engineering"] as? [String: Any] { engineering = Engineering(json: e) }
        defects = (d["defects"] as? [[String: Any]] ?? []).prefix(Defect.max).compactMap(Defect.init(json:))
        if let f = (d["world_frame"] as? [Any])?.compactMap(num), f.count == 4 { worldFrame = SIMD4(f[0], f[1], f[2], f[3]) }
    }
}
