import PhotosUI
import SceneKit
import SwiftUI
import simd

// MARK: - Своя мебель по ссылке или фото

/// Вещь из магазина в настоящем размере: коробка с фото товара спереди. Лежит в Tiling.pieces (scan.json → "tiling")
struct CustomPiece: Equatable, Identifiable {
    var id = UUID()
    var name: String
    var link: String?
    /// Ширина, глубина, высота в метрах
    var width: Double
    var depth: Double
    var height: Double
    /// Середина на плане и поворот — как у остальной мебели
    var x: Double = 0
    var y: Double = 0
    var angle: Double = 0

    static let max = 20

    var sizeText: String {
        let cm = { (v: Double) in Int((v * 100).rounded()) }
        return "\(cm(width)) × \(cm(depth)) × \(cm(height)) см"
    }

    var json: [String: Any] {
        let r = { (v: Double) in (v * 1000).rounded() / 1000 }
        var d: [String: Any] = ["id": id.uuidString, "name": name, "w": r(width), "d": r(depth), "h": r(height),
                                "x": r(x), "y": r(y), "angle": r(angle)]
        if let link { d["link"] = link }
        return d
    }

    init(name: String, link: String?, width: Double, depth: Double, height: Double) {
        self.name = name
        self.link = link
        self.width = width
        self.depth = depth
        self.height = height
    }

    init?(json d: [String: Any]) {
        func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        guard let w = num("w"), let dd = num("d"), let h = num("h"),
              (0.05...6).contains(w), (0.05...6).contains(dd), (0.05...4).contains(h) else { return nil }
        id = (d["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        name = String((d["name"] as? String ?? "").prefix(80))
        link = d["link"] as? String
        width = w
        depth = dd
        height = h
        x = num("x") ?? 0
        y = num("y") ?? 0
        angle = num("angle") ?? 0
    }

    static func image(_ id: UUID) -> UIImage? { TileFiles.image(id) }

    static func saveImage(_ img: UIImage, id: UUID) {
        guard let data = img.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: TileFiles.folder.appendingPathComponent("\(id.uuidString).jpg"), options: .atomic)
        TileFiles.forget(id)
    }

    static func removeImage(_ id: UUID) {
        try? FileManager.default.removeItem(at: TileFiles.folder.appendingPathComponent("\(id.uuidString).jpg"))
        TileFiles.forget(id)
    }
}

/// Размеры мебели из текста страницы: «Ширина: 220 см … Глубина … Высота» или «200x90x85 см» (в метрах)
enum PieceSize {
    private static let num = #"(\d+(?:[.,]\d+)?)"#

    private static func value(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }

    /// Без единиц: от 400 — миллиметры, до 4 — метры, иначе сантиметры
    private static func scale(_ unit: String?, _ values: [Double]) -> Double {
        switch unit?.lowercased() {
        case "мм": return 0.001
        case "см": return 0.01
        case "м": return 1
        default:
            let top = values.max() ?? 0
            return top >= 400 ? 0.001 : top <= 4 ? 1 : 0.01
        }
    }

