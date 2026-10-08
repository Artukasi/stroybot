import SwiftUI
import simd

/// Квартира: общий план комнат, итоги, отправка всех комнат в бот, PDF и общая 3D-модель.
struct FlatView: View {
    @EnvironmentObject var store: ScanStore
    @EnvironmentObject var link: BotLink
    let id: UUID
    let open: (UUID) -> Void
    @State private var rooms: [(UUID, RoomResult)] = []
    @State private var name = ""
    @State private var renaming = false
    @State private var sending = false
    @State private var share: ShareFile?
    @State private var note: String?
    @State private var shown = false
    @Environment(\.dismiss) private var dismiss

    private var flat: SavedFlat? { store.flat(id) }
    private var outlines: [[[Double]]]? {
        guard let flat, !flat.outlines.isEmpty else { return nil }
        let list = rooms.compactMap { flat.outlines[$0.0] }
        return list.count == rooms.count ? list : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if rooms.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    planCard
                    totals
                    roomList
                    sendButton
                    Button { sharePDF() } label: { Label("План квартиры в PDF", systemImage: "doc.richtext") }
                    Button {
                        if let url = PlanDXF.flat(name: flat?.name ?? "Квартира", rooms: rooms.map { $0.1 }, outlines: outlines) {
                            share = ShareFile(url: url)
                        } else {
                            note = "Не получилось собрать чертёж."
                        }
                    } label: { Label("Чертёж квартиры DXF — для AutoCAD", systemImage: "pencil.and.ruler") }
                    if let model = store.flatModel(id) {
                        ShareLink(item: model) { Label("3D-модель квартиры (USDZ)", systemImage: "cube") }
                    }
                    if outlines == nil {
                        Text("Комнаты сняты по отдельности, поэтому на плане они стоят рядом, а не как в квартире. Чтобы получить настоящий план, снимайте все комнаты за один раз: «Следующая комната» и проход через дверь, не выключая камеру (нужна iOS 17).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(flat?.name ?? "Квартира")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { name = flat?.name ?? ""; renaming = true } label: { Label("Переименовать", systemImage: "pencil") }
                    Button(role: .destructive) { store.deleteFlat(id); dismiss() } label: { Label("Удалить квартиру", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear(perform: load)
        .sheet(item: $share) { ActivitySheet(items: [$0.url]) }
        .alert("Название", isPresented: $renaming) {
            TextField("Квартира на Ленина", text: $name)
            Button("Сохранить") { if !name.isEmpty { store.renameFlat(id, name) } }
            Button("Отмена", role: .cancel) {}
        }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func load() {
        guard let flat else { return }
        rooms = flat.rooms.compactMap { rid in store.result(rid).map { (rid, $0) } }
        if !shown { withAnimation(.easeOut(duration: 1.2).delay(0.2)) { shown = true } }
    }

    // MARK: - План

    private var planCard: some View {
        FlatPlanView(rooms: rooms.map { $0.1 }, outlines: outlines, progress: shown ? 1 : 0)
            .frame(height: 300)
            .padding(16)
            .background(Palette.ink, in: RoundedRectangle(cornerRadius: 22))
    }

    private var totals: some View {
        let r = rooms.map { $0.1 }
        let floor = r.reduce(0) { $0 + $1.floorArea }
        let walls = r.reduce(0) { $0 + $1.wallArea }
        let skirting = r.reduce(0) { $0 + $1.skirting }
        let doors = r.reduce(0) { $0 + $1.doors }
        let windows = r.reduce(0) { $0 + $1.windows }
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            total("Пол всего", floor, "м²")
            total("Стены без проёмов", walls, "м²")
            total("Плинтус", skirting, "м")
            VStack(alignment: .leading, spacing: 4) {
                Text("Окна и двери").font(.caption).foregroundStyle(.secondary)
                Text("\(windows) и \(doors)").font(.title3.bold())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func total(_ title: String, _ v: Double, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                CountUp(value: shown ? v : 0).font(.title3.bold())
                Text(unit).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var roomList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Комнаты").font(.title3.bold())
            Text("Откройте комнату, чтобы дать ей название, сделать ремонт в 3D или доснять.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(rooms.enumerated()), id: \.offset) { i, item in
                if let s = store.scan(item.0) {
                    Button { open(item.0) } label: {
                        HStack(spacing: 10) {
                            Circle().fill(Color(FlatLayout.colors[i % FlatLayout.colors.count])).frame(width: 12, height: 12)
                            ScanRow(scan: s)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Отправка

    private var sendButton: some View {
        let ids = rooms.map(\.0)
        let notSent = ids.filter { store.botScanId($0, server: link.server) == nil }
        return VStack(alignment: .leading, spacing: 6) {
            Button { Task { await sendAll(notSent) } } label: {
                Group {
                    if sending { ProgressView() } else if notSent.isEmpty {
                        Label("Все комнаты в боте", systemImage: "checkmark")
                    } else {
                        Label("Отправить в СтройБот: \(notSent.count) \(plural(notSent.count, "комнату", "комнаты", "комнат"))",
                              systemImage: "paperplane.fill")
                    }
                }
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(Palette.signal, in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(Palette.ink)
            }
            .disabled(sending || notSent.isEmpty)
            Text("Каждая комната придёт в бот отдельным сканом: материалы и смета посчитаются по каждой.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func sendAll(_ ids: [UUID]) async {
        guard link.connected else {
            for i in ids { store.setPending(i, true) }
            note = "Комнаты в очереди: уйдут в бот, когда подключите бота."
            return
        }
        sending = true
        defer { sending = false }
        var ok = 0
        for rid in ids {
            guard let r = rooms.first(where: { $0.0 == rid })?.1 else { continue }
            do {
                guard let n = try await link.sendScan(r) else { continue }
                store.setSent(rid, botScanId: n, server: link.server)
                if let l = store.look(rid) { try? await link.saveLook(scanId: n, look: l.json) }
                ok += 1
            } catch LinkError.offline(let why) {
                for i in ids where store.botScanId(i, server: link.server) == nil { store.setPending(i, true) }
                note = "\(why)\n\nОстальные комнаты в очереди: уйдут сами, когда бот станет доступен."
                return
            } catch {
                note = LinkError.describe(error)
                return
            }
        }
        note = "Отправлено комнат: \(ok)."
    }

    private func sharePDF() {
        let ids = rooms.map(\.0)
        let photo = { (d: UUID) -> UIImage? in ids.lazy.compactMap { store.defectPhoto($0, d) }.first }
        if let url = PlanPDF.flat(name: flat?.name ?? "Квартира", rooms: rooms.map { $0.1 }, outlines: outlines, photos: photo) {
            share = ShareFile(url: url)
        } else {
            note = "Не получилось собрать PDF."
        }
    }
}

/// Общий план квартиры: контуры комнат прорисовываются, подписи появляются следом
struct FlatPlanView: View {
    let rooms: [RoomResult]
    let outlines: [[[Double]]]?
    var progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            let shapes = FlatLayout.shapes(rooms: rooms, outlines: outlines)
            let frame = Self.frame(shapes, geo.size)
            ZStack {
                ForEach(Array(shapes.enumerated()), id: \.offset) { i, s in
                    let color = Color(FlatLayout.colors[i % FlatLayout.colors.count])
                    OutlineShape(points: s.points.map(frame))
                        .fill(color.opacity(0.22 * Double(progress)))
                    OutlineShape(points: s.points.map(frame))
                        .trim(from: 0, to: progress)
                        .stroke(Palette.signal, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                    let c = frame(FlatLayout.centroid(s.points))
                    VStack(spacing: 1) {
                        Text(rooms[i].room).font(.caption.bold())
                        Text("\(fmt(rooms[i].floorArea)) м²").font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .opacity(Double(progress))
                    .position(c)
                }
            }
        }
    }

    /// Метры → точки рамки
    static func frame(_ shapes: [FlatLayout.Shape], _ size: CGSize) -> (SIMD2<Double>) -> CGPoint {
        let all = shapes.flatMap(\.points)
        let minX = all.map(\.x).min() ?? 0, maxX = all.map(\.x).max() ?? 1
        let minY = all.map(\.y).min() ?? 0, maxY = all.map(\.y).max() ?? 1
        let k = min(size.width / CGFloat(max(maxX - minX, 0.1)), size.height / CGFloat(max(maxY - minY, 0.1)))
        let ox = (size.width - CGFloat(maxX - minX) * k) / 2, oy = (size.height - CGFloat(maxY - minY) * k) / 2
        return { p in CGPoint(x: ox + CGFloat(p.x - minX) * k, y: oy + CGFloat(p.y - minY) * k) }
    }
}

struct OutlineShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        points.dropFirst().forEach { p.addLine(to: $0) }
        p.closeSubpath()
        return p
    }
}
