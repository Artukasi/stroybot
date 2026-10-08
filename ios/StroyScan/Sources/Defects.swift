import PhotosUI
import SceneKit
import SwiftUI
import simd

/// Дефект в комнате: трещина, протечка, плесень, кривой угол… Место на плане и высота от пола, фото и заметка.
/// Видно на плане, в 3D (красная булавка с номером) и в PDF «Дефекты» — отчёт для клиента или прораба.
struct Defect: Equatable, Identifiable {
    var id = UUID()
    var kind: String
    var note: String = ""
    var x: Double
    var y: Double
    var height: Double
    /// Стена скана, если отметка на стене
    var wall: Int?
    var created = Date()
    var fixed = false
    var hasPhoto = false

    var json: [String: Any] {
        let r = { (v: Double) in (v * 1000).rounded() / 1000 }
        var d: [String: Any] = ["id": id.uuidString, "kind": kind, "note": note, "x": r(x), "y": r(y), "height": r(height),
                                "created": created.timeIntervalSince1970, "fixed": fixed, "photo": hasPhoto]
        if let wall { d["wall"] = wall }
        return d
    }

    init(kind: String, x: Double, y: Double, height: Double, wall: Int?) {
        self.kind = kind
        self.x = x
        self.y = y
        self.height = height
        self.wall = wall
    }