    private static func groups(_ pattern: String, _ text: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    private static func word(_ stem: String, _ text: String) -> Double? {
        let pattern = stem + #"[а-я]*(?:\s*\(?[а-я ,]*\)?)?\s*[:,—-]?\s*"# + num + #"\s*(мм|см|м)?(?![а-я])"#
        guard let g = groups(pattern, text), let s = g[0] else { return nil }
        let v = value(s)
        let m = v * scale(g[1], [v])
        return m > 0 ? m : nil
    }

    static func parse(_ text: String) -> (w: Double?, d: Double?, h: Double?) {
        let t = String(text.prefix(300_000))
        var w = word("ширин", t), d = word("глубин", t)
        let h = word("высот", t), l = word("длин", t)
        if let l {
            if let ww = w, d == nil { w = Swift.max(l, ww); d = Swift.min(l, ww) } else if w == nil { w = l }
        }
        if w != nil, d != nil, h != nil { return (w, d, h) }
        let x = #"\s*[xх×*]\s*"#
        if let g = groups(num + x + num + x + num + #"\s*(мм|см|м)?(?![а-я])"#, t),
           let a = g[0], let b = g[1], let c = g[2] {
            let vs = [value(a), value(b), value(c)]
            let k = scale(g[3], vs)
            return (vs[0] * k, vs[1] * k, vs[2] * k)
        }
        if w != nil, h != nil { return (w, d, h) }
        if let g = groups(num + x + num + #"\s*(мм|см|м)?(?![а-я])"#, t), let a = g[0], let b = g[1] {
            let vs = [value(a), value(b)]
            let k = scale(g[2], vs)
            return (vs[0] * k, vs[1] * k, h)
        }
        return (w, d, h)
    }
}

// MARK: - Своя мебель в 3D

extension RenoEditor {
    enum CustomResult { case added, tooMany, noRoom }

    func buildCustom() {
        customHolder.childNodes.forEach { $0.removeFromParentNode() }
        customHolder.isHidden = bare || furnitureHidden
        customNodes = tiling.pieces.indices.map { makeCustom($0) }
        customNodes.forEach { customHolder.addChildNode($0) }
    }

    private func makeCustom(_ j: Int) -> SCNNode {
        let p = tiling.pieces[j]
        let w = CGFloat(p.width), d = CGFloat(p.depth), h = CGFloat(p.height)
        let box = SCNBox(width: w, height: h, length: d, chamferRadius: min(0.01, min(w, d, h) / 4))
        let photo = CustomPiece.image(p.id)
        let side = SCNMaterial()
        side.lightingModel = .physicallyBased
        side.diffuse.contents = photo.flatMap { TileImage.average($0) } ?? UIColor(white: 0.75, alpha: 1)
        side.roughness.contents = 0.7
        let front = SCNMaterial()
        front.lightingModel = .physicallyBased
        if let photo {
            front.diffuse.contents = RenoEditor.facePicture(photo, aspect: p.width / p.height)
        } else {
            front.diffuse.contents = side.diffuse.contents
        }
        front.roughness.contents = 0.6
        // спереди фото товара, по бокам и сверху — его средний цвет
        box.materials = [front, side, side, side, side, side]
        let body = SCNNode(geometry: box)
        body.position.y = Float(h / 2)
        let node = SCNNode()
        node.name = "cust:\(j)"
        node.addChildNode(body)
        node.simdPosition = SIMD3(Float(p.x), 0, Float(p.y))
        node.eulerAngles.y = -Float(p.angle)
        return node
    }

    /// Фото товара целиком на лицевой стороне: по краям — белый фон, как на сайте магазина
    static func facePicture(_ img: UIImage, aspect: Double) -> UIImage {
        let longSide: CGFloat = 512
        let size = aspect >= 1 ? CGSize(width: longSide, height: max(16, (longSide / CGFloat(aspect)).rounded()))
                               : CGSize(width: max(16, (longSide * CGFloat(aspect)).rounded()), height: longSide)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let k = min(size.width / max(img.size.width, 1), size.height / max(img.size.height, 1))
            let s = CGSize(width: img.size.width * k, height: img.size.height * k)
            img.draw(in: CGRect(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2, width: s.width, height: s.height))
        }
    }

    /// Поставить свою вещь на свободное место; не влезает свободно — ближе к середине, но целиком в комнате
    @discardableResult
    func addCustom(_ piece: CustomPiece, image: UIImage?) -> CustomResult {
        guard tiling.pieces.count < CustomPiece.max else { return .tooMany }
        let w = Float(piece.width), d = Float(piece.depth)
        var found = freeSpot(kind: "storage", variant: "default", w: w, d: d, h: Float(piece.height))
        if found == nil {
            for angle in [Float(0), .pi / 2] {
                if let c = nearestFit(room.centroid, angle: angle, w: w, d: d) { found = (c, angle); break }
            }
        }
        guard let spot = found else { return .noRoom }
        var p = piece
        p.x = Double(spot.0.x)
        p.y = Double(spot.0.y)
        p.angle = Double(spot.1)
        if let image { CustomPiece.saveImage(image, id: p.id) }
        if furnitureHidden { setFurnitureHidden(false) }
        tiling.pieces.append(p)
        buildCustom()
        select(.custom(tiling.pieces.count - 1))
        return .added
    }

    /// Повернуть на четверть оборота; false — повёрнутой в комнату не помещается
    func rotateCustom(_ j: Int) -> Bool {
        guard tiling.pieces.indices.contains(j) else { return false }
        var p = tiling.pieces[j]
        p.angle = (p.angle + .pi / 2).truncatingRemainder(dividingBy: 2 * .pi)
        guard let c = nearestFit(SIMD2(Float(p.x), Float(p.y)), angle: Float(p.angle), w: Float(p.width), d: Float(p.depth))
        else { return false }
        p.x = Double(c.x)
        p.y = Double(c.y)
        tiling.pieces[j] = p
        buildCustom()
        highlight()
        return true
    }

    func removeCustom(_ j: Int) {
        guard tiling.pieces.indices.contains(j) else { return }
        select(nil)
        let id = tiling.pieces[j].id
        tiling.pieces.remove(at: j)
        CustomPiece.removeImage(id)
        buildCustom()
    }

    /// Стоит ли целиком в комнате на своём месте
    func customInRoom(_ j: Int) -> Bool {
        guard tiling.pieces.indices.contains(j) else { return false }
        let p = tiling.pieces[j]
        return inRoom(SIMD2(Float(p.x), Float(p.y)), angle: Float(p.angle), w: Float(p.width), d: Float(p.depth))
    }

    /// Пройдёт ли через самую широкую дверь комнаты (боком или на ребре). nil — дверей в скане нет
    func customPassesDoor(_ j: Int) -> (ok: Bool, door: Double)? {
        guard tiling.pieces.indices.contains(j) else { return nil }
        let doors = result.openings.filter { $0.kind == "door" || $0.kind == "opening" }
        guard let door = doors.max(by: { $0.width < $1.width }) else { return nil }
        let p = tiling.pieces[j]
        let s = [p.width, p.depth, p.height].sorted()
        // 2 см запаса на руки и косяк
        let ok = s[0] <= door.width - 0.02 && s[1] <= door.height - 0.02
        return (ok, door.width)
    }
}

// MARK: - Добавить свою мебель

struct CustomPieceAddView: View {
    let onSave: (CustomPiece, UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable { case link = "Ссылка", photo = "Фото" }

    @State private var source = Source.link
    @State private var linkText = ""
    @State private var browse: BrowseURL?
    @State private var link: String?
    @State private var loading = false
    @State private var problem: String?
    @State private var note: String?
    @State private var picked: PhotosPickerItem?
    @State private var camera = false
    @State private var photo: UIImage?
    @State private var name = ""
    @State private var width = ""
    @State private var depth = ""
    @State private var height = ""

    private func cm(_ s: String) -> Double? {
        guard let v = Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) else { return nil }
        return v / 100
    }

    private var size: (Double, Double, Double)? {
        guard let w = cm(width), let d = cm(depth), let h = cm(height),
              (0.05...6).contains(w), (0.05...6).contains(d), (0.05...4).contains(h) else { return nil }
        return (w, d, h)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Откуда", selection: $source) {
                        ForEach(Source.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    if source == .link {
                        TextField("Ссылка на товар в магазине", text: $linkText, axis: .vertical)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button { Task { await loadLink() } } label: {
                            HStack {
                                if loading { ProgressView() }
                                Text(loading ? "Загружаю…" : "Взять со страницы")
                            }
                        }
                        .disabled(linkText.isEmpty || loading)
                        Text("Любой магазин: Хофф, Divan.ru, Икеа, Озон, Wildberries и другие. Возьму фото, название и размеры, если они есть на странице.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button { camera = true } label: { Label("Сфотографировать", systemImage: "camera") }
                        PhotosPicker(selection: $picked, matching: .images) { Label("Выбрать из галереи", systemImage: "photo") }
                        Text("Подойдёт скриншот из магазина или фото в салоне. Размеры впишите ниже.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                }
                if let photo {
                    Section {
                        Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 200).frame(maxWidth: .infinity)
                    }
                }
                Section {
                    TextField("Название", text: $name)
                    field("Ширина", $width)
                    field("Глубина", $depth)
                    field("Высота", $height)
                    if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text("Размер из карточки товара")
                } footer: {
                    Text("Поставлю вещь в комнату в настоящем размере и проверю, влезает ли она и пройдёт ли в дверь.")
                }
            }
            .navigationTitle("Своя мебель")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Поставить") { save() }.disabled(size == nil)
                }
            }
            .onChange(of: picked) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        photo = TileImage.upright(img)
                    }
                }
            }
            .sheet(item: $browse) { b in
                ShopPageView(start: b.url, what: "товар") { found, img in apply(found, img) }
            }
            .fullScreenCover(isPresented: $camera) {
                PhotoCameraView { data in if let img = UIImage(data: data) { photo = TileImage.upright(img) } }
            }
        }
    }

    private func field(_ title: String, _ value: Binding<String>) -> some View {
        HStack {
            Text(title)
            TextField("0", text: value).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            Text("см").foregroundStyle(.secondary)
        }
    }

    private func loadLink() async {
        loading = true
        problem = nil
        note = nil
        defer { loading = false }
        do {
            let (found, img) = try await TileLink.fetch(linkText)
            apply(found, img)
        } catch TileLink.Problem.badURL {
            problem = "Это не похоже на ссылку. Скопируйте адрес страницы товара."
        } catch {
            // сайт не отдал страницу «простому» запросу — открываем как в Safari
            if let url = linkIn(linkText) { browse = BrowseURL(url: url) }
            else { problem = "Не получилось открыть страницу. Проверьте интернет или добавьте вещь по фото." }
        }
    }

    private func apply(_ found: TileLinkFound, _ img: UIImage) {
        do {
            photo = TileImage.upright(img)
            name = String(found.name.prefix(80))
            link = found.page?.absoluteString ?? linkText.trimmingCharacters(in: .whitespacesAndNewlines)
            let s = PieceSize.parse(found.text)
            let txt = { (v: Double?) in v.map { fmt(($0 * 1000).rounded() / 10) } ?? "" }
            if s.w != nil { width = txt(s.w) }
            if s.d != nil { depth = txt(s.d) }
            if s.h != nil { height = txt(s.h) }
            note = s.w == nil && s.d == nil && s.h == nil
                ? "Размеров на странице не нашёл — впишите их из карточки товара."
                : "Размеры взял со страницы — сверьте с карточкой товара (иногда там размер упаковки)."
        }
    }

    private func save() {
        guard let s = size else { return }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let piece = CustomPiece(name: title.isEmpty ? "Моя мебель" : title, link: link, width: s.0, depth: s.1, height: s.2)
        onSave(piece, photo.map { RenoEditor.facePicture($0, aspect: max($0.size.width, 1) / max($0.size.height, 1)) })
        dismiss()
    }
}