    init?(json d: [String: Any]) {
        let num = { (v: Any?) -> Double? in (v as? NSNumber)?.doubleValue }
        guard let kind = d["kind"] as? String, let x = num(d["x"]), let y = num(d["y"]) else { return nil }
        self.kind = kind
        self.x = x
        self.y = y
        height = num(d["height"]) ?? 0
        wall = (d["wall"] as? NSNumber)?.intValue
        note = String((d["note"] as? String ?? "").prefix(1000))
        id = (d["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        created = num(d["created"]).map { Date(timeIntervalSince1970: $0) } ?? Date()
        fixed = d["fixed"] as? Bool ?? false
        hasPhoto = d["photo"] as? Bool ?? false
    }

    var title: String { DefectKind.find(kind)?.title ?? "Дефект" }

    static let max = 60
}

struct DefectKind: Identifiable {
    let id: String
    let title: String
    let icon: String

    static let all = [
        DefectKind(id: "crack", title: "Трещина", icon: "bolt.horizontal"),
        DefectKind(id: "leak", title: "Протечка", icon: "drop.triangle"),
        DefectKind(id: "mold", title: "Плесень, грибок", icon: "allergens"),
        DefectKind(id: "uneven", title: "Неровность", icon: "water.waves"),
        DefectKind(id: "corner", title: "Кривой угол", icon: "angle"),
        DefectKind(id: "chip", title: "Скол, повреждение", icon: "hammer"),
        DefectKind(id: "electric", title: "Электрика", icon: "bolt.trianglebadge.exclamationmark"),
        DefectKind(id: "plumbing", title: "Сантехника", icon: "spigot"),
        DefectKind(id: "window", title: "Окно, дверь", icon: "window.casement"),
        DefectKind(id: "other", title: "Другое", icon: "exclamationmark.bubble"),
        DefectKind(id: "note", title: "Заметка", icon: "mic.fill"),
    ]

    static func find(_ id: String) -> DefectKind? { all.first { $0.id == id } }
}

extension RoomResult {
    /// Досъёмка в том же сеансе: дефекты переносим через мировые координаты (план мог повернуться)
    func movedDefects(_ old: RoomResult) -> [Defect]? {
        guard old.worldFrame != nil, worldFrame != nil else { return nil }
        var out: [Defect] = []
        for d in old.defects {
            guard let w = old.toWorld(SIMD3(d.x, d.y, d.height)), let q = toPlan(w) else { return nil }
            var n = d
            n.x = q.x
            n.y = q.y
            n.height = max(0, q.z)
            n.wall = d.wall == nil ? nil : nearestWall(SIMD2(q.x, q.y)).flatMap { $0.distance < 0.35 ? $0.wall : nil }
            out.append(n)
        }
        return out
    }
}

// MARK: - Фото дефектов (в папке скана)

extension ScanStore {
    nonisolated func defectPhotoURL(_ scan: UUID, _ defect: UUID) -> URL {
        folderURL.appendingPathComponent("\(scan.uuidString)/defects/\(defect.uuidString).jpg")
    }

    nonisolated func saveDefectPhoto(_ scan: UUID, _ defect: UUID, _ data: Data) {
        let url = defectPhotoURL(scan, defect)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // уменьшаем до 1600 точек — в копию и PDF идёт быстро
        if let img = UIImage(data: data) {
            let k = min(1, 1600 / max(img.size.width, img.size.height, 1))
            let size = CGSize(width: img.size.width * k, height: img.size.height * k)
            let small = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
            try? small.jpegData(compressionQuality: 0.8)?.write(to: url, options: .atomic)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    nonisolated func defectPhoto(_ scan: UUID, _ defect: UUID) -> UIImage? {
        UIImage(contentsOfFile: defectPhotoURL(scan, defect).path)
    }

    nonisolated func deleteDefectPhoto(_ scan: UUID, _ defect: UUID) {
        try? FileManager.default.removeItem(at: defectPhotoURL(scan, defect))
    }
}

// MARK: - На плане

/// Красные номера дефектов поверх плана (исправленные — зелёные)
struct PlanDefects: View {
    let defects: [Defect]
    let points: [SIMD2<Double>]
    var selected: UUID?

    var body: some View {
        GeometryReader { geo in
            if let f = planFrame(points, in: CGRect(origin: .zero, size: geo.size)) {
                ForEach(Array(defects.enumerated()), id: \.element.id) { i, d in
                    Text("\(i + 1)")
                        .font(.caption2.bold())
                        .frame(width: 20, height: 20)
                        .background(d.fixed ? Color.green : Color.red, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: d.id == selected ? 3 : 1.5))
                        .foregroundStyle(.white)
                        .scaleEffect(d.id == selected ? 1.3 : 1)
                        .position(x: f.ox + CGFloat(d.x) * f.k, y: f.oy + CGFloat(d.y) * f.k)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Раздел на экране комнаты

struct DefectsSection: View {
    @EnvironmentObject var store: ScanStore
    let scanID: UUID
    @Binding var result: RoomResult
    @State private var adding = false
    @State private var voice = false
    @State private var open: Defect?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Дефекты и заметки", systemImage: "exclamationmark.triangle").font(.headline)
                Spacer()
                if result.defects.contains(where: { $0.kind != "note" }) {
                    let left = result.defects.filter { !$0.fixed && $0.kind != "note" }.count
                    Text(left == 0 ? "все исправлены" : "открыто: \(left)").font(.caption.bold())
                        .foregroundStyle(left == 0 ? Color.green : Color.red)
                }
            }
            ForEach(Array(result.defects.enumerated()), id: \.element.id) { i, d in
                Button { open = d } label: { row(i, d) }.buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                Button { voice = false; adding = true } label: {
                    Label("Дефект", systemImage: "plus.viewfinder")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.red)
                }
                Button { voice = true; adding = true } label: {
                    Label("Голосом", systemImage: "mic.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Palette.draft.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Palette.draft)
                }
            }
            .disabled(result.defects.count >= Defect.max || result.plan.count < 3)
            if result.defects.isEmpty {
                Text("Трещина, протечка, кривой угол — или просто заметка голосом к стене («тут розетка выше», «здесь штробить»). Место на плане, фото, текст — всё попадёт в PDF.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .sheet(isPresented: $adding) {
            DefectEditor(scanID: scanID, result: result, defect: nil, voice: voice) { d in
                withAnimation(.spring(response: 0.4)) { result.defects.append(d) }
            } onDelete: {}
        }
        .sheet(item: $open) { d in
            DefectEditor(scanID: scanID, result: result, defect: d) { changed in
                if let i = result.defects.firstIndex(where: { $0.id == changed.id }) { result.defects[i] = changed }
            } onDelete: {
                store.deleteDefectPhoto(scanID, d.id)
                withAnimation { result.defects.removeAll { $0.id == d.id } }
            }
        }
    }

    private func row(_ i: Int, _ d: Defect) -> some View {
        HStack(spacing: 10) {
            Text("\(i + 1)").font(.caption.bold()).frame(width: 24, height: 24)
                .background(d.fixed ? Color.green : Color.red, in: Circle()).foregroundStyle(.white)
            if d.hasPhoto, let img = store.defectPhoto(scanID, d.id) {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(d.title).font(.subheadline.bold()).strikethrough(d.fixed)
                Text(d.note.isEmpty ? place(d) : d.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func place(_ d: Defect) -> String {
        if let w = d.wall { return "Стена \(w + 1), \(Int((d.height * 100).rounded())) см от пола" }
        return d.height < 0.1 ? "На полу" : "Потолок"
    }
}

/// Новый дефект или правка: место пальцем на плане, высота, вид, фото, заметка
struct DefectEditor: View {
    @EnvironmentObject var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    let scanID: UUID
    let result: RoomResult
    let defect: Defect?
    /// Сразу заметка голосом: вид «Заметка» и включённый микрофон
    var voice = false
    let onSave: (Defect) -> Void
    let onDelete: () -> Void
    @StateObject private var dictation = Dictation()
    /// Текст заметки до начала диктовки — надиктованное дописываем к нему
    @State private var noteBase = ""

    @State private var kind = "crack"
    @State private var note = ""
    @State private var spot: SIMD2<Double>?
    @State private var height = 1.0
    @State private var fixed = false
    @State private var photo: Data?
    @State private var oldPhoto: UIImage?
    @State private var camera = false
    @State private var picked: PhotosPickerItem?

    private var wall: (wall: Int, offset: Double, distance: Double)? {
        guard let spot, let near = result.nearestWall(spot), near.distance < 0.3 else { return nil }
        return near
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    plan.frame(height: 230).listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                } header: {
                    Text("Где")
                } footer: {
                    Text(spot == nil ? "Нажмите на плане место дефекта." :
                         wall.map { "Стена \($0.wall + 1)" } ?? "Пол или потолок")
                }
                if spot != nil {
                    Section("Высота от пола") {
                        HStack {
                            Slider(value: $height, in: 0...max(result.height, 1), step: 0.05)
                            Text("\(Int((height * 100).rounded())) см").monospacedDigit().frame(width: 64, alignment: .trailing)
                        }
                        HStack {
                            ForEach([("Пол", 0.0), ("Середина", result.height / 2), ("Потолок", result.height)], id: \.0) { t, h in
                                Button(t) { withAnimation { height = h } }.buttonStyle(.bordered)
                            }
                        }
                    }
                }
                Section("Что") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 8) {
                        ForEach(DefectKind.all) { k in
                            Button { kind = k.id } label: {
                                Label(k.title, systemImage: k.icon).font(.caption.bold())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(kind == k.id ? Color.red.opacity(0.18) : Color(.tertiarySystemFill),
                                                in: RoundedRectangle(cornerRadius: 10))
                                    .foregroundStyle(kind == k.id ? Color.red : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    TextField("Заметка: размер, когда появилось, что делать", text: $note, axis: .vertical)
                        .lineLimit(2...8)
                    DictateButton(dictation: dictation)
                }
                Section("Фото") {
                    if let img = photo.flatMap(UIImage.init(data:)) ?? oldPhoto {
                        Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Button { camera = true } label: { Label("Снять камерой", systemImage: "camera") }
                    PhotosPicker(selection: $picked, matching: .images) { Label("Из галереи", systemImage: "photo") }
                }
                if defect != nil {
                    Section {
                        Toggle("Исправлено", isOn: $fixed)
                        Button("Удалить дефект", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(kind == "note" ? "Заметка" : defect == nil ? "Новый дефект" : "Дефект")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }.bold().disabled(spot == nil)
                }
            }
            .fullScreenCover(isPresented: $camera) {
                PhotoCameraView { data in photo = data }
            }
            .onChange(of: picked) { item in
                Task { if let d = try? await item?.loadTransferable(type: Data.self) { photo = d } }
            }
            .onAppear(perform: load)
            .onChange(of: dictation.running) { on in if on { noteBase = note } }
            .onChange(of: dictation.text) { said in
                guard !said.isEmpty else { return }
                note = noteBase.isEmpty ? said : noteBase + " " + said
            }
            .onDisappear { dictation.stop() }
        }
    }

    private var plan: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            ZStack {
                PlanShape(points: result.plan).fill(Palette.draft.opacity(0.08))
                PlanShape(points: result.plan).stroke(Palette.ink, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                PlanWalls(points: result.plan, lines: result.wallLines, weak: [])
                if let spot, let f = planFrame(result.plan, in: rect) {
                    Image(systemName: "mappin.circle.fill").font(.system(size: 30)).foregroundStyle(.white, .red)
                        .position(x: f.ox + CGFloat(spot.x) * f.k, y: f.oy + CGFloat(spot.y) * f.k - 12)
                        .transition(.scale)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { p in
                guard let f = planFrame(result.plan, in: rect), f.k > 0 else { return }
                let q = SIMD2(Double((p.x - f.ox) / f.k), Double((p.y - f.oy) / f.k))
                withAnimation(.spring(response: 0.3)) {
                    // у стены — прилипает к стене
                    if let near = result.nearestWall(q), near.distance < 0.3, let at = result.wallPoint(near.wall, offset: near.offset) {
                        spot = at
                        if defect == nil && height < 0.05 { height = 1 }
                    } else {
                        spot = q
                        if defect == nil { height = 0 }
                    }
                }
            }
        }
        .aspectRatio(max(0.6, min(1.8, result.length / max(result.width, 0.1))), contentMode: .fit)
    }

    private func load() {
        if defect == nil && voice && spot == nil {
            kind = "note"
            Task { await dictation.start() }
        }
        guard let d = defect, spot == nil else { return }
        kind = d.kind
        note = d.note
        spot = SIMD2(d.x, d.y)
        height = d.height
        fixed = d.fixed
        if d.hasPhoto { oldPhoto = store.defectPhoto(scanID, d.id) }
    }

    private func save() {
        guard let spot else { return }
        var d = defect ?? Defect(kind: kind, x: spot.x, y: spot.y, height: height, wall: nil)
        d.kind = kind
        d.note = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        d.x = spot.x
        d.y = spot.y
        d.height = height
        d.wall = wall?.wall
        d.fixed = fixed
        if let photo {
            store.saveDefectPhoto(scanID, d.id, photo)
            d.hasPhoto = true
        }
        onSave(d)
        dismiss()
    }
}

// MARK: - В 3D

extension RenoEditor {
    /// Красные булавки с номерами там, где отмечены дефекты
    func buildDefects() {
        defectHolder.childNodes.forEach { $0.removeFromParentNode() }
        let normals = Dictionary(room.walls.map { ($0.index, $0.normal) }, uniquingKeysWith: { a, _ in a })
        for (i, d) in result.defects.enumerated() {
            let color: UIColor = d.fixed ? .systemGreen : .systemRed
            let pin = SCNNode()
            let ball = SCNSphere(radius: 0.06)
            let m = SCNMaterial()
            m.diffuse.contents = color
            m.emission.contents = color.withAlphaComponent(0.6)
            ball.firstMaterial = m
            let head = SCNNode(geometry: ball)
            let label = SCNText(string: "\(i + 1)", extrusionDepth: 0.01)
            label.font = UIFont.systemFont(ofSize: 0.1, weight: .heavy)
            label.flatness = 0.01
            let lm = SCNMaterial()
            lm.diffuse.contents = UIColor.white
            lm.lightingModel = .constant
            label.firstMaterial = lm
            let text = SCNNode(geometry: label)
            let (lo, hi) = text.boundingBox
            text.pivot = SCNMatrix4MakeTranslation((hi.x + lo.x) / 2, (hi.y + lo.y) / 2, 0)
            text.position = SCNVector3(0, 0.13, 0)
            let board = SCNNode()
            board.addChildNode(text)
            board.constraints = [SCNBillboardConstraint()]
            pin.addChildNode(head)
            pin.addChildNode(board)
            var p = SIMD3(Float(d.x), Float(d.height), Float(d.y))
            if let w = d.wall, let n = normals[w] { p += SIMD3(n.x, 0, n.y) * 0.08 }
            p.y = min(max(p.y, 0.06), room.height - 0.06)
            pin.simdPosition = p
            // мягкое покачивание, чтобы булавку было видно
            let bob = SCNAction.sequence([.moveBy(x: 0, y: 0.03, z: 0, duration: 0.8), .moveBy(x: 0, y: -0.03, z: 0, duration: 0.8)])
            bob.timingMode = .easeInEaseOut
            head.runAction(.repeatForever(bob))
            defectHolder.addChildNode(pin)
        }
    }
}
